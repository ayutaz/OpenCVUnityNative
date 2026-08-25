#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'test-native', 'test-asan', 'test-managed', 'test', 'clean')]
    [string]$Command = 'test'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot      = Split-Path -Parent $PSScriptRoot
$Preset        = 'windows-x64-debug'
$AsanPreset    = 'windows-x64-asan'
$NativeOutDir  = Join-Path $RepoRoot "build/$Preset/native/Debug"
$ResultsDir    = Join-Path $RepoRoot 'artifacts/test-results'

function Invoke-Checked([scriptblock]$Action, [string]$What) {
    Write-Host "==> $What" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" }
}

function Build-Native {
    Invoke-Checked { cmake --preset $Preset } 'configure native'
    Invoke-Checked { cmake --build --preset $Preset } 'build native'
}

function Test-Native {
    Build-Native
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
    Invoke-Checked {
        ctest --preset $Preset --output-junit (Join-Path $ResultsDir 'native.xml')
    } 'run native tests (L1)'
}

switch ($Command) {
    'build'       { Build-Native }
    'test-native' { Test-Native }
    'test'        { Test-Native }
    'clean'       { Remove-Item -Recurse -Force (Join-Path $RepoRoot 'build') -ErrorAction SilentlyContinue }
    default       { throw "Command '$Command' is not implemented yet." }
}

Write-Host "OK: $Command" -ForegroundColor Green
