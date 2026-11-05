//! In-memory task links and plans. They live as long as the daemon does.

use std::collections::HashMap;

use fleet_protocol::api::{
    ApiError, ErrorCode, PlanInfo, PlanState, PlanStepInfo, PlanStepSpec, SessionStatus, StepState,
    TaskInfo, sidebar_class,
};
use tokio::sync::{Mutex, watch};

struct Presence {
    active: bool,
    needs_attention: bool,
}

struct TaskRecord {
    parent_id: Option<String>,
    brief: Option<String>,
    plan_id: Option<String>,
    step_index: Option<u32>,
}

struct StoredStep {
    spec: PlanStepSpec,
    state: StepState,
    session_id: Option<String>,
}

struct StoredPlan {
    parent_id: String,
    state: PlanState,
    steps: Vec<StoredStep>,
}

struct Inner {
    tasks: HashMap<String, TaskRecord>,
    plans: HashMap<String, StoredPlan>,
    presence: HashMap<String, Presence>,
    next_plan: u64,
    generation: u64,
}

/// What the plan runner should do after a step exits.
#[derive(Debug, PartialEq, Eq)]
pub enum Advance {
    /// The next waiting step can be spawned.
    Continue,
    /// The plan is done or failed.
    Stop,
}

pub struct TaskBook {
    inner: Mutex<Inner>,
    sessions: watch::Sender<u64>,
}

