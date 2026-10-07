# External Tcl template + zip release artifact

**Status**: accepted

The Tcl that sets the dark palette lives in `assets/bootstrap.tcl` as a separate file in the repo, not as an inline here-string inside `git-gui-dark.ps1`. The release artifact is therefore a zip containing both `git-gui-dark.ps1` and `bootstrap.tcl` at the root, downloaded and extracted by Scoop. The `.ps1` reads the template at install time via `$PSScriptRoot\bootstrap.tcl` and performs the placeholder substitution (`__GITGUI_TCL_PATH__`, `__GIT_BIN_PATHS__`) before writing the rendered output to `%LOCALAPPDATA%\git-gui-dark\bootstrap.tcl`. This makes the Tcl editable in a real editor and keeps the `.ps1` focused on PowerShell, at the cost of a small per-release zip step (manual today; trivially scriptable later if it becomes friction).

## Considered options

- **Inline here-string** — rejected. Tcl inside a PowerShell single-quoted here-string is fragile (`$` and `[...]` interact awkwardly), and the Tcl is much easier to read and edit in a dedicated file with proper syntax highlighting.
- **External + build step that inlines before release** — deferred. Would be the right choice at a higher polish bar, but adds a build script for one user.

## Consequences

- The release process is now: bump `VERSION`, update `bucket/git-gui-dark.json` (version + url + hash), commit, tag, create a GitHub release with a zip of `src/git-gui-dark.ps1` and `assets/bootstrap.tcl` at the root attached. Manual today.
- The `.ps1` has a hard dependency on `bootstrap.tcl` sitting next to it. If the script is ever run from a location where the template is not present (e.g. someone `iwr`s just the `.ps1` and runs it), `install` must fail with a clear error rather than silently writing a broken bootstrap.
- The Scoop manifest's `url` is the zip, not the raw `.ps1`. The `bin` field still points at the `.ps1`; Scoop extracts the zip and creates a shim to that file.
