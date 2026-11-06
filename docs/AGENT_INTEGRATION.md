# Integrating an Agent CLI with Fleet

Fleet starts installed coding-agent CLIs and gives each supported session three
MCP tools: `orchestrate`, `watch`, and `plan`. The tools are served by a
loopback HTTP server that the macOS app runs for as long as it is connected to
the daemon. The server URL contains a random token:

```text
http://127.0.0.1:<port>/mcp/<token>
```

Each supported preset receives launch arguments and/or environment variables
that make that one process load the server. Fleet never edits the user's own
agent configuration. This document describes the current wiring, how to add a
new CLI, and what to check when an agent changes its configuration format.

## Supported presets

| Preset | ID | How Fleet supplies the server | Verified with |
| --- | --- | --- | --- |
| Claude Code | `claude` | `--mcp-config <file>` (a temporary file; no `--strict-mcp-config`) | Claude Code 2.1.317 |
| Codex | `codex` | `-c mcp_servers.fleet.url="<url>"` | codex-cli 0.164.0 |
| Gemini CLI | `gemini` | `GEMINI_CLI_SYSTEM_SETTINGS_PATH=<file>` containing `mcpServers.fleet.httpUrl` | Gemini CLI 0.46.0 |
| OpenCode | `opencode` | `OPENCODE_CONFIG_CONTENT=<inline JSON>` plus `--standalone` | OpenCode v2.2.5 |
| Cursor Agent | `cursor` | not wired | 2025.10.28 |
| Shell / Custom | `shell`, `custom` | not wired; not agents | — |

"Verified with" is the version used when the integration was last checked. It
is not a minimum version. Re-run the checks in [Verification](#verification)
after upgrading an agent.

## Where the wiring lives

| Location | Responsibility |
| --- | --- |
| `apps/macos/Fleet/Services/AgentCatalog.swift` | `AgentPreset.all`: the visible preset list (`id`, title, binary, default arguments, SF Symbol). `pluginPresets` passes them to the plugin. |
| `apps/macos/FleetKit/Sources/FleetAPI/PluginHandler.swift` | `FleetPluginEndpoint`, `FleetPluginLaunch.spec`, `FleetPluginFiles`, and the handler that creates child sessions and plan steps. |
| `apps/macos/Fleet/Services/PluginServer.swift` | Binds the loopback port, writes the per-run config files, exposes the endpoint, and removes the files on stop. |
| `apps/macos/Fleet/App/AppModel.swift` | Applies the plugin spec when the UI starts a session (`createSession`). |
| `apps/macos/FleetKit/Tests/FleetAPITests/PluginHandlerTests.swift` | Writer, spec, and child-session/plan tests. |

`FleetPluginLaunch.spec(presetID:endpoint:)` is the **only** place that maps a
preset to launch arguments and environment. Both paths use it:

- UI launch: `AppModel.createSession` → `AgentCatalog.pluginLaunch` →
  `FleetPluginLaunch.spec` → `spec.applying(to: sessionEnvironment(...))`.
- Agent-spawned session: `PluginHandler.resolveLaunch` →
  `FleetPluginLaunch.spec` → `spec.applying(to: sessionEnvironment(...))`.
- Plan step: the same spec, applied to `planStepEnvironment()`. The daemon adds
  `FLEET_SESSION_ID` when it assigns the step's session id.

Do not add a second preset switch anywhere else. If a path needs different
behavior, change `spec` (or the endpoint) so every path stays equal.

The `preset` value that an agent passes to `orchestrate` and `plan` is the same
`id` from `AgentPreset.all`. Passing `program` instead resolves the preset by
the executable's basename. A wrapper script with a different name therefore
gets no plugin wiring unless you add a preset for it.

## Adding a preset

1. **Find a process-scoped hook.** Read the CLI's own documentation and
   `--help`. Prefer, in order:
   1. a flag that adds one MCP server for this launch (Claude Code, Codex);
   2. a process-scoped environment variable that points at a config file
      (Gemini CLI);
   3. a process-scoped environment variable that holds inline config
      (OpenCode).
   If the only way to add a server is to edit the user's global or project
   config, leave the preset unwired. Do not add a hidden config edit to make it
   work.

2. **Add the preset** to `AgentPreset.all`:

   ```swift
   AgentPreset(
       id: "agentx",
       title: "Agent X",
       binary: "agentx",
       arguments: [],
       symbol: "sparkle"
   ),
   ```

   - `id` is stable; it is stored in plans and used by the plugin's `preset`
     argument. Do not rename it casually.
   - `binary` is the executable name that `AgentCatalog.resolveProgram` looks
     up in the GUI app's small `PATH` (plus `~/.local/bin`, `~/bin`,
     `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`).
   - `arguments` are defaults for every launch. The plugin appends its own
     arguments after these.

