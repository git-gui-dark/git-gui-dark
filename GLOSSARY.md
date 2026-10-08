# git-gui-dark

A dark-theme launcher for the official Git GUI on Windows, distributed as a single-file PowerShell script and packaged for the Scoop package manager from a personal bucket in this repo.

## Language

**Bootstrap (Tcl)**:
The generated Tcl file written to `%LOCALAPPDATA%\git-gui-dark\bootstrap.tcl` at install time, after path substitution. It sets a dark Tk palette and hands off to the real `git-gui.tcl`.
_Avoid_: launcher, proxy, wrapper

**Tcl template**:
The source file at `assets/bootstrap.tcl` in the repo, before path substitution. Bundled into the release zip alongside `git-gui-dark.ps1`; rendered into the bootstrap at install time.
_Avoid_: bootstrap file, palette script

**Context-menu override**:
The HKCU registry key (`HKCU\Software\Classes\Directory\shell\git_gui`) that launches `git-gui-dark run` when the user right-clicks a folder and chooses "Open Git GUI here". Mirrors the label and icon of the system entry.
_Avoid_: context menu, right-click entry, shell extension

**Bucket**:
A git repository of Scoop manifest JSON files, referenced by `scoop bucket add` as an install source. This project ships a personal bucket as a subdirectory of its own repo (`bucket/`).
_Avoid_: feed, registry, repository

**Manifest**:
The JSON file at `bucket/git-gui-dark.json` that describes the app to Scoop: version, download URL, SHA-256 hash, install behavior, shim name.
_Avoid_: definition, spec, descriptor

**Shim**:
A Scoop-generated launcher file (`.ps1` / `.cmd` / extensionless) that invokes the underlying tool. The shim name defaults to the file name minus extension; the `bin` field in the manifest controls which file becomes a shim.
_Avoid_: launcher, wrapper, alias

**Subcommand**:
A top-level positional argument (`install`, `uninstall`, `run`, `help`) that selects which function the script executes. Replaces the original `-Install` / `-Run` / `-Uninstall` switch surface.
_Avoid_: verb, command, action

**Version file**:
The single `VERSION` file at the repo root holding a SemVer string (e.g. `1.0.0`). Single source of truth for the current release; the Scoop manifest's `version` field mirrors it.
_Avoid_: version stamp, release marker, tag

**Release zip**:
The zip file attached to each GitHub release. For Spec 0002 / T1 + T2 (v1.1.0+), it contains exactly five entries at the root: `git-gui-dark.ps1`, `win32-dark.ps1`, `bootstrap.tcl`, `supported-builds.json`, and the `cffi/` subdirectory. The Scoop manifest's `url` points at this zip; the manifest's `hash` is the zip's SHA-256. Full layout: `docs/adr/0003-external-tcl-zip-release.md`.
_Avoid_: release archive, distributable, bundle

**Darkmode config**:
The Tcl flag file at `%LOCALAPPDATA%\git-gui-dark\darkmode-config.tcl`, written at install time from the build's match against `supported-builds.json`. Sets a single `menuDarkModeEnabled` flag the bootstrap reads to gate the in-process cffi/uxtheme calls. The T1 title-bar helper is unaffected.
_Avoid_: darkmode flag, menu-dark toggle, install-time config

**Helper module**:
The sibling PowerShell file at `src/win32-dark.ps1` (bundled into the release zip as `win32-dark.ps1`). Contains the OS-detection, allowlist-match, and DWM-applier functions; dot-sourced by the launcher at startup. Optional at runtime — missing file = silent no-op.
_Avoid_: dark-mode module, helper script, dark module

**Allowlist**:
The JSON file at `supported-builds.json` at the repo root (bundled into the release zip unchanged). An array of `{ family, build, revision, displayVersion }` objects the helper matches against the running OS to decide whether to apply title-bar darkening. An empty array (or missing file) is a no-match.
_Avoid_: support list, build allowlist, compat list

**CFFI bundle**:
The prebuilt `cffi` Tcl extension under `assets/cffi/` (bundled into the release zip as `cffi/`). BSD-2-Clause, ships with LICENSE. Loaded by the bootstrap via `package require cffi` after `auto_path` is extended; the bootstrap resolves the in-process uxtheme ordinals (135 / 136 / 133) and calls them via `cffi::call`. Optional at runtime — missing bundle = silent no-op.
_Avoid_: cffi, FFI, uxtheme shim
