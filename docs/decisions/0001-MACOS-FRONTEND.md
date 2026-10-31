# 0001. Use SwiftUI with SwiftTerm for the macOS frontend

Status: accepted for the issue #4 prototype
Date: 2026-10-27
Issue: [#4](https://github.com/nsrul/fleet/issues/4)

## Context

Fleet needs a desktop frontend that can show one project with two live agent
sessions, send keyboard input, render Unicode, support selection and scrollback,
and reflow terminals when panes or the window resize. The daemon already owns the
PTYs and exposes raw bytes over the local Unix-socket API.

The initial architecture considered GPUI for a Rust interface across desktop
platforms or SwiftUI with AppKit for a Mac-focused app. The first prototype is
Mac-only, and the team chose SwiftUI to move quickly with native windowing,
menus, settings, accessibility, and AppKit integration.

Terminal rendering is the main dependency decision. A terminal widget has to
handle escape sequences, wide and combining characters, selection, scrollback,
keyboard modes, mouse reporting, and PTY resize. Writing that layer in the
prototype would dominate the work and produce a worse terminal than an
established implementation.

## Decision

Use SwiftUI for the application shell and AppKit through `NSViewRepresentable`
where SwiftUI cannot host the terminal directly. Use
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.99.1 (MIT) for terminal
emulation and rendering on macOS.

The daemon remains the owner of agent processes and PTYs. The app is a client:
it attaches to sessions, feeds raw output bytes into SwiftTerm, forwards keyboard
input, and sends the terminal grid size on layout changes. SwiftTerm owns
terminal state, scrollback, selection, clipboard behavior, and rendering.

The prototype targets macOS 14+ on Apple Silicon. It is ad-hoc signed and not
sandboxed. The Xcode project is generated from `apps/macos/project.yml` with
XcodeGen and checked in so the app can be built without XcodeGen installed.

## Alternatives considered

| Alternative | Why not now |
| --- | --- |
| GPUI | Keeps the UI in Rust and could share types with the daemon, but it is less mature for native macOS controls, accessibility, menus, and settings. The prototype would spend more time on UI plumbing than on validating live terminals. |
| AppKit only | Native and predictable, but slower to build the sidebar, panels, sheets, and state-driven layout than SwiftUI. AppKit is still used for the terminal host. |
| Electron or Tauri with a web terminal (xterm.js) | Cross-platform and strong terminal support, but adds a web runtime and a second rendering stack to a Mac-first prototype. It also makes native window and menu behavior less direct. |
| Custom terminal renderer | Full control, but escape-sequence coverage, Unicode width handling, selection, and scrollback are a large project on their own and would not improve the prototype's core question. |
| libvterm or another C terminal core with a custom view | A credible path, but SwiftTerm already packages a maintained terminal core with a native macOS view and is MIT licensed. |

## Consequences

- The frontend is Mac-only for now. A Windows or Linux frontend would need a
  separate implementation or a new cross-platform decision.
- SwiftTerm is a third-party dependency. It is pinned to an exact version, and
  local builds pass `-skipPackagePluginValidation` because of its build-tool
  plugin. Upgrades need a pass over keyboard, Unicode, selection, scrollback,
  and resize behavior.
- The app depends on AppKit interop for the terminal view and first responder
  handling. SwiftUI owns the surrounding layout and state.
- The daemon protocol stays terminal-agnostic. It carries raw bytes, so the
  frontend can change terminal widgets without changing the daemon.
- Because the daemon has no terminal-state snapshot yet, reattachment replays
  bounded raw output and SwiftTerm reconstructs what it can. Issue #5 should
  define snapshot or ordered-replay semantics before the UI claims exact screen
  restoration.
- SwiftTerm 1.99.1's `TerminalView.becomeFirstResponder` is not `open`, so focus
  is requested through the window rather than by overriding that method.

## Verification

The prototype was built with Xcode 27.1 / Swift 6.4 on macOS 27 and exercised
with Claude Code 2.1.311 and Gemini CLI 0.46.0. Two panes attached to independent
sessions; keyboard input, Unicode (`café 日本語`), selection and copy, scrollback,
window resize (PTY grid 83×20 → 51×18), and focus switching all worked. The
protocol smoke test also covers input/output, Unicode, resize, and exit against
a real daemon.

See [`apps/macos/README.md`](../../apps/macos/README.md) for build, run, demo,
and verification commands and the full results table.

## Follow-ups

- Revisit a cross-platform frontend when Windows or Linux becomes a target.
- Add a macOS CI job once the prototype stabilizes.
- Define terminal-state snapshots and replay in issue #5.
- Replace ad-hoc signing with a real signing and notarization process before
  distributing the app. Developer ID signing for a local release zip is
  documented in [`docs/RELEASE.md`](../RELEASE.md). Notarization is still open.