3. **Extend `FleetPluginEndpoint` only when needed.** Keep new fields optional
   with a default so existing callers and tests keep compiling:

   ```swift
   public var agentxConfigPath: String?
   ```

   Do not put the URL in a new field; it is already `url`.

4. **Write the config in `FleetPluginFiles`.** Use the private
   `prepareDirectory` (0700) and `write` (0600) helpers. Merge into any base
   config instead of overwriting it. Return `nil` when a required base file
   exists but cannot be parsed, so the session starts unwired instead of
   shadowing the user's settings. Add a focused test for the writer.

5. **Add a case to `FleetPluginLaunch.spec`:**

   ```swift
   case "agentx":
       guard let path = endpoint.agentxConfigPath else { return FleetPluginSpec() }
       return FleetPluginSpec(environment: ["AGENTX_MCP_CONFIG": path])
   ```

   Return both `arguments` and `environment` when a CLI needs both. Leave the
   `default` branch returning an empty spec: unsupported is better than wrong.

6. **Create the artifact in `PluginServer.start`.** Add its path to
   `FleetPluginEndpoint`, and append the file URL to `configURLs` so `stop()`
   removes it. Write only inside the per-user temp directory
   (`fleet-plugin-<uid>`), never into the working directory or home config.

7. **Test the three paths** in `PluginHandlerTests`:
   - writer: JSON shape, merged keys, `0600` permissions;
   - spec: exact arguments and environment, and empty specs for unsupported
     presets;
   - child session and plan step: `orchestrate` create and `plan` put both
     carry the new environment to the daemon, and plan steps do **not** carry
     `FLEET_SESSION_ID` yet.

