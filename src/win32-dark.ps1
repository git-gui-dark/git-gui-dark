<#
.SYNOPSIS
    Win32 dark-mode helper for the git-gui-dark launcher (Spec 0002 / T1).

.DESCRIPTION
    Detects the running Windows build, matches it against a small allowlist
    (supported-builds.json), and on a match, applies
    DWMWA_USE_IMMERSIVE_DARK_MODE (= 20) to wish.exe's main window so the
    OS title bar renders dark.

    Silent no-op on unsupported builds, when the helper can't be loaded, or
    when the target window is not found in time.

    The launcher dot-sources this module; all functions below become
    available in the launcher's scope. No types or functions are exported
    via a module manifest - this is intentionally a flat script, not a
    binary module.

    Public surface (all unit-testable except Set-Win32WindowDarkMode and
    Apply-Win32DarkModeToPid, which need a live window):

        Get-Win32OsInfo
        Get-SupportedBuilds
        Test-Win32BuildSupportsDarkMode
        Set-Win32WindowDarkMode
        Get-WishMainWindowHandle
        Apply-Win32DarkModeToPid

.NOTES
    Part of Spec 0002 (issue #7). Ticket T1 (issue #8). Detection: build
    via RtlGetVersion P/Invoke, UBR + DisplayVersion via the registry.
    No opt-in flag; no telemetry; no modification of the Git install.
#>

$ErrorActionPreference = 'Stop'

# ---- Constants ----------------------------------------------------------

# DWMWA_USE_IMMERSIVE_DARK_MODE. Documented for Windows 11+; community
# testing confirms it works on Windows 10 17763+ (build 19045 in this
# project). See https://github.com/microsoft/Windows.UI.Composition-Win32-Samples
# and the uxtheme ordinal discussion in the project history.
$script:DarkModeAttribute = 20

# ---- One-time native binding registration -------------------------------
# Register both ntdll and dwmapi bindings in a single Add-Type call so we
# only pay the C# compile cost once per process. Guarded so re-dot-sourcing
# the helper is cheap.

if (-not ('GitGuiDark.Native' -as [type])) {
    $nativeSource = @"
using System;
using System.Runtime.InteropServices;

namespace GitGuiDark {
    [StructLayout(LayoutKind.Sequential)]
    public struct OSVERSIONINFOEX {
        public int  dwOSVersionInfoSize;
        public int  dwMajorVersion;
        public int  dwMinorVersion;
        public int  dwBuildNumber;
        public int  dwPlatformId;
        public int  dwServicePackMajor;
        public int  dwServicePackMinor;
        public short wSuiteMask;
        public byte  wProductType;
        public byte  wReserved;
    }

    public static class Native {
        [DllImport("ntdll.dll")]
        public static extern int RtlGetVersion(ref OSVERSIONINFOEX lpVersionInformation);

        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int pvAttribute, int cbAttribute);
    }
}
"@
    Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop
}

# ---- Public API ---------------------------------------------------------

function Get-Win32OsInfo {
<#
.SYNOPSIS
    Returns a hashtable describing the running Windows build.

.DESCRIPTION
    Build comes from RtlGetVersion (P/Invoke into ntdll); Revision (UBR) and
    DisplayVersion come from HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion.
    Family is "Win11" for build >= 22000, otherwise "Win10". Returns $null
    on any failure (non-Windows host, missing registry key, etc.).
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    try {
        $osvi = New-Object 'GitGuiDark.OSVERSIONINFOEX'
        $osvi.dwOSVersionInfoSize = [System.Runtime.InteropServices.Marshal]::SizeOf(
            [type]'GitGuiDark.OSVERSIONINFOEX'
        )
        $null = [GitGuiDark.Native]::RtlGetVersion([ref]$osvi)

        $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $reg = Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop
        $ubr = if ($reg.UBR) { [int]$reg.UBR } else { 0 }
        $dv  = if ($reg.DisplayVersion) { [string]$reg.DisplayVersion } else { '' }

        return @{
            Family         = if ($osvi.dwBuildNumber -ge 22000) { 'Win11' } else { 'Win10' }
            Build          = [int]$osvi.dwBuildNumber
            Revision       = $ubr
            DisplayVersion = $dv
        }
    }
    catch {
        return $null
    }
}

