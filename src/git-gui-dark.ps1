<#
.SYNOPSIS
    Install, run, or uninstall a dark theme for git-gui (the official Git GUI).

.DESCRIPTION
    Git GUI does not have a built-in dark theme. This script:

      - Writes a small Tcl bootstrap to %LOCALAPPDATA%\git-gui-dark that sets a
        dark Tk palette and hands off to the real git-gui.tcl.
      - Optionally adds an HKCU registry override so Windows Explorer's
        "Open Git GUI here" context-menu entry launches git-gui in dark mode.
      - On supported Windows builds, also drives DWMWA_USE_IMMERSIVE_DARK_MODE
        so the OS title bar of git-gui's main window renders dark.

    Nothing inside the Git installation itself is modified.

    The script exposes a subcommand-style CLI:

        git-gui-dark <subcommand> [flags]

    Subcommands: install, uninstall, run, help. With no subcommand, `run` is
    assumed (so a bare `git-gui-dark` launches git-gui in dark mode once
    installed).

    The Tcl template is read at install time from bootstrap.tcl. The script
    looks for it in two places (in order):

      1. $PSScriptRoot\bootstrap.tcl            - release layout (zip root)
      2. $PSScriptRoot\..\assets\bootstrap.tcl  - source layout (this repo)

    If neither exists, `install` exits with a clear error rather than writing
    a broken bootstrap.

.PARAMETER Subcommand
    One of: install, uninstall, run, help. Omit to default to `run`.

.PARAMETER Force
    On `install`: overwrite an existing bootstrap without prompting.
    On `uninstall`: skip the confirmation prompt.

.PARAMETER GitPath
    Override the Git for Windows installation path. Defaults to auto-detect
    C:\Program Files\Git (and its 32-bit sibling). Honoured by `install` and
    `run`.

.PARAMETER Passthrough
    Any extra tokens (e.g. --working-dir C:\path\to\repo) are forwarded to
    wish / git-gui verbatim when the subcommand is `run`. Mirrors the Windows
    "Open Git GUI here" context-menu command.

.EXAMPLE
    PS> git-gui-dark help
    # Print the subcommand set and per-subcommand flag list.

.EXAMPLE
    PS> git-gui-dark
    PS> git-gui-dark run
    # Launch git-gui in dark mode (assumes `install` has been run first).

.EXAMPLE
    PS> git-gui-dark run --working-dir C:\path\to\repo
    # Launch git-gui in C:\path\to\repo using the dark theme.

.EXAMPLE
    PS> git-gui-dark install
    PS> git-gui-dark install -Force
    PS> git-gui-dark install -GitPath 'D:\portable\Git'
    # Install / refresh the dark theme bootstrap and context-menu override.

.EXAMPLE
    PS> git-gui-dark uninstall
    PS> git-gui-dark uninstall -Force
    # Remove the dark theme bootstrap + context-menu override.

.NOTES
    Part of Spec 0001 (issue #1) + Spec 0002 / T1 (issue #8). The Tcl
    template lives in assets\bootstrap.tcl in this repo; the release zip
    flattens it to the root next to the script. The optional Win32 dark-mode
    helper (win32-dark.ps1) is also at the zip root in the release layout
    and at src\win32-dark.ps1 in the source layout; it is dot-sourced at
    startup and is a no-op when absent or when the running build is not on
    the allowlist.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [string]$Subcommand,

    [switch]$Force,
    [string]$GitPath,

    # Anything PowerShell can't bind to a named param lands here. Forwarded to
    # wish / git-gui verbatim (e.g. --working-dir "%1" from the context menu).
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Passthrough
)

$ErrorActionPreference = 'Stop'

# ----- Storage location ----------------------------------------------------

$darkDir   = Join-Path $env:LOCALAPPDATA 'git-gui-dark'
$bootstrap = Join-Path $darkDir 'bootstrap.tcl'

# ----- Optional helper: Win32 dark-mode (Spec 0002 / T1) -------------------
# The helper is optional. If win32-dark.ps1 is not bundled next to the
# launcher (e.g. an older release still in use), git-gui-dark.ps1 must
# keep working - the existing Tk-palette dark theme is the safety net.
# Dot-sourcing the helper exposes Apply-Win32DarkModeToPid to Launch-GitGui.
$win32DarkHelperPath = $null
foreach ($p in @((Join-Path $PSScriptRoot 'win32-dark.ps1'))) {
    if (Test-Path -LiteralPath $p) {
        $win32DarkHelperPath = (Resolve-Path -LiteralPath $p).Path
        break
    }
}
if ($win32DarkHelperPath) {
    . $win32DarkHelperPath
}

