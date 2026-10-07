# Channel: Scoop, not winget

**Status**: accepted

We distribute via a personal Scoop bucket (`bucket/git-gui-dark.json` in this repo), not winget. Winget rejects `.ps1` installers — its community-repo policy explicitly disallows scripts as installers, and the `portable` installer type only handles `.exe` — so shipping there would require wrapping the script with PS2EXE (which triggers antivirus false positives) or building a real EXE/MSI installer, both out of scope for a packaging-only pass on a personal tool. Scoop accepts `.ps1` directly via a JSON manifest, the audience is one person, and a personal bucket has no PR-review gate, so the trade-off favors least-moving-parts over reach.

## Considered options

- **Winget** — rejected. Would require `.exe` wrapping or a real installer.
- **ScoopInstaller/Main PR** — rejected. Higher bar (README, license, version history, moderator review) than the personal-tool scope warrants.
- **Self-hosted winget source** — rejected. Discoverability and ergonomics are worse than Scoop for a single-user audience.
- **PowerShell Gallery** — rejected. Smaller audience, requires a `.psd1` module manifest, and adds a second publication surface.

## Consequences

- All distribution goes through a JSON manifest under `bucket/`. There is no `.exe` build pipeline and no winget-pkgs PR to maintain.
- The script's `.ps1` source is the installable artifact (bundled into a release zip). If the user later wants winget reach, the path is to add a PS2EXE build step and a separate winget manifest under `winget/`.
