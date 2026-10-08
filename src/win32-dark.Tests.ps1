# Pester 3.x tests for src/win32-dark.ps1.
# Run: Invoke-Pester src\win32-dark.Tests.ps1
#
# These tests cover the unit-testable public surface only. The P/Invoke
# helpers (Get-Win32OsInfo, Set-Win32WindowDarkMode) and the end-to-end
# apply path (Apply-Win32DarkModeToPid) are exercised manually on a real
# Windows host.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sut  = (Join-Path $here 'win32-dark.ps1')

# The SUT is dot-sourced here so its functions are visible to every It.
# If the SUT is missing the test will fail with a clear "file not found"
# rather than a misleading "command not found" later in a test.
. $sut

Describe 'win32-dark helper' {

    Context 'Get-SupportedBuilds' {
        It 'loads the bundled allowlist from a given path and returns ordered entries' {
            $repoRoot = (Resolve-Path (Join-Path $here '..')).Path
            $list = Get-SupportedBuilds -Path (Join-Path $repoRoot 'supported-builds.json')
            @($list).Count | Should Be 1
            $list[0].family | Should Be 'Win10'
            $list[0].build | Should Be 19045
            $list[0].revision | Should Be 6466
            $list[0].displayVersion | Should Be '22H2'
        }

        It 'returns an empty array when the file is missing (silent skip semantics)' {
            $missing = Join-Path $here '__definitely_not_there__.json'
            $list = Get-SupportedBuilds -Path $missing
            @($list).Count | Should Be 0
        }

        It 'returns an empty array when the file is malformed' {
            $bad = Join-Path $TestDrive 'bad.json'
            'not json at all' | Set-Content -LiteralPath $bad -Encoding UTF8
            $list = Get-SupportedBuilds -Path $bad
            @($list).Count | Should Be 0
        }
    }

    Context 'Test-Win32BuildSupportsDarkMode' {
        $win1022H2 = [ordered]@{
            family         = 'Win10'
            build          = 19045
            revision       = 6466
            displayVersion = '22H2'
        }

        It 'returns false when OsInfo is null' {
            Test-Win32BuildSupportsDarkMode -OsInfo $null -Allowlist @($win1022H2) | Should Be $false
        }

        It 'returns false when Allowlist is empty' {
            $info = @{ Family='Win10'; Build=19045; Revision=6466; DisplayVersion='22H2' }
            Test-Win32BuildSupportsDarkMode -OsInfo $info -Allowlist @() | Should Be $false
        }

        It 'returns false when Allowlist is null' {
            $info = @{ Family='Win10'; Build=19045; Revision=6466; DisplayVersion='22H2' }
            Test-Win32BuildSupportsDarkMode -OsInfo $info -Allowlist $null | Should Be $false
        }

        It 'returns true for an exact match (family + build + revision)' {
            $info = @{ Family='Win10'; Build=19045; Revision=6466; DisplayVersion='22H2' }
            Test-Win32BuildSupportsDarkMode -OsInfo $info -Allowlist @($win1022H2) | Should Be $true
        }

        It 'returns true for a match even if DisplayVersion differs (displayVersion is informational)' {
            $info = @{ Family='Win10'; Build=19045; Revision=6466; DisplayVersion='SomeOtherLabel' }
            Test-Win32BuildSupportsDarkMode -OsInfo $info -Allowlist @($win1022H2) | Should Be $true
        }

        It 'returns false for a family mismatch (Win11 OS vs Win10 entry)' {
            $info = @{ Family='Win11'; Build=19045; Revision=6466; DisplayVersion='22H2' }
            Test-Win32BuildSupportsDarkMode -OsInfo $info -Allowlist @($win1022H2) | Should Be $false
        }

        It 'returns false for a build mismatch' {
            $info = @{ Family='Win10'; Build=18363; Revision=6466; DisplayVersion='19H2' }
            Test-Win32BuildSupportsDarkMode -OsInfo $info -Allowlist @($win1022H2) | Should Be $false
        }

        It 'returns false for a revision mismatch' {
            $info = @{ Family='Win10'; Build=19045; Revision=9999; DisplayVersion='22H2' }
            Test-Win32BuildSupportsDarkMode -OsInfo $info -Allowlist @($win1022H2) | Should Be $false
        }

        It 'returns true when one of several allowlist entries matches' {
            $info = @{ Family='Win10'; Build=19045; Revision=6466; DisplayVersion='22H2' }
            $list = @(
                [ordered]@{ family='Win10'; build=18363; revision=1;    displayVersion='19H2' },
                [ordered]@{ family='Win10'; build=19045; revision=6466; displayVersion='22H2' },
                [ordered]@{ family='Win11'; build=22621; revision=1;    displayVersion='22H2' }
            )
            Test-Win32BuildSupportsDarkMode -OsInfo $info -Allowlist $list | Should Be $true
        }

        It 'returns false when no allowlist entry matches across multiple entries' {
            $info = @{ Family='Win10'; Build=19045; Revision=6466; DisplayVersion='22H2' }
            $list = @(
                [ordered]@{ family='Win10'; build=18363; revision=1; displayVersion='19H2' },
                [ordered]@{ family='Win11'; build=22621; revision=1; displayVersion='22H2' }
            )
            Test-Win32BuildSupportsDarkMode -OsInfo $info -Allowlist $list | Should Be $false
        }
    }

    Context 'Get-Win32OsInfo on a real Windows host' {
        It 'returns a hashtable with Family, Build, Revision, DisplayVersion' {
            $info = Get-Win32OsInfo
            # If ntdll or the registry key is unavailable, skip the rest of
            # the assertions. This is the only test that needs a real host;
            # the matcher tests above are host-agnostic.
            if ($null -eq $info) {
                throw 'Get-Win32OsInfo returned null; cannot run on this host.'
            }
            $info.ContainsKey('Family')         | Should Be $true
            $info.ContainsKey('Build')          | Should Be $true
            $info.ContainsKey('Revision')       | Should Be $true
            $info.ContainsKey('DisplayVersion') | Should Be $true
            $info.Family -match '^(Win10|Win11)$' | Should Be $true
            $info.Build  -ge 10240 | Should Be $true
            $info.Revision -ge 0   | Should Be $true
        }
    }
}
