# Director

A proposed desktop workspace for running and coordinating coding agents, backed by a Rust engine.

## Architecture

![Proposed Director architecture: a replaceable desktop frontend and CLI/MCP adapters connect to a Rust daemon that owns sessions, PTYs, scheduling, worktrees, and persistence.](assets/architecture.png)

The Rust daemon owns agent processes and terminal sessions independently of the desktop UI. Closing the UI detaches the client; running agents continue until they exit or the daemon stops.

- **Desktop frontend:** GPUI for a Rust interface across desktop platforms, or SwiftUI with AppKit for a Mac-focused app.
- **Local API:** versioned commands, events, and terminal streams shared by the UI, CLI, and MCP adapters.
- **Session engine:** agent lifecycle, scheduling, task coordination, action policy, and worktree ownership.
- **PTY and terminal host:** process input/output, resizing, bounded buffers, and session reattachment.
- **Persistence:** SQLite and session journals for task state, metadata, history, and recovery.
- **Agent tools:** installed CLI agents use their own credentials and permissions, connecting directly to their model providers.

This diagram describes the proposed design. The engine and desktop frontend have not been implemented yet.

The first milestone is one project with two live agent sessions, reliable terminal input and resizing, and reconnecting the UI without restarting agents.