impl TaskBook {
    pub fn new() -> Self {
        let (sessions, _) = watch::channel(0);
        Self {
            inner: Mutex::new(Inner {
                tasks: HashMap::new(),
                plans: HashMap::new(),
                presence: HashMap::new(),
                next_plan: 1,
                generation: 0,
            }),
            sessions,
        }
    }

    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.sessions.subscribe()
    }

    pub async fn bump(&self) {
        let next = {
            let mut inner = self.inner.lock().await;
            inner.generation = inner.generation.saturating_add(1);
            inner.generation
        };
        let _ = self.sessions.send(next);
    }

    pub async fn record_task(
        &self,
        session_id: String,
        parent_id: Option<String>,
        brief: Option<String>,
    ) {
        let mut inner = self.inner.lock().await;
        inner.tasks.insert(
            session_id,
            TaskRecord {
                parent_id,
                brief,
                plan_id: None,
                step_index: None,
            },
        );
    }

    pub async fn forget(&self, session_id: &str) {
        let mut inner = self.inner.lock().await;
        inner.tasks.remove(session_id);
        inner.presence.remove(session_id);
    }

    pub async fn set_presence(&self, session_id: String, active: bool, needs_attention: bool) {
        let mut inner = self.inner.lock().await;
        inner.presence.insert(
            session_id,
            Presence {
                active,
                needs_attention,
            },
        );
    }

    pub async fn list(
        &self,
        sessions: &[(String, SessionStatus)],
        parent_id: Option<&str>,
    ) -> Vec<TaskInfo> {
        let inner = self.inner.lock().await;
        let mut listed = Vec::new();
        for (session_id, task) in &inner.tasks {
            if parent_id.is_some_and(|parent| task.parent_id.as_deref() != Some(parent)) {
                continue;
            }
            let Some((_, status)) = sessions.iter().find(|(id, _)| id == session_id) else {
                continue;
            };
            let presence = inner
                .presence
                .get(session_id)
                .map(|presence| (presence.active, presence.needs_attention))
                .unwrap_or((false, false));
            let step_state = task.plan_id.as_ref().and_then(|plan_id| {
                let plan = inner.plans.get(plan_id)?;
                let index = task.step_index?;
                plan.steps.get(index as usize).map(|step| step.state)
            });
            listed.push(TaskInfo {
                session_id: session_id.clone(),
                parent_id: task.parent_id.clone(),
                brief: task.brief.clone(),
                status: status.clone(),
                sidebar: sidebar_class(status, presence.0, presence.1),
                plan_id: task.plan_id.clone(),
                step_index: task.step_index,
                step_state,
            });
        }
        listed.sort_by(|left, right| left.session_id.cmp(&right.session_id));
        listed
    }

    /// Stores a plan whose steps are all waiting. Rejects an empty plan and a second in-flight plan.
    pub async fn begin_plan(
        &self,
        parent_id: String,
        steps: Vec<PlanStepSpec>,
    ) -> Result<String, ApiError> {
        if steps.is_empty() {
            return Err(ApiError::invalid_request("a plan needs at least one step"));
        }
        let mut inner = self.inner.lock().await;
        let busy = inner
            .plans
            .values()
            .any(|plan| plan.parent_id == parent_id && plan.state == PlanState::Running);
        if busy {
            return Err(ApiError::invalid_request(
                "this session already has a plan in progress",
            ));
        }
        let id = format!("plan-{}", inner.next_plan);
        inner.next_plan = inner.next_plan.saturating_add(1);
        inner.plans.insert(
            id.clone(),
            StoredPlan {
                parent_id,
                state: PlanState::Running,
                steps: steps
                    .into_iter()
                    .map(|spec| StoredStep {
                        spec,
                        state: StepState::Waiting,
                        session_id: None,
                    })
                    .collect(),
            },
        );
        Ok(id)
    }

    pub async fn step_spec(&self, plan_id: &str, index: usize) -> Result<PlanStepSpec, ApiError> {
        let inner = self.inner.lock().await;
        let plan = inner.plans.get(plan_id).ok_or_else(|| {
            ApiError::new(
                ErrorCode::InvalidRequest,
                format!("plan {plan_id} was not found"),
            )
        })?;
        plan.steps
            .get(index)
            .map(|step| step.spec.clone())
            .ok_or_else(|| ApiError::invalid_request("that plan step does not exist"))
    }

    pub async fn plan_parent(&self, plan_id: &str) -> Option<String> {
        self.inner
            .lock()
            .await
            .plans
            .get(plan_id)
            .map(|plan| plan.parent_id.clone())
    }

    pub async fn mark_started(&self, plan_id: &str, index: usize, session_id: String) {
        let mut inner = self.inner.lock().await;
        let Some(plan) = inner.plans.get_mut(plan_id) else {
            return;
        };
        let parent_id = plan.parent_id.clone();
        let brief = plan
            .steps
            .get(index)
            .and_then(|step| step.spec.brief.clone());
        if let Some(step) = plan.steps.get_mut(index) {
            step.state = StepState::Running;
            step.session_id = Some(session_id.clone());
        }
        inner.tasks.insert(
            session_id,
            TaskRecord {
                parent_id: Some(parent_id),
                brief,
                plan_id: Some(plan_id.to_owned()),
                step_index: Some(index as u32),
            },
        );
    }

    /// Marks the running step from its exit. A failure stops the plan.
    pub async fn complete_running(&self, plan_id: &str, success: bool) -> Advance {
        let mut inner = self.inner.lock().await;
        let Some(plan) = inner.plans.get_mut(plan_id) else {
            return Advance::Stop;
        };
        let Some(position) = plan
            .steps
            .iter()
            .position(|step| step.state == StepState::Running)
        else {
            return Advance::Stop;
        };
        if !success {
            plan.steps[position].state = StepState::Failed;
            plan.state = PlanState::Failed;
            return Advance::Stop;
        }
        plan.steps[position].state = StepState::Done;
        let more = plan
            .steps
            .iter()
            .any(|step| step.state == StepState::Waiting);
        if more {
            return Advance::Continue;
        }
        plan.state = PlanState::Done;
        Advance::Stop
    }

    pub async fn fail_plan(&self, plan_id: &str, index: usize) {
        let mut inner = self.inner.lock().await;
        let Some(plan) = inner.plans.get_mut(plan_id) else {
            return;
        };
        if let Some(step) = plan.steps.get_mut(index) {
            step.state = StepState::Failed;
        }
        plan.state = PlanState::Failed;
    }

    /// Index of the first step that has not been spawned, when the plan is still running.
    pub async fn next_waiting(&self, plan_id: &str) -> Option<usize> {
        let inner = self.inner.lock().await;
        let plan = inner.plans.get(plan_id)?;
        if plan.state != PlanState::Running {
            return None;
        }
        plan.steps
            .iter()
            .position(|step| step.state == StepState::Waiting)
    }

    pub async fn get(&self, id: &str) -> Result<PlanInfo, ApiError> {
        let inner = self.inner.lock().await;
        let plan = inner.plans.get(id).ok_or_else(|| {
            ApiError::new(
                ErrorCode::InvalidRequest,
                format!("plan {id} was not found"),
            )
        })?;
        Ok(PlanInfo {
            id: id.to_owned(),
            parent_id: plan.parent_id.clone(),
            state: plan.state,
            steps: plan
                .steps
                .iter()
                .enumerate()
                .map(|(index, step)| PlanStepInfo {
                    index: index as u32,
                    state: step.state,
                    session_id: step.session_id.clone(),
                    brief: step.spec.brief.clone(),
                })
                .collect(),
        })
    }
}
