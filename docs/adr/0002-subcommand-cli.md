# Subcommand CLI surface

**Status**: accepted

The script exposes a subcommand-style interface (`git-gui-dark install`, `git-gui-dark uninstall`, `git-gui-dark run`, `git-gui-dark help`) instead of the original PowerShell switch verbs (`-Install`, `-Run`, `-Uninstall`). The switch style mapped poorly to a Scoop shim — `git-gui-dark -Install` reads as a flag, not a command — and the audience will install via Scoop, not by invoking the `.ps1` directly. Subcommands are explicit, memorable, and align with what the shim is actually doing: dispatching to one of four functions. No new user-facing features are added; the existing `-Force` / `-GitPath` / `--working-dir` flags are ported to the appropriate subcommands.

## Considered options

- **Keep switch surface** — rejected. A shim named `git-gui-dark` leads users to expect a command, not flags. Documenting `git-gui-dark -Install` as the install path would also be misleading once Scoop handles the install.
- **Subcommands + new verbs (e.g. `update`)** — deferred. `update` is a real verb, but `scoop update git-gui-dark` already covers it. Adding it to the script would duplicate Scoop's own update flow.

## Consequences

- The script gains a top-level `switch ($args[0])` dispatcher and four handler functions. Each handler binds its own named parameters (`install` takes `-Force` and `-GitPath`; `run` takes `-GitPath` and `--working-dir` via passthrough; `uninstall` takes `-Force`).
- The default action (no subcommand) is `run`, so a bare `git-gui-dark` launches git-gui in dark mode once installed.
- `git-gui-dark help` replaces the old no-args-help path. The switch-style help blurb becomes the body of the `help` subcommand.

## Subcommand set

| Subcommand | Flags | Purpose |
|---|---|---|
| (default) | forwarded to `run` | Launch git-gui through the bootstrap |
| `install` | `-Force`, `-GitPath <p>` | Write bootstrap + register context-menu override |
| `uninstall` | `-Force` | Remove bootstrap + context-menu override |
| `run` | `-GitPath <p>`, passthrough args | Launch git-gui through the bootstrap (explicit) |
| `help` | — | Show usage |
