# Pester 3.x tests for the launcher-side install helpers added by
# Spec 0002 / T2: Copy-CffiBundle and Write-DarkModeConfig.
# Run: Invoke-Pester src\git-gui-dark.Tests.ps1
#
# These tests load the launcher file. Because the launcher's bottom-of-file
# dispatcher would try to run `run` on dot-source, we instead parse out
# the helper-function definitions with the AST and eval just those.
#
# (An alternative - refactoring the dispatcher into an `if ($MyInvocation
# .InvocationName -ne '.')` guard - was rejected as a behavior change to
# the launcher unrelated to T2's scope.)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcher = Join-Path $here 'git-gui-dark.ps1'

# Load just the helper functions defined in the launcher. We extract every
# `function Foo { ... }` block via the PowerShell parser and eval them in
# isolation - so the dispatcher's `Invoke-Run` (which would otherwise fire
# when the launcher is dot-sourced) never runs.
$tokens = $null
$errors  = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $launcher, [ref]$tokens, [ref]$errors
)
if ($errors -and $errors.Count -gt 0) {
    throw "Parse error in $launcher : $($errors[0].Message)"
}

$funcAsts = $ast.FindAll(
    { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $true
)

# Load each function definition in isolation. Order is not significant:
# the helpers under test (Copy-CffiBundle, Write-DarkModeConfig) are
# self-contained and don't call each other or anything else in the
# launcher.
foreach ($f in $funcAsts) {
    Invoke-Expression $f.Extent.Text
}

Describe 'Copy-CffiBundle' {
    It 'copies a source tree to a destination, replacing any existing dest' {
        $src = Join-Path $TestDrive 'src'
        $dst = Join-Path $TestDrive 'dst'
        New-Item -ItemType Directory -Path (Join-Path $src 'win32-x86_64') -Force | Out-Null
        'dll-content' | Set-Content -LiteralPath (Join-Path $src 'win32-x86_64\cffi20b1t.dll') -Encoding UTF8 -NoNewline
        'idx'         | Set-Content -LiteralPath (Join-Path $src 'pkgIndex.tcl')           -Encoding UTF8 -NoNewline
        'bsd'         | Set-Content -LiteralPath (Join-Path $src 'LICENSE')                 -Encoding UTF8 -NoNewline

        Copy-CffiBundle -Source $src -Destination $dst

        Test-Path (Join-Path $dst 'pkgIndex.tcl')                  | Should Be $true
        Test-Path (Join-Path $dst 'LICENSE')                       | Should Be $true
        Test-Path (Join-Path $dst 'win32-x86_64\cffi20b1t.dll')    | Should Be $true
        'dll-content' | Should Be (Get-Content -LiteralPath (Join-Path $dst 'win32-x86_64\cffi20b1t.dll') -Raw -Encoding UTF8)
    }

    It 'replaces an existing destination tree atomically' {
        $src = Join-Path $TestDrive 'src2'
        $dst = Join-Path $TestDrive 'dst2'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        'new' | Set-Content -LiteralPath (Join-Path $src 'a.txt') -Encoding UTF8 -NoNewline

        # Pre-populate dst with stale content
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        'stale' | Set-Content -LiteralPath (Join-Path $dst 'old.txt') -Encoding UTF8 -NoNewline

        Copy-CffiBundle -Source $src -Destination $dst

        Test-Path (Join-Path $dst 'a.txt')   | Should Be $true
        Test-Path (Join-Path $dst 'old.txt') | Should Be $false
    }

    It 'throws with a clear message when the source does not exist' {
        $missing = Join-Path $TestDrive 'no-such-dir'
        $dst     = Join-Path $TestDrive 'dst3'
        { Copy-CffiBundle -Source $missing -Destination $dst } |
            Should Throw "CFFI bundle source not found"
    }
}

Describe 'Write-DarkModeConfig' {
    It 'writes a Tcl flag file with menuDarkModeEnabled = 1 when enabled' {
        $dir = Join-Path $TestDrive 'cfg'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-DarkModeConfig -Path $dir -Enabled $true

        $cfg = Join-Path $dir 'darkmode-config.tcl'
        Test-Path $cfg | Should Be $true
        $content = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8
        $content | Should Match 'menuDarkModeEnabled 1'
    }

    It 'writes a Tcl flag file with menuDarkModeEnabled = 0 when disabled' {
        $dir = Join-Path $TestDrive 'cfg2'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-DarkModeConfig -Path $dir -Enabled $false

        $cfg = Join-Path $dir 'darkmode-config.tcl'
        Test-Path $cfg | Should Be $true
        $content = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8
        $content | Should Match 'menuDarkModeEnabled 0'
    }
}

Describe 'Get-CffiBundleSource' {
    It 'returns $null when neither layout candidate exists' {
        $isolated = Join-Path $TestDrive 'no-script-dir'
        New-Item -ItemType Directory -Path $isolated -Force | Out-Null
        Get-CffiBundleSource -ScriptRoot $isolated | Should BeNullOrEmpty
    }

    It 'resolves to the release-layout candidate when cffi sits at the script root' {
        $root = Join-Path $TestDrive 'rel-root'
        $cffi = Join-Path $root 'cffi'
        New-Item -ItemType Directory -Path $cffi -Force | Out-Null
        Get-CffiBundleSource -ScriptRoot $root | Should Be (Resolve-Path -LiteralPath $cffi).Path
    }

    It 'resolves to the source-layout candidate when only assets\cffi exists' {
        # Source layout: launcher at <root>\src, CFFI at <root>\assets\cffi.
        # $ScriptRoot is treated as $PSScriptRoot (the launcher's own directory),
        # so from <root>\src, "..\assets\cffi" lands one level up at <root>\assets\cffi.
        $repoRoot   = Join-Path $TestDrive 'fake-repo-src'
        $launcherDir = Join-Path $repoRoot 'src'
        $cffi       = Join-Path $repoRoot 'assets\cffi'
        New-Item -ItemType Directory -Path $cffi -Force | Out-Null
        Get-CffiBundleSource -ScriptRoot $launcherDir | Should Be (Resolve-Path -LiteralPath $cffi).Path
    }

    It 'prefers the release layout over the source layout when both exist' {
        # From <root>\src, "cffi" is release-layout, "..\assets\cffi" is source-layout.
        $repoRoot   = Join-Path $TestDrive 'fake-repo-both'
        $launcherDir = Join-Path $repoRoot 'src'
        $rel        = Join-Path $launcherDir 'cffi'
        $src        = Join-Path $repoRoot 'assets\cffi'
        New-Item -ItemType Directory -Path $rel -Force | Out-Null
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Get-CffiBundleSource -ScriptRoot $launcherDir | Should Be (Resolve-Path -LiteralPath $rel).Path
    }
}
