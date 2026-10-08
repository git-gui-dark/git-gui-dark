# External Tcl template + zip release artifact

**Status**: accepted (updated 2026-10-08 for Spec 0002 / T1 + T2 release layout)

The Tcl that sets the dark palette lives in `assets/bootstrap.tcl` as a separate file in the repo, not as an inline here-string inside `git-gui-dark.ps1`. The release artifact is therefore a zip containing the launcher and all of its non-PowerShell siblings, downloaded and extracted by Scoop. The `.ps1` reads its bundled resources at install time via two-path resolution: the release layout (`$PSScriptRoot\<name>`) wins, the source layout (`$PSScriptRoot\..\assets\<name>` for repo-tree bundled assets, or `$PSScriptRoot\..\<name>` for files at the repo root) is the fallback used when the script runs from a checkout rather than an extracted Scoop download. The same resolution handles the Tcl placeholders (`__GITGUI_TCL_PATH__`, `__GIT_BIN_PATHS__`), which the launcher substitutes before writing the rendered output to `%LOCALAPPDATA%\git-gui-dark\bootstrap.tcl`. This keeps Tcl editable in a real editor and the `.ps1` focused on PowerShell, at the cost of a small per-release zip step (manual today; trivially scriptable later if it becomes friction).

## Zip root contents (Spec 0001 + 0002)

For a v1.1.0+ release, the zip contains exactly five entries at the root:

| File                    | Source-tree location        | Purpose                                                            |
|-------------------------|-----------------------------|--------------------------------------------------------------------|
| `git-gui-dark.ps1`      | `src/git-gui-dark.ps1`      | Launcher                                                           |
| `win32-dark.ps1`        | `src/win32-dark.ps1`        | Win32 dark-mode helper (Spec 0002 / T1); optional at runtime       |
| `bootstrap.tcl`         | `assets/bootstrap.tcl`      | Tcl dark-mode template (Spec 0001)                                 |
| `supported-builds.json` | `supported-builds.json`     | Win32 build allowlist consumed by the helper (Spec 0002 / T1)      |
| `cffi/`                 | `assets/cffi/`              | Bundled CFFI extension + prebuilt DLLs for menu dark-mode (Spec 0002 / T2) |

Adding a new bundled resource means: add a row above, copy it to `$PSScriptRoot\<name>` at release time, and either extend the launcher's two-path resolution (if it's optional like the CFFI bundle) or rely on direct presence (like `supported-builds.json`).

## Considered options

- **Inline here-string** — rejected. Tcl inside a PowerShell single-quoted here-string is fragile (`$` and `[...]` interact awkwardly), and the Tcl is much easier to read and edit in a dedicated file with proper syntax highlighting.
- **External + build step that inlines before release** — deferred. Would be the right choice at a higher polish bar, but adds a build script for one user.

## Consequences

- The release process is now: bump `VERSION`, rebuild the zip containing the five entries above, compute SHA-256 of the zip, update `bucket/git-gui-dark.json` (version + url + hash), commit, tag (`v<version>`), create a GitHub release with the zip attached. Manual today.
- The `.ps1` reads `bootstrap.tcl` at install time and, on supported builds, also reads `win32-dark.ps1` + `supported-builds.json` + `cffi\`. Each is resolved via two-path resolution (`$PSScriptRoot\<name>` for the release layout, `$PSScriptRoot\..\assets\<name>` or `$PSScriptRoot\..\<name>` for the source layout). If a file is missing, the corresponding feature is a **silent no-op** — no error, no log, no warning. This matches Spec 0002's "silent skip on unsupported builds" rule: nothing about the helper is a correctness requirement, so a missing helper file never breaks `install`. The existing `Throw` in `Get-TclTemplate` for a missing `bootstrap.tcl` is a historical artefact from before Spec 0002; the helper resources are uniformly silent-no-op by design.
- The Scoop manifest's `url` is the zip, not the raw `.ps1`. The `bin` field still points at the `.ps1`; Scoop extracts the zip and creates a shim to that file.
- Two-path resolution is duplicated in three places today (`Get-TclTemplate`, `Get-CffiBundleSource`, `Get-SupportedBuilds`). Future consolidation into one `Resolve-BundledResourcePath` helper would be a small DRY win; accepted today as the cost of separate Pester test files per PowerShell file.
