#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$verify = Join-Path $repoRoot 'tools/verify-opencv-artifact.ps1'

$failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

# 合成のツリーを作って検証する。実際の OpenCV ビルドは要らない。
$temp = Join-Path ([System.IO.Path]::GetTempPath()) "ocvu-verify-$(Get-Random)"
function New-Tree([string[]]$libs) {
    $root = Join-Path $temp "case-$(Get-Random)"
    $libDir = Join-Path $root 'x64/vc17/staticlib'
    New-Item -ItemType Directory -Force -Path $libDir | Out-Null
    foreach ($lib in $libs) { Set-Content -Path (Join-Path $libDir $lib) -Value 'stub' }
    return $root
}

$allowed = @(
    'opencv_core500.lib', 'opencv_imgproc500.lib', 'opencv_imgcodecs500.lib',
    'opencv_objdetect500.lib', 'opencv_features500.lib', 'opencv_flann500.lib',
    'zlib.lib', 'libpng.lib', 'libjpeg-turbo.lib'
)

# 正常系
$ok = New-Tree $allowed
& pwsh -NoProfile -File $verify -Root $ok | Out-Null
Assert-That ($LASTEXITCODE -eq 0) 'a clean tree passes'

# videoio が混ざっている
$bad = New-Tree ($allowed + 'opencv_videoio500.lib')
& pwsh -NoProfile -File $verify -Root $bad 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'videoio is rejected'

# FFmpeg のプラグイン DLL が混ざっている
$ffmpegRoot = New-Tree $allowed
Set-Content -Path (Join-Path $ffmpegRoot 'x64/vc17/staticlib/opencv_videoio_ffmpeg500_64.dll') -Value 'stub'
& pwsh -NoProfile -File $verify -Root $ffmpegRoot 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a bundled FFmpeg plug-in is rejected'

# 期待した module が足りない
$missing = New-Tree @('opencv_core500.lib')
& pwsh -NoProfile -File $verify -Root $missing 2>&1 | Out-Null
Assert-That ($LASTEXITCODE -ne 0) 'a tree missing a required module is rejected'

# 検出結果の出力
$listing = & pwsh -NoProfile -File $verify -Root $ok
Assert-That ($listing -contains 'core') 'reports the modules it found'
Assert-That ($listing -contains 'imgproc') 'reports imgproc'

Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) assertion(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