8. **Verify by hand** with the installed CLI (see
   [Verification](#verification)), then run the app build and tests.

9. **Update this table**, the known limitations, and any user-visible preset
   list in `README.md` / `apps/macos/README.md`.

### What not to do

- Do not write `~/.claude.json`, `~/.codex/config.toml`,
  `~/.gemini/settings.json`, `~/.cursor/mcp.json`, or
  `~/.config/opencode/opencode.json`.
- Do not shell out to `claude mcp add`, `gemini mcp add`, `opencode mcp add`,
  or similar during session startup.
- Do not pass trust-skipping or permission-bypassing flags
  (`--skip-trust`, `--dangerously-skip-permissions`, `--auto`, …) to make MCP
  load. The user's own permission settings stay in effect.
- Do not log the endpoint, token, or generated config contents. Error messages
  should name the agent, not the URL.
- Do not make cleanup remove paths outside `fleet-plugin-<uid>`.

## How the current agents differ

These notes explain why each case looks the way it does and what to check when
upgrading.

### Claude Code

`--mcp-config` points at `claude-mcp.json` containing an `mcpServers.fleet`
entry with `type: "http"`. Fleet does **not** pass `--strict-mcp-config`, so
the user's own MCP servers still load. The file is in the temp directory; the
URL is not on the command line.

Check:

```sh
claude --help | rg -- '--mcp-config|--strict-mcp-config'
```

### Codex

Codex accepts a per-launch override, so Fleet passes:

```text
-c mcp_servers.fleet.url="http://127.0.0.1:<port>/mcp/<token>"
```

The URL is in the process arguments. Any process running as the same user can
read it with `ps`; the token is loopback-only and rotates when Fleet relaunches.

Check:

```sh
codex --help | rg -- '-c'
```

### Gemini CLI

Gemini CLI has no per-launch MCP flag. Its settings hierarchy includes a
system-settings file, which is the highest-precedence JSON layer, and
`GEMINI_CLI_SYSTEM_SETTINGS_PATH` overrides that path. Fleet:

1. resolves the system-settings path from the app's own environment, or
   `/Library/Application Support/GeminiCli/settings.json` when unset;
2. reads it if it exists and copies its contents;
3. adds `mcpServers.fleet = { "httpUrl": "<url>" }`;
4. writes `gemini-settings.json` in the fleet temp directory (0600) and sets
   `GEMINI_CLI_SYSTEM_SETTINGS_PATH` for the session.

The `mcpServers` setting uses `shallow_merge` in Gemini CLI: other server names
are preserved, but a same-named `fleet` entry is replaced.

If the existing system-settings file cannot be parsed as strict JSON, Fleet
returns no path and Gemini stays unwired for that run. This is deliberate:
pointing the CLI at a partial file would shadow enterprise settings. JSONC
comments in that file also make it unparseable for this writer.

Gemini CLI 0.46 disables MCP servers in an untrusted folder. Trust the
workspace in Gemini's own UI (or start it once yourself and trust it). Fleet
does not pass `--skip-trust`.

Check:

```sh
GEMINI_CLI_SYSTEM_SETTINGS_PATH=/path/to/gemini-settings.json gemini mcp list
```

The server should appear as `fleet`. In an untrusted folder it may appear as
`Disabled`; that is the folder-trust gate, not a wiring failure.

### OpenCode

OpenCode reads configuration from the environment only when it runs its own
server. By default the CLI attaches to a shared background service. That
service ignores the environment of the client that attaches to it, so setting
`OPENCODE_CONFIG_CONTENT` alone is ignored. Fleet therefore launches:

```text
opencode --standalone
```

with `OPENCODE_CONFIG_CONTENT` set to:

```json
{"mcp":{"fleet":{"type":"remote","url":"http://127.0.0.1:<port>/mcp/<token>"}}}
```

OpenCode v2 normalizes the legacy `mcp.<name>` shape to `mcp.servers.<name>`.
It then merges `mcp.servers` from every configuration document, so the user's
own servers remain. A later document (the injected one) wins only for a
server with the same name.

If a future OpenCode version stops normalizing the legacy shape, switch
`FleetPluginFiles.opencodeConfig` to the canonical form:

```json
{"mcp":{"servers":{"fleet":{"type":"remote","url":"..."}}}}
```

and update the writer test.

Check:

```sh
OPENCODE_CONFIG_CONTENT='{"mcp":{"fleet":{"type":"remote","url":"http://127.0.0.1:9/mcp/x"}}}' \
  opencode --standalone debug config
```

Look for an `OPENCODE_CONFIG_CONTENT` document containing `mcp.servers.fleet`.
In v2.2.5, `opencode --standalone mcp list` can report “No MCP servers
configured” even when `debug config` shows the document; use `debug config`
for the config check and a real session for the tool check.

## Verification

For every preset change:

1. Build and run the app:

   ```sh
   apps/macos/scripts/build.sh
   apps/macos/scripts/verify-terminal.sh
   ```

   The terminal harness runs the FleetKit tests, a real daemon on a temporary
   socket, and `FleetProbe --smoke`.

2. Start a session with the preset in a trusted working directory.
3. Confirm the agent sees the `orchestrate`, `watch`, and `plan` tools.
   - Ask it to call `orchestrate` with `action: "create"`, a `preset`, and a
     `cwd`; the new session should appear in Fleet.
   - Or inspect the agent's own MCP server list.
4. Quit Fleet. The generated files under `fleet-plugin-<uid>` should be gone,
   and the user's own config should be unchanged. If dotfiles are tracked,
   `git diff` before/after is the simplest check.
5. Relaunch Fleet and repeat. A new port and token must be used; no stale
   server should be listed.

For a quick config-only check, the commands in each agent section above show
whether that CLI reads the mechanism Fleet uses. They do not prove the tools
are callable; step 3 does.

## Security rules

- The server binds `127.0.0.1` only. The bearer token is the URL path and is
  compared in constant time. Nothing about a request is logged.
- Treat the URL as a capability: whoever has it can create and stop sessions
  and read task and plan state. Keep it in the process environment or a `0600`
  file.
- Generated files are `0600`; the containing directory is `0700`.
- Configuration is per process. Fleet must leave no change that affects the
  user's next `claude`, `codex`, `gemini`, or `opencode` run.
- Never weaken folder trust or permission prompts to make the integration
  work. If an agent disables MCP in an untrusted folder, document that the
  user must trust the folder.
- Only start the plugin when the daemon advertises the `tasks` capability.
  Without it the tools cannot do anything.

## Known limitations

- Cursor Agent is not wired. The tested version has no process-scoped MCP
  configuration mechanism that Fleet can use without editing
  `~/.cursor/mcp.json`.
- Shell and custom commands are not agents and never receive the plugin.
- Gemini CLI requires a trusted workspace, and an unparseable (including
  JSONC) administrator settings file means Gemini starts without the plugin
  for that run.
- OpenCode must run with `--standalone`, so a Fleet session does not share the
  background service's state with other OpenCode windows.
- Codex receives the URL in its process arguments, which is readable by other
  processes of the same user (`ps`). The token is loopback-only and rotates
  when Fleet relaunches.
- A crash can leave files in the per-user temp directory. The next start
  overwrites the same file names. Do not add cleanup that deletes outside
  `fleet-plugin-<uid>`.
- The plugin requires the daemon's `tasks` capability. A daemon without it
  starts the UI but not the MCP server.
- The macOS app is the only client that starts the plugin today. A future CLI
  or remote client would need its own endpoint and config strategy.

## Maintenance

When an agent changes its config format or flags:

1. Reproduce with the check command in its section.
2. Change only the writer or the `spec` case that owns that agent.
3. Update the writer/spec/child-session tests.
4. Bump the “Verified with” row after a successful manual check.
5. If the mechanism disappears, remove the case and move the preset to the
   unwired list rather than writing user config as a fallback.

Keep the integration shallow: one preset list, one `spec` switch, one writer
per mechanism, and one cleanup list. That is what makes the next agent cheap to
add.