# ----- Helpers (lower-priority test seams per Spec 0001) -------------------

function Find-GitForWindows {
    param([string]$Hint)

    $candidates = @()
    if ($Hint) { $candidates += $Hint }
    $candidates += @(
        (Join-Path ${env:ProgramFiles} 'Git'),
        'C:\Program Files\Git',
        'C:\Program Files (x86)\Git'
    ) | Where-Object { $_ }

    foreach ($p in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path $p)) { continue }
        foreach ($a in @('ucrt64', 'mingw64', 'mingw32')) {
            $w = Join-Path $p "$a\bin\wish.exe"
            $g = Join-Path $p "$a\libexec\git-core\git-gui.tcl"
            if ((Test-Path $w) -and (Test-Path $g)) {
                # git-gui.tcl uses cygpath (which lives in usr/bin), so we need
                # BOTH the arch bin (where wish.exe lives) and usr/bin in PATH.
                return [pscustomobject]@{
                    Root      = $p
                    Arch      = $a
                    Wish      = $w
                    GitGuiTcl = $g
                    GitBins   = @(
                        (Join-Path $p "$a\bin"),
                        (Join-Path $p "usr\bin")
                    )
                }
            }
        }
    }
    return $null
}

function Get-TclTemplate {
    # Two-path resolution: release layout (script + template at the same
    # directory) wins, then source layout (script in src/, template in
    # ../assets/). Returns the template content as a string. If neither path
    # resolves, prints a clear error and exits non-zero so `install` does not
    # write a broken bootstrap.
    $candidates = @(
        (Join-Path $PSScriptRoot 'bootstrap.tcl'),
        (Join-Path $PSScriptRoot '..\assets\bootstrap.tcl')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) {
            $resolved = (Resolve-Path -LiteralPath $p).Path
            # Use UTF-8 WITHOUT BOM - Tcl parses a BOM as junk at line 1 and
            # errors out. The .NET UTF8Encoding($false) ctor is the no-BOM form.
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            return [pscustomobject]@{
                Path    = $resolved
                Content = [System.IO.File]::ReadAllText($resolved, $utf8NoBom)
            }
        }
    }
    Write-Host "Tcl template not found next to the script." -ForegroundColor Red
    Write-Host ("Looked for: " + ($candidates -join ' ; ')) -ForegroundColor Yellow
    exit 1
}