function Get-SupportedBuilds {
<#
.SYNOPSIS
    Loads the supported-builds allowlist (supported-builds.json) into an
    array of ordered hashtables.

.DESCRIPTION
    Two-path resolution: looks for supported-builds.json next to this script
    (release layout) and one directory up (source layout - the file lives
    at the repo root, while the script lives in src/). Returns an empty
    array if the file is missing or malformed - the caller treats that as
    "no supported build" and the matcher returns false (silent skip).

.PARAMETER Path
    Override the resolved path. Used by the test suite to point at fixtures
    and to exercise the missing/malformed paths.
#>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string]$Path
    )

    if (-not $Path) {
        $candidates = @(
            (Join-Path $PSScriptRoot 'supported-builds.json'),
            (Join-Path $PSScriptRoot '..\supported-builds.json')
        )
        foreach ($p in $candidates) {
            if (Test-Path -LiteralPath $p) {
                $Path = (Resolve-Path -LiteralPath $p).Path
                break
            }
        }
    }

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $raw  = [System.IO.File]::ReadAllText($Path, $utf8NoBom)
        $list = $raw | ConvertFrom-Json
        if ($null -eq $list) { return @() }
        # PSCustomObject (not OrderedDictionary) - PSCustomObject is not
        # enumerable, so the pipeline does not expand it into its scalar
        # property values the way an OrderedDictionary would.
        return @($list | ForEach-Object {
            [PSCustomObject]@{
                family         = [string]$_.family
                build          = [int]$_.build
                revision       = [int]$_.revision
                displayVersion = [string]$_.displayVersion
            }
        })
    }
    catch {
        return @()
    }
}

function Test-Win32BuildSupportsDarkMode {
<#
.SYNOPSIS
    Pure decision function: does the running build match any allowlist entry?

.DESCRIPTION
    The public entry point used by the launcher. Takes a parsed OS-info
    hashtable (Get-Win32OsInfo) and an allowlist array (Get-SupportedBuilds),
    and returns $true if any entry's family + build + revision all match.
    DisplayVersion is informational only - a mismatched display label does
    NOT cause a skip, because the same UBR can ship under different
    marketing names (e.g. "22H2" vs an Insider preview label).
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [hashtable]$OsInfo,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Allowlist
    )

    if ($null -eq $OsInfo) { return $false }
    if ($null -eq $Allowlist -or $Allowlist.Count -eq 0) { return $false }

    foreach ($entry in $Allowlist) {
        if ([string]$entry.family   -ne [string]$OsInfo.Family)   { continue }
        if ([int]$entry.build       -ne [int]$OsInfo.Build)       { continue }
        if ([int]$entry.revision    -ne [int]$OsInfo.Revision)    { continue }
        return $true
    }
    return $false
}

function Set-Win32WindowDarkMode {
<#
.SYNOPSIS
    Applies DWMWA_USE_IMMERSIVE_DARK_MODE to a top-level window handle.

.DESCRIPTION
    Returns $true on success (HRESULT == 0), $false otherwise. The caller
    is expected to be a non-Windows-host unit test or a live process that
    already has a target window - this function does no waiting.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$WindowHandle
    )

    if ($WindowHandle -eq [IntPtr]::Zero) { return $false }

    $useDark = 1
    $hr = [GitGuiDark.Native]::DwmSetWindowAttribute(
        $WindowHandle,
        [int]$script:DarkModeAttribute,
        [ref]$useDark,
        [System.Runtime.InteropServices.Marshal]::SizeOf([int])
    )
    return ($hr -eq 0)
}

function Get-WishMainWindowHandle {
<#
.SYNOPSIS
    Polls a target process for a non-zero MainWindowHandle.

.DESCRIPTION
    Used by Apply-Win32DarkModeToPid to wait for wish.exe to create its
    top-level window. Returns [IntPtr]::Zero on timeout or if the process
    has already exited.
#>
    [CmdletBinding()]
    [OutputType([IntPtr])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try { $Process.Refresh() } catch { return [IntPtr]::Zero }
        if ($Process.HasExited) { return [IntPtr]::Zero }
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            return $Process.MainWindowHandle
        }
        Start-Sleep -Milliseconds 250
    }
    return [IntPtr]::Zero
}

function Apply-Win32DarkModeToPid {
<#
.SYNOPSIS
    End-to-end: detect, match, wait, apply. The single entry the launcher
    calls from Launch-GitGui.

.DESCRIPTION
    Silent no-op if the OS info can't be read, the build isn't on the
    allowlist, or the target window never appears in time. Never throws -
    the helper is a UX nicety, not a correctness requirement, and must
    never break a launch.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [int]$TimeoutSeconds = 15
    )

    try {
        $osInfo = Get-Win32OsInfo
        if ($null -eq $osInfo) { return }

        $allowlist = Get-SupportedBuilds
        if (-not (Test-Win32BuildSupportsDarkMode -OsInfo $osInfo -Allowlist $allowlist)) {
            return
        }

        $hwnd = Get-WishMainWindowHandle -Process $Process -TimeoutSeconds $TimeoutSeconds
        if ($hwnd -eq [IntPtr]::Zero) { return }

        $null = Set-Win32WindowDarkMode -WindowHandle $hwnd
    }
    catch {
        # Intentionally swallow. A dark-mode failure must never break the
        # launch - the existing Tk-palette dark theme is the safety net.
    }
}
