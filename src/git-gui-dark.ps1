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
    Part of Spec 0001 (issue #1) + Spec 0002 / T1 (issue #8) + Spec 0002 /
    T2 (issue #9). The Tcl template lives in assets\bootstrap.tcl in this
    repo; the release zip flattens it to the root next to the script. The
    optional Win32 dark-mode helper (win32-dark.ps1) is also at the zip
    root in the release layout and at src\win32-dark.ps1 in the source
    layout; it is dot-sourced at startup and is a no-op when absent or when
    the running build is not on the allowlist. The bundled CFFI menu-dark
    package lives at cffi\ in the release zip root and at assets\cffi\ in
    the source layout; install copies it to %LOCALAPPDATA%\git-gui-dark\cffi\
    when the running build is on the supported-builds allowlist.
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

function Get-CffiBundleSource {
<#
.SYNOPSIS
    Locate the bundled CFFI package for the installer's Copy-CffiBundle.

.DESCRIPTION
    Two-path resolution identical in shape to Get-TclTemplate: release
    layout (the zip root has a `cffi\` directory next to git-gui-dark.ps1)
    wins, then source layout (this repo, where the launcher sits in
    `src\` and the bundle sits in `assets\cffi\`).

    Returns the resolved absolute path, or $null if neither candidate
    exists. Invoke-Install treats the missing case as installer-fatal:
    a release that omits CFFI is broken, and an in-tree run where
    `assets/cffi/` has been deleted is a hard error.

.PARAMETER ScriptRoot
    Override the directory used for the release-layout candidate lookup.
    Defaults to $PSScriptRoot (the launcher's own directory). Tests use
    this to drive isolated layouts.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$ScriptRoot = $PSScriptRoot
    )

    $candidates = @(
        (Join-Path $ScriptRoot 'cffi'),
        (Join-Path $ScriptRoot '..\assets\cffi')
    )
    foreach ($p in $candidates) {
        # PathType Container: a file (not a directory) named `cffi` at the
        # script root would otherwise match Test-Path, then blow up
        # confusingly inside Copy-CffiBundle. We want directories only.
        if (Test-Path -LiteralPath $p -PathType Container) {
            return (Resolve-Path -LiteralPath $p).Path
        }
    }
    return $null
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
    # -WindowStyle Hidden: keep the spawned PS terminal invisible. The
    # context-menu launcher is intended to be a no-window UX; the
    # launcher script returns to the caller as soon as wish.exe has
    # launched and the DWM title-bar apply window has completed.
    $cmdValue = 'powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File ' +
                '"' + $ScriptPath + '"' +
                ' run --working-dir "%1"'
    Set-ItemProperty -Path $cmdKey -Name '(default)' -Value $cmdValue

    Write-Host "Context-menu override installed." -ForegroundColor Green
    Write-Host ("  " + $cmdValue) -ForegroundColor DarkGray
}

function Copy-CffiBundle {
    <#
    .SYNOPSIS
        Copy the bundled CFFI package from the repo to the per-user install
        directory (Spec 0002 / T2).

    .DESCRIPTION
        Replaces any existing $darkDir\cffi tree. Throws with a clear
        message if the source bundle is missing - that means the launcher
        was deployed without the CFFI files (e.g. a stale release), and
        the install should fail loudly rather than silently break menu
        dark-mode.

    .PARAMETER Source
        Filesystem path to the bundled `assets/cffi/` directory.

    .PARAMETER Destination
        Filesystem path to the install dir's `cffi/` subdir
        (typically `$darkDir\cffi`).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "CFFI bundle source not found: $Source"
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
}

function Write-DarkModeConfig {
    <#
    .SYNOPSIS
        Write the install-time dark-mode flag the bootstrap reads on launch
        (Spec 0002 / T2).

    .DESCRIPTION
        Renders a tiny `darkmode-config.tcl` next to `bootstrap.tcl` that
        sets `::gitGuiDark::menuDarkModeEnabled` to 1 (supported build) or
        0 (unsupported). The bootstrap sources this file and silently
        skips the CFFI/uxtheme path when the flag is 0 or the file is
        missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [bool]$Enabled
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $cfg = Join-Path $Path 'darkmode-config.tcl'
    $flag = if ($Enabled) { '1' } else { '0' }
    $content = "# Auto-generated by git-gui-dark install - do not edit.`r`n" +
               "# 1 = running build is on the supported-builds allowlist.`r`n" +
               "# 0 = unsupported (or detection failed). The bootstrap reads`r`n" +
               "# this and silently skips the CFFI/uxtheme path when 0.`r`n" +
               "namespace eval ::gitGuiDark {}`r`n" +
               "set ::gitGuiDark::menuDarkModeEnabled $flag`r`n"
    # Tcl parses a BOM as junk on line 1; write UTF-8 without BOM.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($cfg, $content, $utf8NoBom)
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
        [Parameter()]

        # The dispatcher may pass an empty `@()` for `Passthrough` on a
        # bare `run` (no --working-dir etc.). PowerShell's binder treats
        # `@()` as "no value" for [string[]] without [AllowEmptyCollection]
        # and substitutes the parameter default - which is $null. Allow
        # both null and empty so the empty-array case reaches this body
        # and we can filter it explicitly.
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Passthrough = @()
    )

    # Filter out any null/empty entries that snuck through. The trailing
    # + below is fine on an empty @() but would produce `@($Bootstrap,
    # $null)` if Passthrough is $null (one null element) - and Start-Process
    # rejects -ArgumentList containing a null.
    $cleanPassthrough = @($Passthrough) | Where-Object { $_ }
    $argList = @($Bootstrap) + $cleanPassthrough

    # Start-Process -PassThru (rather than the call operator `&`) so the
    # parent process keeps a Process handle to wish.exe. This is what lets
    # Apply-Win32DarkModeToPid poll for the main window and apply
    # DWMWA_USE_IMMERSIVE_DARK_MODE during the apply window before the
    # launcher exits.
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

    # No wait on the wish process: the launcher returns as soon as the DWM
    # apply window finishes (success or timeout). wish.exe keeps running
    # independently. This keeps the context-menu spawner invisible
    # (Spec 0002 follow-up: context-menu launch leaves PowerShell
    # terminal visible until git-gui closes) and lets the bare
    # `git-gui-dark` CLI return promptly without blocking on wish.exe.
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

    # T2 / Spec 0002: detect whether the running build is on the
    # supported-builds allowlist. The result gates the CFFI bundle copy
    # and the bootstrap's menu dark-mode flag. If the T1 helper isn't
    # loaded (e.g. an older release still in use), default to $false -
    # the bootstrap stays Tk-palette only, which is the safety net.
    $darkModeEnabled = $false
    if (Get-Command -Name Test-Win32BuildSupportsDarkMode -ErrorAction SilentlyContinue) {
        try {
            $osInfo = Get-Win32OsInfo
            $allowlist = Get-SupportedBuilds
            $darkModeEnabled = Test-Win32BuildSupportsDarkMode -OsInfo $osInfo -Allowlist $allowlist
        }
        catch {
            # Detection failure (ntdll unreachable, registry key absent).
            # Stay on the safe side: no CFFI, no flag, fall through to
            # Tk-palette.
            $darkModeEnabled = $false
        }
    }
    Write-Verbose ("Menu dark mode enabled for this build: " + $darkModeEnabled)

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

    # 3. CFFI bundle + menu dark-mode flag (Spec 0002 / T2). On
    # supported builds we ship the bundled CFFI extension and tell the
    # bootstrap to call the uxtheme ordinals. On unsupported builds we
    # make sure no stale bundle is left behind from a prior install.
    $cffiDst = Join-Path $darkDir 'cffi'
    if ($darkModeEnabled) {
        $cffiSrc = Get-CffiBundleSource
        if (-not $cffiSrc) {
            Write-Host "CFFI bundle not found next to the script." -ForegroundColor Red
            Write-Host ("Looked for: cffi\  ;  ..\assets\cffi\  (under " + $PSScriptRoot + ")") -ForegroundColor Yellow
            exit 1
        }
        Copy-CffiBundle -Source $cffiSrc -Destination $cffiDst
        Write-Host "CFFI menu-dark bundle installed." -ForegroundColor Green
        Write-Host ("  " + $cffiDst) -ForegroundColor DarkGray
    }
    elseif (Test-Path -LiteralPath $cffiDst) {
        # Build used to be on the allowlist but isn't any more. The
        # bootstrap would silently no-op anyway, but leaving dead files
        # in the install dir is just noise.
        Remove-Item -LiteralPath $cffiDst -Recurse -Force
        Write-Host "Removed stale CFFI bundle (build no longer on the allowlist)." -ForegroundColor Yellow
    }
    Write-DarkModeConfig -Path $darkDir -Enabled $darkModeEnabled
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

        # Empty `@()` (bare `run` with no --working-dir) must reach this
        # body so Launch-GitGui can see it - PowerShell 5.1 collapses
        # `@()` to $null for [string[]] without [AllowEmptyCollection].
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Passthrough = @()
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