function Write-BootstrapFromTemplate {
    param(
        [string]$Template,
        [string]$GitGuiTclPath,
        [string[]]$GitBinPaths,
        [string]$Output,
        [string]$Dir
    )
    if (-not (Test-Path $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $gitGuiTclTcl = $GitGuiTclPath -replace '\\', '/'
    # Build a Tcl list literal: each path is a brace-quoted element.
    $gitBinTcl = ($GitBinPaths | ForEach-Object { '{' + ($_ -replace '\\', '/') + '}' }) -join ' '
    $content = $Template.Replace('__GITGUI_TCL_PATH__', $gitGuiTclTcl)
    $content = $content.Replace('__GIT_BIN_PATHS__', $gitBinTcl)
    # Use UTF-8 WITHOUT BOM - Tcl parses a BOM as junk at line 1 and errors out.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Output, $content, $utf8NoBom)
}

function Register-ContextMenu {
    param(
        [string]$ScriptPath
    )

    $parentKey = 'HKCU:\Software\Classes\Directory\shell\git_gui'
    $cmdKey    = "$parentKey\command"

    if (-not (Test-Path $parentKey)) {
        New-Item -Path $parentKey -Force | Out-Null
    }
    Set-ItemProperty -Path $parentKey -Name '(default)' -Value 'Open Git &GUI here'
    $iconPath = 'C:\Program Files\Git\cmd\git-gui.exe'
    if (Test-Path $iconPath) {
        Set-ItemProperty -Path $parentKey -Name 'Icon' -Value $iconPath
    }

    if (-not (Test-Path $cmdKey)) {
        New-Item -Path $cmdKey -Force | Out-Null
    }
    $cmdValue = 'powershell.exe -ExecutionPolicy Bypass -File ' +
                '"' + $ScriptPath + '"' +
                ' run --working-dir "%1"'
    Set-ItemProperty -Path $cmdKey -Name '(default)' -Value $cmdValue

    Write-Host "Context-menu override installed." -ForegroundColor Green
    Write-Host ("  " + $cmdValue) -ForegroundColor DarkGray
}

function Unregister-ContextMenu {
    $parentKey = 'HKCU:\Software\Classes\Directory\shell\git_gui'
    if (Test-Path $parentKey) {
        Remove-Item -Path $parentKey -Recurse -Force
        Write-Host "Context-menu override removed." -ForegroundColor Green
    }
    else {
        Write-Host "Context-menu override was not installed." -ForegroundColor DarkGray
    }
}

function Launch-GitGui {
    param(
        [string]$Wish,
        [string]$Bootstrap,
        [string[]]$Passthrough
    )
    $argList = @($Bootstrap) + $Passthrough

    # Start-Process -PassThru (rather than the call operator `&`) so the
    # parent process keeps a Process handle to wish.exe. This is what lets
    # Apply-Win32DarkModeToPid poll for the main window and apply
    # DWMWA_USE_IMMERSIVE_DARK_MODE before WaitForExit blocks.
    $proc = Start-Process -FilePath $Wish -ArgumentList $argList -PassThru

    # Spec 0002 / T1: on a supported Windows build, additionally apply
    # DWMWA_USE_IMMERSIVE_DARK_MODE to wish.exe's main window so the OS
    # title bar renders dark. Silent no-op if the helper is absent or the
    # build is not on the allowlist; never throws.
    if (Get-Command -Name Apply-Win32DarkModeToPid -ErrorAction SilentlyContinue) {
        try {
            Apply-Win32DarkModeToPid -Process $proc
        }
        catch {
            # A dark-mode failure must never break a launch.
        }
    }

    $proc.WaitForExit()
}

# ----- Subcommand handlers (primary test seams per Spec 0001) -------------

function Invoke-Help {
@"
git-gui-dark - dark theme for the official Git GUI on Windows

Usage:
    git-gui-dark                       Launch git-gui in dark mode (alias for `run`)
    git-gui-dark help                  Show this help
    git-gui-dark install               Write bootstrap + register "Open Git GUI here" override
    git-gui-dark install -Force        Overwrite an existing install
    git-gui-dark install -GitPath <p>  Use <p> as the Git for Windows install root
    git-gui-dark run                   Launch git-gui in dark mode (assumes installed)
    git-gui-dark run --working-dir <p> Launch git-gui in <p>
    git-gui-dark uninstall             Remove the dark theme (asks to confirm)

On supported Windows builds (e.g. Win10 22H2 / 19045.6466+), `run` also
darkens the OS title bar of git-gui's main window. No flag needed; the
helper auto-skips on unsupported builds.
    git-gui-dark uninstall -Force      Remove the dark theme without prompting

Subcommand flags:
    install     -Force, -GitPath <p>
    uninstall   -Force
    run         -GitPath <p>, plus any trailing args forwarded to git-gui
    help        (no flags)

Full parameter descriptions and examples:
    Get-Help .\git-gui-dark.ps1 -Full
"@
}

function Invoke-Install {
    [CmdletBinding()]
    param(
        [switch]$Force,
        [string]$GitPath
    )

    $git = Find-GitForWindows -Hint $GitPath
    if (-not $git) {
        Write-Host "Could not find a Git for Windows installation." -ForegroundColor Red
        Write-Host "Use -GitPath 'C:\path\to\Git' to override." -ForegroundColor Yellow
        exit 1
    }

    Write-Verbose ("Git root     : " + $git.Root)
    Write-Verbose ("Architecture : " + $git.Arch)
    Write-Verbose ("wish.exe     : " + $git.Wish)
    Write-Verbose ("git-gui.tcl  : " + $git.GitGuiTcl)
    Write-Verbose ("Git bins     : " + ($git.GitBins -join '; '))

    $template = Get-TclTemplate
    Write-Verbose ("Tcl template : " + $template.Path)

    # 1. Bootstrap file
    $overwriteBootstrap = $true
    if ((Test-Path $bootstrap) -and -not $Force) {
        $answer = Read-Host "Bootstrap already installed at $bootstrap. Overwrite? (y/N)"
        if ($answer -ne 'y' -and $answer -ne 'Y') {
            Write-Host "Skipped bootstrap." -ForegroundColor Yellow
            $overwriteBootstrap = $false
        }
    }
    if ($overwriteBootstrap) {
        Write-BootstrapFromTemplate -Template $template.Content `
            -GitGuiTclPath $git.GitGuiTcl `
            -GitBinPaths $git.GitBins `
            -Output $bootstrap `
            -Dir $darkDir
        Write-Host "Dark theme bootstrap installed." -ForegroundColor Green
        Write-Host ("  " + $bootstrap) -ForegroundColor DarkGray
    }

    # 2. Context-menu override (HKCU-only; mirrors the system label/icon)
    $overwriteContextMenu = $true
    if ((Test-Path 'HKCU:\Software\Classes\Directory\shell\git_gui') -and -not $Force) {
        $answer = Read-Host "Context-menu override already installed. Re-register? (y/N)"
        if ($answer -ne 'y' -and $answer -ne 'Y') {
            Write-Host "Skipped context-menu override." -ForegroundColor Yellow
            $overwriteContextMenu = $false
        }
    }
    if ($overwriteContextMenu) {
        Register-ContextMenu -ScriptPath $PSCommandPath
    }
}

function Invoke-Uninstall {
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    if (-not $Force) {
        $answer = Read-Host "Remove the dark theme customization (bootstrap + context-menu override)? (y/N)"
        if ($answer -ne 'y' -and $answer -ne 'Y') {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }
    }

    # 1. Bootstrap file
    if (Test-Path $darkDir) {
        Remove-Item $darkDir -Force -Recurse
        Write-Host "Dark theme bootstrap removed." -ForegroundColor Green
    }
    else {
        Write-Host "Dark theme bootstrap was not installed." -ForegroundColor DarkGray
    }

    # 2. Context-menu override
    Unregister-ContextMenu
}

function Invoke-Run {
    [CmdletBinding()]
    param(
        [string]$GitPath,
        [string[]]$Passthrough
    )

    $git = Find-GitForWindows -Hint $GitPath
    if (-not $git) {
        Write-Host "Could not find a Git for Windows installation." -ForegroundColor Red
        Write-Host "Use -GitPath 'C:\path\to\Git' to override." -ForegroundColor Yellow
        exit 1
    }

    Write-Verbose ("Git root     : " + $git.Root)
    Write-Verbose ("Architecture : " + $git.Arch)
    Write-Verbose ("wish.exe     : " + $git.Wish)
    Write-Verbose ("git-gui.tcl  : " + $git.GitGuiTcl)

    if (-not (Test-Path $bootstrap)) {
        Write-Host "Dark theme is not installed. Run 'git-gui-dark install' first." -ForegroundColor Red
        exit 1
    }

    Write-Host "Launching Git GUI (dark)..." -ForegroundColor Cyan
    Launch-GitGui -Wish $git.Wish -Bootstrap $bootstrap -Passthrough $Passthrough
}

# ----- Dispatcher ---------------------------------------------------------

# No subcommand supplied -> default to `run` (a bare `git-gui-dark` launches
# git-gui in dark mode once installed). Subcommand match is case-insensitive.
$resolved = if ($Subcommand) { $Subcommand.ToLowerInvariant() } else { 'run' }

# A flag-shaped first token (e.g. `git-gui-dark --working-dir <p>`) means
# "bare run with passthrough" -- the spec's user story 3 "or" form. PowerShell's
# param binder already collected the flag + its value in $Passthrough; route
# to `run` and prepend the captured token so the run path sees the same argv
# it would for the explicit `run --working-dir <p>` form.
if ($Subcommand -like '-*') {
    $Passthrough = @($Subcommand) + $Passthrough
    $resolved = 'run'
}

switch ($resolved) {
    'help' {
        Invoke-Help
        return
    }
    'install' {
        Invoke-Install -Force:$Force -GitPath $GitPath
        return
    }
    'uninstall' {
        Invoke-Uninstall -Force:$Force
        return
    }
    'run' {
        Invoke-Run -GitPath $GitPath -Passthrough $Passthrough
        return
    }
    default {
        Write-Host ("Unknown subcommand: '{0}'" -f $Subcommand) -ForegroundColor Red
        Write-Host "Run 'git-gui-dark help' for usage." -ForegroundColor Yellow
        exit 1
    }
}
