#Requires -Version 7.0
# Pester を使わず素の assert で書く。依存を増やさないため。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'tools/OpenCvConfig.psm1') -Force

$failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

$config = Get-OpenCvConfig

Assert-That ($config.Tag -eq '5.0.0') 'tag is pinned to 5.0.0'
Assert-That ($config.Modules -join ',' -eq 'core,imgproc,imgcodecs,objdetect,features') 'module allowlist matches the spec'

# 4.x の名前が混ざっていないこと。OpenCV 5 では再編されている。
Assert-That (-not ($config.Modules -contains 'features2d')) 'features2d is not used (renamed to features in 5.x)'
Assert-That (-not ($config.Modules -contains 'calib3d')) 'calib3d is not used (split in 5.x)'
Assert-That (-not ($config.Modules -contains 'videoio')) 'videoio is excluded'

$args = $config.CMakeArgs -join ' '
foreach ($forbidden in @('WITH_FFMPEG=OFF', 'WITH_GSTREAMER=OFF', 'WITH_MSMF=OFF', 'WITH_DSHOW=OFF')) {
    Assert-That ($args -match [regex]::Escape($forbidden)) "flags disable $($forbidden.Split('=')[0])"
}
Assert-That ($args -match 'CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL') 'CRT is /MD'
Assert-That ($args -match 'BUILD_SHARED_LIBS=OFF') 'OpenCV is built static'

# ハッシュは決定的で、構成が変われば変わること
$hash1 = Get-OpenCvConfigHash -Config $config
$hash2 = Get-OpenCvConfigHash -Config (Get-OpenCvConfig)
Assert-That ($hash1 -eq $hash2) 'hash is deterministic across calls'
Assert-That ($hash1 -match '^[0-9a-f]{12}$') 'hash is 12 lowercase hex characters'

$mutated = Get-OpenCvConfig
$mutated.CMakeArgs = @($mutated.CMakeArgs) + '-DWITH_TIFF=ON'
Assert-That ((Get-OpenCvConfigHash -Config $mutated) -ne $hash1) 'changing a flag changes the hash'

$mutatedTag = Get-OpenCvConfig
$mutatedTag.Tag = '5.0.1'
Assert-That ((Get-OpenCvConfigHash -Config $mutatedTag) -ne $hash1) 'changing the tag changes the hash'

Assert-That ((Get-OpenCvArtifactName -Config $config) -eq "opencv-5.0.0-windows-x64-$hash1") 'artifact name embeds the hash'

# 並び順を変えても同じハッシュになること（order-insensitive）。
# Sort-Object を将来のリファクタで取りこぼしても検知できるよう、
# 一度きりの ad hoc 確認ではなくテストスイートに残す。
$shuffled = Get-OpenCvConfig
$shuffled.CMakeArgs = @($shuffled.CMakeArgs[-1]) + @($shuffled.CMakeArgs[0..($shuffled.CMakeArgs.Count - 2)])
$shuffled.Modules = @($shuffled.Modules[-1]) + @($shuffled.Modules[0..($shuffled.Modules.Count - 2)])
Assert-That ((Get-OpenCvConfigHash -Config $shuffled) -eq $hash1) 'reordering CMakeArgs and Modules does not change the hash'

# 正規化が単射であること。区切り文字で join するだけの正規化は、
# 要素境界に区切り文字自体を含む値が来ると衝突し得る
# （["-DAAA=1","-DBBB=2"] と ["-DAAA=1 -DBBB=2"] が同じ文字列になる）。
# 今の固定構成には空白・カンマを含む flag/module は無いが、
# Task 3 / 7 で CMakeArgs が増える前提なので、ここで塞いでおく。
$collisionA = Get-OpenCvConfig
$collisionA.CMakeArgs = @('-DAAA=1', '-DBBB=2')
$collisionB = Get-OpenCvConfig
$collisionB.CMakeArgs = @('-DAAA=1 -DBBB=2')
Assert-That ((Get-OpenCvConfigHash -Config $collisionA) -ne (Get-OpenCvConfigHash -Config $collisionB)) 'CMakeArgs elements do not collide across element boundaries'

$moduleCollisionA = Get-OpenCvConfig
$moduleCollisionA.Modules = @('core', 'imgproc')
$moduleCollisionB = Get-OpenCvConfig
$moduleCollisionB.Modules = @('core,imgproc')
Assert-That ((Get-OpenCvConfigHash -Config $moduleCollisionA) -ne (Get-OpenCvConfigHash -Config $moduleCollisionB)) 'Modules elements do not collide across element boundaries'

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) assertion(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
