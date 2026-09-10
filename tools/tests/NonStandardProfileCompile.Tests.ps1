#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$script:failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

# $PSScriptRoot はこのファイルの置かれたディレクトリ（tools/tests）なので、
# 2 段上がると repo root になる。既存の tools/tests/*.Tests.ps1 と同じ導出。
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# --------------------------------------------------------------------------
# **生成された非 standard profile の C# が、実際にコンパイルできることを見る。**
#
# 2026-09-07（M7b）に BindingGenerator.Tests.ps1 から切り出した。あちらが
# fast lane（$ToolsTestScriptsFast）に居るのに対し、ここは slow lane
# （$ToolsTestScriptsSlow、CI 専用）に置く —— この 1 本だけで `dotnet run`
# （合成木への書き込み）と `dotnet build` を 1 回ずつ抱え、
# BindingGenerator.Tests.ps1 側の実測 38 秒（fast lane 全体 80 秒のうち）の
# 大半を占めていた。`dev.ps1 test` を 65 秒 → 144 秒へ押し上げた回帰の
# 主因のひとつである。
#
# **検査そのものは削らない** —— 最終レビュー C-1（下記）を実際に捕まえた
# 実績がある。安い方（出力先の path だけを見る `--list-outputs`
# orchestration 検査）は BindingGenerator.Tests.ps1 に残してある。
#
# ローカルでは走らないが、`ci-native.yml` の 3 job（Windows/macOS/Linux）
# すべてが `dev.ps1 test-tools-slow` を呼び、3 つとも main の必須チェックで
# あるため「どこからも走らない」状態にはならない
# （`tools/tests/OpenCvConfig.Tests.ps1` の配線検査が、この事実自体を見る）。
#
# profile ごとに別 assembly へ分ける・LibraryName を複製する設計意図は
# CsPInvokeEmitter.cs に書いてある。ここで見るのは「実際にコンパイル
# できるか」だけである。
$profileCompileTmp = Join-Path ([System.IO.Path]::GetTempPath()) `
    ('ocvu-profile-compile-' + [System.Guid]::NewGuid().ToString('N'))
$specDirTmp = Join-Path $profileCompileTmp 'bindings/spec'
New-Item -ItemType Directory -Path $specDirTmp -Force | Out-Null
try {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'bindings/spec/schema.json') `
        -Destination (Join-Path $specDirTmp 'schema.json')

    # 合成した非 standard profile の spec 1 つだけで足りる。standard 側の
    # 経路（path の振り分け）は BindingGenerator.Tests.ps1 の orchestration
    # 検査が --list-outputs だけで安く見ているので、ここでは複製しない。
    Set-Content -LiteralPath (Join-Path $specDirTmp 'dnnprobe.json') -NoNewline -Value @'
{
  "module": "dnnprobe",
  "profile": "dnn",
  "functions": [
    {
      "name": "ocvu_dnnprobe_thing",
      "summary": "非 standard profile の生成物が単独でコンパイルできることを確かめるためだけの合成 spec。",
      "returns": "ocvu_status",
      "csReturns": "int",
      "wrapInTryBarrier": true,
      "params": []
    }
  ]
}
'@

    # ------------------------------------------------------------------
    # **生成物そのものをコンパイルする。**
    #
    # 出力先の path しか見ない orchestration 検査（BindingGenerator.Tests.ps1
    # 側）や、出力の文字列しか見ない Ocvu.Generator.Tests の ProfileTests.cs
    # では捕まえられない。M5 の Unity 側の正の対照がコンパイルしたのは
    # **手書きの probe ファイル**だった —— **生成された profile のファイルを
    # 誰もコンパイルしていなかった。**
    #
    # その穴を通って実際に欠陥が 1 件入った（最終レビュー C-1）:
    # `[DllImport(LibraryName, ...)]` の `LibraryName` は手書きの
    # `Runtime/Interop/NativeMethods.cs` にある internal const で、
    # 既定 profile はそれと同じ型の partial だから見えていた。
    # **非 standard は別 assembly・別型なので見えず、CS0103 になる**
    # （このブロックを最初に書く前に、実際にその error で落ちることを
    # 実測してある）。
    #
    # **道具は増やさない。** NuGet の追加は入れず、SDK が持つ `dotnet build`
    # だけで済ませる —— 対象の生成物は外部参照を 1 つも持たないので、
    # 空の net8.0 プロジェクトへ 1 ファイル入れれば足りる。
    & dotnet run --project (Join-Path $repoRoot 'bindings/generator/Ocvu.Generator') `
        -- --repo-root $profileCompileTmp 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -eq 0) 'the generator writes the synthetic profile tree'

    $emitted = Join-Path $profileCompileTmp `
        'Packages/com.ayutaz.opencv-unity-native/Runtime/Interop.Dnn/NativeMethods.Dnnprobe.g.cs'
    Assert-That (Test-Path -LiteralPath $emitted) `
        'the non-standard profile binding was written to disk (無ければ以下は空振りする)'

    # **EnableDefaultCompileItems を切って 1 ファイルだけを入れる。**
    # 既定のままだと生成器が同じ木へ書いた他の .cs（到達性テスト。
    # NUnit を参照する）まで拾ってしまい、落ちる理由が変わる。
    $csproj = Join-Path $profileCompileTmp 'profile-compile.csproj'
    Set-Content -LiteralPath $csproj -Value @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>disable</Nullable>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="Packages/com.ayutaz.opencv-unity-native/Runtime/Interop.Dnn/NativeMethods.Dnnprobe.g.cs" />
  </ItemGroup>
</Project>
"@

    function Invoke-ProfileCompileBuild {
        (& dotnet build $csproj --nologo -v q 2>&1) -join "`n"
    }

    $buildLog = Invoke-ProfileCompileBuild
    $compiled = $LASTEXITCODE -eq 0
    if (-not $compiled) { Write-Host $buildLog }
    Assert-That $compiled `
        'the GENERATED non-standard profile binding compiles on its own (C-1: LibraryName が見えないと CS0103)'

    # ------------------------------------------------------------------
    # **壊して、落ちることを見る（prove-a-check-works）。** 上の PASS だけ
    # では「今のコードがたまたま通った」のか「この検査が C-1 を実際に
    # 捕まえるのか」を区別できない。切り出しでこの区別を失わないよう、
    # C-1 そのもの —— 非 standard profile の生成物から LibraryNameBlock
    # （CsPInvokeEmitter.LibraryNameBlock、`#if ... #endif` の 5 行）を
    # 欠かす —— を再現し、この検査が本当に CS0103 で落ちることを実測して
    # から元に戻す。
    if ($compiled) {
        $original = Get-Content -LiteralPath $emitted -Raw
        try {
            $broken = [regex]::Replace(
                $original,
                '(?s)#if \(UNITY_IOS.*?#endif\r?\n',
                '')
            Assert-That ($broken -ne $original) `
                'the negative control actually removed the LibraryName declaration (置換が空振りしていない)'
            Set-Content -LiteralPath $emitted -Value $broken -NoNewline

            $brokenLog = Invoke-ProfileCompileBuild
            Assert-That ($LASTEXITCODE -ne 0) `
                'removing the LibraryName declaration makes the check fail again (CS0103 の再現)'
            Assert-That ($brokenLog -match 'CS0103') `
                'the failure is specifically CS0103 (別の理由で落ちていないことの確認)'
        }
        finally {
            Set-Content -LiteralPath $emitted -Value $original -NoNewline
        }

        Invoke-ProfileCompileBuild | Out-Null
        Assert-That ($LASTEXITCODE -eq 0) 'restoring the generated file makes it compile again'
    }
}
finally {
    Remove-Item -LiteralPath $profileCompileTmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($script:failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
