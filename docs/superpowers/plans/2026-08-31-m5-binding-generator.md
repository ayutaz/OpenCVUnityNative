# M5 binding specification と generator Implementation Plan

> **実施済み（2026-09-01、PR #55）。** 8 タスクすべてを Subagent-Driven Development で
> 実行し、CI の必須 21 本すべてが緑になった。**完了条件 5 件のうち 4 件を満たし、
> 条件 2 は計画の側で意図的に次へ送った**（判定表は `docs/roadmap.md` の M5 節。
> **ここに再掲しない** —— 2 箇所が同時に古くなる）。
> 実施の記録は下の「実施の結果」節にある。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** C ABI 宣言・C# P/Invoke・API 対応表・到達性 conformance test を、レビュー可能な 1 つの仕様（`bindings/spec/*.json`）から生成し、**いま手書きされている 20 本をその仕様の側へ寄せる**。

**Architecture:** `bindings/spec/<module>.json` を正本とし、net8.0 の console generator（`bindings/generator/`）が **module ごとに** C ヘッダと C# P/Invoke を出す。生成物は git に入れ、**golden test が「spec から出したもの」と「木に在るもの」の一致を見る**（差分が出たら赤）。実装（`.cpp` の本体）は生成しない —— 生成するのは**境界の宣言**と、それを**全部呼ぶ到達性テスト**である。

**Tech Stack:** JSON（spec と schema）、C# / net8.0（generator と golden test。既存の `tests/Managed` レーンに同居）、PowerShell（`dev.ps1` の入口）、CMake（module ごとのヘッダ）。

**Spec:** `docs/roadmap.md` の「M5 — binding specification と generator」節（完了条件 5 件と非ゴール）、および同「M7 — Optional profiles と性能」節の「決定: native bridge を module 単位に分ける」。**roadmap が M5 着手時に後者を読むよう明示している。**

---

## この計画が扱わないもの（別の計画に分ける）

**roadmap の M5 完了条件 2「`geometry` / `calib` / `features` / `objdetect` などを利用例に基づいて追加する」は、この計画には入れない。**

理由: それは**別の subsystem** である。新しい OpenCV module をリンクすると、
`cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS`、`tools/opencv-config.psd1` の
`Modules`、`THIRD_PARTY_NOTICES.md`、成果物の大きさ、依存 allowlist が動く
（**M3.5 で `imgcodecs` を足したときに実際に全部動いた**）。生成の仕組みと同時に
やると、**「生成が壊れたのか、新しい module が壊れたのか」が切り分けられない。**

**この計画の完了時点で、新しい関数を足す作業は「spec に 1 エントリ書いて `dev.ps1 generate`」になる。**
そこまで来てから module を足すほうが安い。

したがって **M5 の完了条件 5 件のうち、この計画が閉じるのは 1・3・4・5 の 4 件**である。
条件 2 は次の計画で閉じる。**判定表にはそう書くこと** —— 部分的な達成を完了と呼ばない。

---

## Global Constraints

このリポジトリの不変条件は全タスクに掛かる。**タスクごとに再掲しないので、着手前にここを読むこと。**

- **C ABI が唯一の native contract。** `cv::Mat*` や STL 型を境界の外へ出さない。opaque handle と固定サイズ型のみ（`CLAUDE.md`「アーキテクチャの中核」）
- **例外を ABI の外へ伝播させない。** 公開 ABI 関数は `OCVU_TRY_BEGIN` / `OCVU_TRY_END` で囲む。**囲ってはならない関数の一覧が `native/src/ocvu_error.h` にある**（`ocvu_get_last_error_*` は囲うと報告すべきエラーを自分で消す）
- **`ocvu_mat_handle` は常に native が所有する。** Unity のメモリを指す handle を返さない
- **`Runtime/Interop` と `Runtime/Core` は `UnityEngine` を参照してはならない**（`tests/Managed/CvUnity.Runtime.Shim` がビルドで強制する）
- **非 ASCII を出力する PowerShell スクリプトは先頭に `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()` を置く**
- **検査を足す・変えるときは `prove-a-check-works` skill の手順を踏む。** 壊して落ちることを見るまで、その検査は動くと言えない。**壊す前にコミットする**（`git checkout --` で作業ごと戻す事故を M4 で 3 回踏んだ）
- **ABI 関数を足す・変えるときは `add-abi-function` skill の手順を踏む**
- **CI はローカルと同一のコマンド（`tools/dev.ps1`）を呼ぶ。** CI 専用の手順を作らない。全 job に `timeout-minutes`
- **`git add -A` / `git add .` は hook が拒否する。** ファイルを名指しして add する
- **PR を出す前に AI レビューを行う。** **書いていない別のエージェント**にブランチ全体を見せる
- **必須チェックを増減したら `CLAUDE.md` の表と `README.md` の該当段落を直す**（二重に書いてあるのはその 1 箇所だけ）
- **`OCVU_ABI_VERSION` は 1。** 生成の導入だけでは bump しない —— **既存 20 本のシグネチャを 1 バイトも変えない**のがこの計画の前提である（`docs/abi-ownership-and-versioning.md` §2）

---

## 先に決めたこと（着手前に読む）

計画を書く時点で 3 つ決めた。**変えるなら、変えた理由をここに書き足すこと。**

### 決定 1: spec は JSON。YAML にしない

**このリポジトリは PowerShell 側に YAML パーサを持たず、意図的に避けている** ——
`tools/tests/OpenCvConfig.Tests.ps1` は workflow を「YAML パーサを使わず
インデント規約で」切り出しており、その理由がコメントに書いてある。
JSON なら PowerShell（`ConvertFrom-Json`）・C#（`System.Text.Json`）・`jq` の
すべてが**依存を足さずに**読める。

差分の読みやすさは **1 行 1 フィールド**の書き方で担保する。

### 決定 2: generator は C# / net8.0

**生成物の一致は golden test で見る。それが速いレーンで走ることが要件である。**
`tests/Managed/` に net8.0 の xUnit レーンが既にあり、`dev.ps1 test-managed` が
**約 11 秒**で回る。generator を同じ solution に置けば golden test は秒で回る。

PowerShell でも書けるが、C/C# のコードを文字列で組み立てるのは読みにくい。
Python は CI に新しい実行環境を持ち込む。

### 決定 3: 最初から **module ごと**に出す

roadmap の M7 決定 1 が既にこう決めている:

> **C ABI を module ごとに分ける。** `core` / `imgproc` / `imgcodecs` は安定 ABI として
> 先行し、`dnn` は別ヘッダ・別 `.cpp`・別 CMake target に置く。共通の型・status・version
> だけを `opencv_unity_native.h` に残す。**いま 20 本が 1 ヘッダにあるのを、足す前に割る。**

**単一ヘッダを生成すると、M7 で generator を書き直すことになる。**

---

## ファイル構成

| 場所 | 責務 |
| --- | --- |
| `bindings/spec/schema.json` | spec の JSON Schema。**形の正本** |
| `bindings/spec/infra.json` | version / last-error / status 表 / OpenCV info / debug |
| `bindings/spec/core.json` | `Mat` のライフサイクルと buffer 転送 |
| `bindings/spec/imgproc.json` | `cvtColor` / `resize` / `GaussianBlur` |
| `bindings/spec/imgcodecs.json` | `imencode` / `imdecode` |
| `bindings/generator/Ocvu.Generator/` | net8.0 console。spec を読んで生成物を書く |
| `bindings/generator/Ocvu.Generator.Tests/` | golden test（xUnit） |
| `native/include/ocvu/<module>.h` | **生成物**。module ごとの C ABI 宣言 |
| `native/include/opencv_unity_native.h` | **手書きのまま。** 共通の型・status・version と `ocvu/*.h` の include |
| `Packages/.../Runtime/Interop/NativeMethods.<Module>.g.cs` | **生成物**。`partial class` の module ごとの P/Invoke |
| `tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs` | **生成物**。全 entry point を 1 回ずつ呼ぶ |
| `docs/api-map.md` | **生成物**。API 対応表 |
| `tools/dev.ps1` | `generate` と `verify-generated` の入口 |

**生成物は git に入れる。** 理由は 2 つ:
(a) Unity は生成 step を持たないので `.g.cs` が木に無いとコンパイルが通らない、
(b) **差分がレビューに出る**ほうがこのリポジトリの規律に合う。
代わりに **`verify-generated` が「生成し直して差分が出たら落とす」**。

---

## Task 1: spec の形と、それを検証する schema

**Files:**
- Create: `bindings/spec/schema.json`
- Create: `bindings/spec/infra.json`
- Create: `bindings/generator/Ocvu.Generator/Ocvu.Generator.csproj`
- Create: `bindings/generator/Ocvu.Generator/SpecModel.cs`
- Create: `bindings/generator/Ocvu.Generator.Tests/Ocvu.Generator.Tests.csproj`
- Create: `bindings/generator/Ocvu.Generator.Tests/SpecSchemaTests.cs`
- Modify: `tests/Managed/CvUnity.Managed.sln`

**Interfaces:**
- Produces: `Ocvu.Generator.SpecModel.Load(string specDir)` → `IReadOnlyList<ModuleSpec>`。
  `ModuleSpec(string Module, IReadOnlyList<FunctionSpec> Functions)`、
  `FunctionSpec(string Name, string Summary, string Returns, string CsReturns, bool WrapInTryBarrier, IReadOnlyList<ParamSpec> Params, string? BarrierNote, string? EntryPoint)`、
  `ParamSpec(string Name, string CType, string CsType, string Direction)`。
  形式違反は `SpecFormatException` を投げる

- [ ] **Step 1: `bindings/spec/infra.json` を書く**

**`infra` から始めるのは、この群が「囲ってはならない関数」を含むから**である。
`native/src/ocvu_error.h` にその一覧があり、`ocvu_get_last_error_*` は
`OCVU_TRY_BEGIN` で囲むと報告すべきエラーを自分で消す。
**その情報を spec が持てないと、生成は最初から正しくない。**

```json
{
  "module": "infra",
  "functions": [
    {
      "name": "ocvu_get_abi_version",
      "summary": "現在の C ABI バージョンを返す。失敗しない。",
      "returns": "int32_t",
      "csReturns": "int",
      "wrapInTryBarrier": false,
      "barrierNote": "ocvu_status を返さないので囲めない",
      "params": []
    },
    {
      "name": "ocvu_get_last_error_status",
      "summary": "直近のエラー status を返す。呼び出しスレッドごとに独立している。",
      "returns": "ocvu_status",
      "csReturns": "int",
      "wrapInTryBarrier": false,
      "barrierNote": "OCVU_TRY_BEGIN は clear_last_error() を呼ぶので、報告すべきエラーを自分で消してしまう",
      "params": []
    },
    {
      "name": "ocvu_get_status_count",
      "summary": "status 表の件数を返す。",
      "returns": "int32_t",
      "csReturns": "int",
      "wrapInTryBarrier": false,
      "barrierNote": "ocvu_status を返さないので囲めない",
      "params": []
    }
  ]
}
```

**この 3 本だけで始める。** 残りは Task 5 で移す。

- [ ] **Step 2: `bindings/spec/schema.json` を書く**

**`additionalProperties: false` を必ず入れる。** 入れないと綴り間違えた
フィールドが黙って無視される —— このリポジトリは CodeQL の `query-filters` で
実際にその形を踏んだ（`exclude` を `excludes` と書いても schema を通った）。

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "additionalProperties": false,
  "required": ["module", "functions"],
  "properties": {
    "module": { "type": "string", "pattern": "^[a-z][a-z0-9_]*$" },
    "functions": {
      "type": "array",
      "minItems": 1,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["name", "summary", "returns", "csReturns", "wrapInTryBarrier", "params"],
        "properties": {
          "name": { "type": "string", "pattern": "^ocvu_[a-z0-9_]+$" },
          "summary": { "type": "string", "minLength": 1 },
          "returns": { "type": "string", "enum": ["ocvu_status", "int32_t", "void"] },
          "csReturns": { "type": "string", "enum": ["int", "void"] },
          "wrapInTryBarrier": { "type": "boolean" },
          "barrierNote": { "type": "string" },
          "entryPoint": { "type": "string", "pattern": "^ocvu_[a-z0-9_]+$" },
          "params": {
            "type": "array",
            "items": {
              "type": "object",
              "additionalProperties": false,
              "required": ["name", "cType", "csType", "direction"],
              "properties": {
                "name": { "type": "string", "pattern": "^[a-z][a-zA-Z0-9_]*$" },
                "cType": { "type": "string", "minLength": 1 },
                "csType": { "type": "string", "minLength": 1 },
                "direction": { "type": "string", "enum": ["in", "out", "in-buffer", "out-buffer"] }
              }
            }
          }
        }
      }
    }
  }
}
```

`entryPoint` は任意である。**`mat_copy_from_buffer` は `byte[]` 版と `IntPtr` 版で
2 つの C# 宣言を持つが、C の entry point は 1 つ**なので、spec 上は別エントリにして
`entryPoint` で同じ名前を指す（Task 5 で使う）。

- [ ] **Step 3: 失敗するテストを書く（`SpecSchemaTests.cs`）**

```csharp
using System;
using System.IO;
using System.Linq;
using Xunit;

namespace Ocvu.Generator.Tests;

public class SpecSchemaTests
{
    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "bindings", "spec")))
        {
            dir = dir.Parent;
        }
        Assert.NotNull(dir);
        return dir!.FullName;
    }

    [Fact]
    public void EverySpecFileLoads()
    {
        var specs = SpecModel.Load(Path.Combine(RepoRoot(), "bindings", "spec"));
        Assert.NotEmpty(specs);
        Assert.All(specs, s => Assert.NotEmpty(s.Functions));
    }

    // **囲ってはならない関数を spec が知っていること。**
    // native/src/ocvu_error.h が「囲まない関数」を列挙している。spec がそれと
    // 食い違うと、生成した宣言は正しくても実装のレビューが誤誘導される。
    [Fact]
    public void LastErrorAccessorsAreNotWrappedInTheBarrier()
    {
        var fns = SpecModel.Load(Path.Combine(RepoRoot(), "bindings", "spec"))
            .SelectMany(s => s.Functions)
            .ToDictionary(f => f.Name);

        Assert.False(fns["ocvu_get_last_error_status"].WrapInTryBarrier);
        Assert.False(fns["ocvu_get_abi_version"].WrapInTryBarrier);
        Assert.False(fns["ocvu_get_status_count"].WrapInTryBarrier);
    }

    // **知らないフィールドを黙って捨てない。**
    [Fact]
    public void UnknownFieldsAreRejected()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try
        {
            File.WriteAllText(Path.Combine(tmp, "bad.json"),
                "{ \"module\": \"bad\", \"functions\": [], \"typoField\": 1 }");
            Assert.Throws<SpecFormatException>(() => SpecModel.Load(tmp));
        }
        finally { Directory.Delete(tmp, recursive: true); }
    }

    // **0 件で通さない。** spec が消えても「空で成功」しては困る。
    [Fact]
    public void AnEmptySpecDirectoryIsRejected()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "ocvu-spec-" + Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        try { Assert.Throws<SpecFormatException>(() => SpecModel.Load(tmp)); }
        finally { Directory.Delete(tmp, recursive: true); }
    }
}
```

- [ ] **Step 4: 落ちることを見る**

Run: `pwsh tools/dev.ps1 test-managed`
Expected: FAIL —— `SpecModel` が無いのでビルドが通らない。

- [ ] **Step 5: `SpecModel.cs` を書く**

```csharp
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Ocvu.Generator;

public sealed class SpecFormatException : Exception
{
    public SpecFormatException(string message) : base(message) { }
}

public sealed record ParamSpec(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("cType")] string CType,
    [property: JsonPropertyName("csType")] string CsType,
    [property: JsonPropertyName("direction")] string Direction);

public sealed record FunctionSpec(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("summary")] string Summary,
    [property: JsonPropertyName("returns")] string Returns,
    [property: JsonPropertyName("csReturns")] string CsReturns,
    [property: JsonPropertyName("wrapInTryBarrier")] bool WrapInTryBarrier,
    [property: JsonPropertyName("params")] IReadOnlyList<ParamSpec> Params,
    [property: JsonPropertyName("barrierNote")] string? BarrierNote = null,
    [property: JsonPropertyName("entryPoint")] string? EntryPoint = null);

public sealed record ModuleSpec(
    [property: JsonPropertyName("module")] string Module,
    [property: JsonPropertyName("functions")] IReadOnlyList<FunctionSpec> Functions);

public static class SpecModel
{
    private static readonly JsonSerializerOptions Options = new()
    {
        // **知らないフィールドを黙って捨てない。** 綴り間違いは形の誤りである。
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        ReadCommentHandling = JsonCommentHandling.Disallow,
    };

    public static IReadOnlyList<ModuleSpec> Load(string specDir)
    {
        var files = Directory.GetFiles(specDir, "*.json")
            .Where(f => Path.GetFileName(f) != "schema.json")
            .OrderBy(f => f, StringComparer.Ordinal)
            .ToList();

        if (files.Count == 0)
        {
            throw new SpecFormatException($"spec が 1 件も見つかりません: {specDir}");
        }

        var result = new List<ModuleSpec>();
        foreach (var file in files)
        {
            ModuleSpec? spec;
            try
            {
                spec = JsonSerializer.Deserialize<ModuleSpec>(File.ReadAllText(file), Options);
            }
            catch (JsonException ex)
            {
                throw new SpecFormatException($"{Path.GetFileName(file)} を読めません: {ex.Message}");
            }
            if (spec is null)
            {
                throw new SpecFormatException($"{Path.GetFileName(file)} が null になりました");
            }
            result.Add(spec);
        }
        return result;
    }
}
```

- [ ] **Step 6: `.csproj` を 2 つ書き、solution に足す**

`bindings/generator/Ocvu.Generator/Ocvu.Generator.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <RootNamespace>Ocvu.Generator</RootNamespace>
  </PropertyGroup>
</Project>
```

`bindings/generator/Ocvu.Generator.Tests/Ocvu.Generator.Tests.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <IsPackable>false</IsPackable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="18.9.0" />
    <PackageReference Include="xunit" Version="2.9.3" />
    <PackageReference Include="xunit.runner.visualstudio" Version="4.0.0" />
    <PackageReference Include="JunitXml.TestLogger" Version="8.0.0" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="..\Ocvu.Generator\Ocvu.Generator.csproj" />
  </ItemGroup>
</Project>
```

**版は `tests/Managed/CvUnity.Tests.Managed/CvUnity.Tests.Managed.csproj` から写す** ——
Dependabot が NuGet を追うので、食い違うと更新のたびに片方だけ動く。

```bash
dotnet sln tests/Managed/CvUnity.Managed.sln add bindings/generator/Ocvu.Generator/Ocvu.Generator.csproj
dotnet sln tests/Managed/CvUnity.Managed.sln add bindings/generator/Ocvu.Generator.Tests/Ocvu.Generator.Tests.csproj
```

- [ ] **Step 7: 通ることを見る**

Run: `pwsh tools/dev.ps1 test-managed`
Expected: PASS。上の 4 件が緑。

- [ ] **Step 8: 壊して落ちることを見る**

**壊す前にコミットする。**

```bash
git add bindings tests/Managed/CvUnity.Managed.sln
git commit -m "wip(m5): spec と schema（壊す前に）"
```

3 通り壊し、それぞれ落ちることを見て `git checkout -- bindings/spec` で戻す:

1. `infra.json` の `"wrapInTryBarrier": false` を `true` に →
   `LastErrorAccessorsAreNotWrappedInTheBarrier` が FAIL
2. `infra.json` に `"typo": 1` を足す → `EverySpecFileLoads` が FAIL
3. `infra.json` を消す → `EverySpecFileLoads` が FAIL（0 件で通さない）

最後に緑を確認する。

- [ ] **Step 9: コミット**

```bash
git add bindings/spec/schema.json bindings/spec/infra.json \
        bindings/generator/Ocvu.Generator/SpecModel.cs \
        bindings/generator/Ocvu.Generator/Ocvu.Generator.csproj \
        bindings/generator/Ocvu.Generator.Tests/SpecSchemaTests.cs \
        bindings/generator/Ocvu.Generator.Tests/Ocvu.Generator.Tests.csproj \
        tests/Managed/CvUnity.Managed.sln
git commit -m "feat(m5): binding spec の形と、それを検証する schema"
```

---

## Task 2: C ヘッダの生成と golden test

**Files:**
- Create: `bindings/generator/Ocvu.Generator/CHeaderEmitter.cs`
- Create: `bindings/generator/Ocvu.Generator.Tests/CHeaderEmitterTests.cs`

**Interfaces:**
- Consumes: `ModuleSpec` / `FunctionSpec` / `ParamSpec`（Task 1）
- Produces: `CHeaderEmitter.Emit(ModuleSpec spec)` → `string`（ヘッダの全文）

- [ ] **Step 1: 失敗するテストを書く**

```csharp
using System;
using Xunit;

namespace Ocvu.Generator.Tests;

public class CHeaderEmitterTests
{
    private static ModuleSpec Sample() => new(
        Module: "sample",
        Functions: new[]
        {
            new FunctionSpec("ocvu_sample_do", "何かする。", "ocvu_status", "int", true,
                new[]
                {
                    new ParamSpec("handle", "ocvu_mat_handle", "ulong", "in"),
                    new ParamSpec("outValue", "int32_t*", "out int", "out"),
                }),
        });

    [Fact]
    public void EmitsTheDeclaration()
    {
        Assert.Contains(
            "OCVU_API ocvu_status ocvu_sample_do(ocvu_mat_handle handle, int32_t* outValue);",
            CHeaderEmitter.Emit(Sample()));
    }

    // 引数が無い関数は (void) にする。() は C では「引数不定」という別の意味になる。
    [Fact]
    public void NoParametersBecomesVoid()
    {
        var spec = new ModuleSpec("sample", new[]
        {
            new FunctionSpec("ocvu_sample_none", "何もしない。", "int32_t", "int", false,
                Array.Empty<ParamSpec>()),
        });
        Assert.Contains("OCVU_API int32_t ocvu_sample_none(void);", CHeaderEmitter.Emit(spec));
    }

    // **include guard が module ごとに違うこと。** 同じなら 2 つ目が丸ごと消える。
    [Fact]
    public void GuardIsPerModule()
    {
        Assert.Contains("#ifndef OCVU_SAMPLE_H", CHeaderEmitter.Emit(Sample()));
    }

    // **生成物であることが読んで分かること。** 手で直されると spec が正本でなくなる。
    [Fact]
    public void SaysItIsGenerated()
    {
        var text = CHeaderEmitter.Emit(Sample());
        Assert.Contains("このファイルは生成物である", text);
        Assert.Contains("bindings/spec/sample.json", text);
    }

    // **summary が落ちないこと。** 落ちると生成物のほうが情報量で負ける。
    [Fact]
    public void CarriesTheSummary()
    {
        Assert.Contains("何かする。", CHeaderEmitter.Emit(Sample()));
    }

    // **囲わない理由を書き出すこと。** 実装をレビューする人が最初に読む場所である。
    [Fact]
    public void CarriesTheBarrierNote()
    {
        var spec = new ModuleSpec("sample", new[]
        {
            new FunctionSpec("ocvu_sample_raw", "囲わない。", "ocvu_status", "int", false,
                Array.Empty<ParamSpec>(), BarrierNote: "自分でエラーを消してしまうため"),
        });
        Assert.Contains("例外バリアで囲まない: 自分でエラーを消してしまうため",
                        CHeaderEmitter.Emit(spec));
    }
}
```

- [ ] **Step 2: 落ちることを見る**

Run: `pwsh tools/dev.ps1 test-managed`
Expected: FAIL —— `CHeaderEmitter` が存在しない。

- [ ] **Step 3: `CHeaderEmitter.cs` を書く**

```csharp
using System.Text;

namespace Ocvu.Generator;

public static class CHeaderEmitter
{
    public static string Emit(ModuleSpec spec)
    {
        var guard = $"OCVU_{spec.Module.ToUpperInvariant()}_H";
        var sb = new StringBuilder();

        sb.AppendLine("/*");
        sb.AppendLine(" * このファイルは生成物である。手で編集しないこと。");
        sb.AppendLine($" * 正本: bindings/spec/{spec.Module}.json");
        sb.AppendLine(" * 生成: ./tools/dev.ps1 generate");
        sb.AppendLine(" */");
        sb.AppendLine($"#ifndef {guard}");
        sb.AppendLine($"#define {guard}");
        sb.AppendLine();
        sb.AppendLine("#include \"opencv_unity_native.h\"");
        sb.AppendLine();
        sb.AppendLine("#ifdef __cplusplus");
        sb.AppendLine("extern \"C\" {");
        sb.AppendLine("#endif");
        sb.AppendLine();

        foreach (var fn in spec.Functions)
        {
            sb.AppendLine($"/* {fn.Summary} */");
            if (!fn.WrapInTryBarrier && !string.IsNullOrEmpty(fn.BarrierNote))
            {
                sb.AppendLine($"/* 例外バリアで囲まない: {fn.BarrierNote} */");
            }
            var ps = fn.Params.Count == 0
                ? "void"
                : string.Join(", ", fn.Params.Select(p => $"{p.CType} {p.Name}"));
            sb.AppendLine($"OCVU_API {fn.Returns} {fn.Name}({ps});");
            sb.AppendLine();
        }

        sb.AppendLine("#ifdef __cplusplus");
        sb.AppendLine("}  /* extern \"C\" */");
        sb.AppendLine("#endif");
        sb.AppendLine();
        sb.AppendLine($"#endif  /* {guard} */");
        return sb.ToString();
    }
}
```

- [ ] **Step 4: 通ることを見る**

Run: `pwsh tools/dev.ps1 test-managed`
Expected: PASS。

- [ ] **Step 5: 壊して落ちることを見る**

**壊す前にコミットする。** `guard` を `"OCVU_H"` の定数にする →
`GuardIsPerModule` が FAIL。戻して緑を確認する。

- [ ] **Step 6: コミット**

```bash
git add bindings/generator/Ocvu.Generator/CHeaderEmitter.cs \
        bindings/generator/Ocvu.Generator.Tests/CHeaderEmitterTests.cs
git commit -m "feat(m5): spec から C ABI ヘッダを生成する"
```

---

## Task 3: C# P/Invoke の生成と golden test

**Files:**
- Create: `bindings/generator/Ocvu.Generator/CsPInvokeEmitter.cs`
- Create: `bindings/generator/Ocvu.Generator.Tests/CsPInvokeEmitterTests.cs`

**Interfaces:**
- Consumes: `ModuleSpec`
- Produces: `CsPInvokeEmitter.Emit(ModuleSpec spec)` → `string`

- [ ] **Step 1: 失敗するテストを書く**

```csharp
using Xunit;

namespace Ocvu.Generator.Tests;

public class CsPInvokeEmitterTests
{
    private static ModuleSpec Sample() => new(
        Module: "sample",
        Functions: new[]
        {
            new FunctionSpec("ocvu_sample_do", "何かする。", "ocvu_status", "int", true,
                new[]
                {
                    new ParamSpec("handle", "ocvu_mat_handle", "ulong", "in"),
                    new ParamSpec("outValue", "int32_t*", "out int", "out"),
                }),
        });

    // **partial にする。** module ごとにファイルが分かれるので、
    // partial でないと 2 つ目のクラス定義が衝突する。
    [Fact]
    public void EmitsAPartialClassSoModulesCanCoexist()
    {
        Assert.Contains("internal static partial class NativeMethods",
                        CsPInvokeEmitter.Emit(Sample()));
    }

    // **CallingConvention.Cdecl を必ず付ける。** 付け忘れるとスタックが壊れる
    // （add-abi-function skill の「よくある取りこぼし」）。
    [Fact]
    public void AlwaysDeclaresCdecl()
    {
        Assert.Contains("CallingConvention = CallingConvention.Cdecl",
                        CsPInvokeEmitter.Emit(Sample()));
    }

    [Fact]
    public void EmitsTheSignature()
    {
        Assert.Contains("internal static extern int ocvu_sample_do(ulong handle, out int outValue);",
                        CsPInvokeEmitter.Emit(Sample()));
    }

    // **entryPoint を指定した場合はそれを出す。** C 側 1 本に対して C# の宣言が
    // 2 つある場合（byte[] 版と IntPtr 版）に要る。
    [Fact]
    public void HonoursAnExplicitEntryPoint()
    {
        var spec = new ModuleSpec("sample", new[]
        {
            new FunctionSpec("ocvu_sample_do_ptr", "ポインタ版。", "ocvu_status", "int", true,
                new[] { new ParamSpec("p", "void*", "System.IntPtr", "in") },
                BarrierNote: null, EntryPoint: "ocvu_sample_do"),
        });
        var text = CsPInvokeEmitter.Emit(spec);
        Assert.Contains("EntryPoint = \"ocvu_sample_do\"", text);
        // entryPoint を出しても Cdecl は落とさない。
        Assert.Contains("CallingConvention = CallingConvention.Cdecl", text);
    }

    [Fact]
    public void SaysItIsGenerated()
    {
        Assert.Contains("このファイルは生成物である", CsPInvokeEmitter.Emit(Sample()));
    }
}
```

- [ ] **Step 2: 落ちることを見る**

Run: `pwsh tools/dev.ps1 test-managed`
Expected: FAIL —— `CsPInvokeEmitter` が存在しない。

- [ ] **Step 3: `CsPInvokeEmitter.cs` を書く**

```csharp
using System.Text;

namespace Ocvu.Generator;

public static class CsPInvokeEmitter
{
    public static string Emit(ModuleSpec spec)
    {
        var sb = new StringBuilder();
        sb.AppendLine("// このファイルは生成物である。手で編集しないこと。");
        sb.AppendLine($"// 正本: bindings/spec/{spec.Module}.json");
        sb.AppendLine("// 生成: ./tools/dev.ps1 generate");
        sb.AppendLine();
        sb.AppendLine("using System.Runtime.InteropServices;");
        sb.AppendLine();
        sb.AppendLine("namespace CvUnity.Interop");
        sb.AppendLine("{");
        sb.AppendLine("    internal static partial class NativeMethods");
        sb.AppendLine("    {");

        foreach (var fn in spec.Functions)
        {
            sb.AppendLine($"        /// <summary>{fn.Summary}</summary>");
            var entry = string.IsNullOrEmpty(fn.EntryPoint)
                ? ""
                : $"EntryPoint = \"{fn.EntryPoint}\", ";
            sb.AppendLine($"        [DllImport(LibraryName, {entry}CallingConvention = CallingConvention.Cdecl)]");
            var ps = string.Join(", ", fn.Params.Select(p => $"{p.CsType} {p.Name}"));
            sb.AppendLine($"        internal static extern {fn.CsReturns} {fn.Name}({ps});");
            sb.AppendLine();
        }

        sb.AppendLine("    }");
        sb.AppendLine("}");
        return sb.ToString();
    }
}
```

- [ ] **Step 4: 通ることを見る**

Run: `pwsh tools/dev.ps1 test-managed`
Expected: PASS。

- [ ] **Step 5: 壊して落ちることを見る**

**壊す前にコミットする。** `[DllImport(LibraryName, {entry}CallingConvention = CallingConvention.Cdecl)]`
を `[DllImport(LibraryName)]` に変える → `AlwaysDeclaresCdecl` と
`HonoursAnExplicitEntryPoint` が FAIL。戻して緑を確認する。

- [ ] **Step 6: コミット**

```bash
git add bindings/generator/Ocvu.Generator/CsPInvokeEmitter.cs \
        bindings/generator/Ocvu.Generator.Tests/CsPInvokeEmitterTests.cs
git commit -m "feat(m5): spec から C# の P/Invoke を生成する"
```

---

## Task 4: `dev.ps1 generate` と、生成物が古いと落ちる検査

**Files:**
- Create: `bindings/generator/Ocvu.Generator/Program.cs`
- Modify: `tools/dev.ps1`（`ValidateSet`、`switch`、`$ToolsTestScriptsFast`、関数 2 つ）
- Create: `tools/tests/BindingGenerator.Tests.ps1`
- Create: `native/include/ocvu/infra.h`（生成物）
- Create: `Packages/.../Runtime/Interop/NativeMethods.Infra.g.cs`（生成物）

**Interfaces:**
- Consumes: `SpecModel.Load`、`CHeaderEmitter.Emit`、`CsPInvokeEmitter.Emit`
- Produces: `dotnet run --project bindings/generator/Ocvu.Generator -- --repo-root <path> [--check]`。
  `--check` は書かずに差分の有無を終了コードで返す（差分あり = 1、正常 = 0、引数不正 = 2）

- [ ] **Step 1: `Program.cs` を書く**

```csharp
using Ocvu.Generator;

var repoRoot = Directory.GetCurrentDirectory();
var check = false;
for (var i = 0; i < args.Length; i++)
{
    if (args[i] == "--repo-root" && i + 1 < args.Length) { repoRoot = args[++i]; }
    else if (args[i] == "--check") { check = true; }
    else { Console.Error.WriteLine($"unknown argument: {args[i]}"); return 2; }
}

var specs = SpecModel.Load(Path.Combine(repoRoot, "bindings", "spec"));

var outputs = new List<(string Path, string Text)>();
foreach (var spec in specs)
{
    outputs.Add((Path.Combine(repoRoot, "native", "include", "ocvu", $"{spec.Module}.h"),
                 CHeaderEmitter.Emit(spec)));
    var pascal = char.ToUpperInvariant(spec.Module[0]) + spec.Module[1..];
    outputs.Add((Path.Combine(repoRoot, "Packages", "com.ayutaz.opencv-unity-native",
                              "Runtime", "Interop", $"NativeMethods.{pascal}.g.cs"),
                 CsPInvokeEmitter.Emit(spec)));
}

var stale = new List<string>();
foreach (var (path, text) in outputs)
{
    var existing = File.Exists(path) ? File.ReadAllText(path) : null;
    // 改行を正規化して比べる。CRLF / LF の差で赤くしない。
    var same = existing is not null
        && existing.Replace("\r\n", "\n") == text.Replace("\r\n", "\n");
    if (same) { continue; }

    stale.Add(Path.GetRelativePath(repoRoot, path));
    if (!check)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
    }
}

if (check && stale.Count > 0)
{
    Console.Error.WriteLine("生成物が spec と食い違っています:");
    foreach (var s in stale) { Console.Error.WriteLine($"  - {s}"); }
    Console.Error.WriteLine("./tools/dev.ps1 generate を実行してコミットしてください。");
    return 1;
}

Console.WriteLine(check
    ? $"==> 生成物は spec と一致しています（{outputs.Count} ファイル）"
    : $"==> {outputs.Count} ファイルを生成しました（更新 {stale.Count} 件）");
return 0;
```

- [ ] **Step 2: `dev.ps1` に入口を足す**

`ValidateSet` に `'generate'` と `'verify-generated'` を足す。
関数を 2 つ足す。**`dev.ps1` の既存の関数は `Invoke-Checked` で外部コマンドを
包み、非 0 で `Write-DevFailure` に落としている。** 同じ形にすること
（`Build-Native` や `Test-Managed` の書き方を読んでから書く）:

```powershell
function Invoke-Generate {
    $proj = Join-Path $RepoRoot 'bindings/generator/Ocvu.Generator'
    Invoke-Checked 'run the binding generator' {
        & dotnet run --project $proj -- --repo-root $RepoRoot
    }
}

function Test-Generated {
    $proj = Join-Path $RepoRoot 'bindings/generator/Ocvu.Generator'
    Invoke-Checked 'verify the generated bindings are up to date' {
        & dotnet run --project $proj -- --repo-root $RepoRoot --check
    }
}
```

**`Invoke-Checked` という名前は仮である。** `tools/dev.ps1` を開き、
既存の関数が外部コマンドの終了コードをどう見ているかを読んで、
**同じヘルパを使うこと**（`$LASTEXITCODE -ne 0` を見て `Write-DevFailure`
に渡す形になっているはずである）。**新しいヘルパを作らない。**

`switch` に足す:

```powershell
'generate'          { Invoke-Generate }
'verify-generated'  { Test-Generated }
```

**`test` にも足す** —— 生成物のずれは速いレーンで捕まえる:

```powershell
'test' { Reset-Results; Test-Tools; Test-Generated; Test-Native; Test-Managed }
```

- [ ] **Step 3: 生成して、木に入れる**

Run: `pwsh tools/dev.ps1 generate`

`native/include/ocvu/infra.h` と
`Packages/.../Runtime/Interop/NativeMethods.Infra.g.cs` ができる。

**この時点では既存の `NativeMethods.cs` と宣言が重複する。**
`Runtime/Interop` は Unity と shim の両方がコンパイルするので、
**重複したままだと両方で落ちる。** そこで **Task 4 では `.g.cs` を
`Runtime/Interop` の外（`bindings/out/` 等）には置かず、生成先はそのままにして、
`NativeMethods.cs` 側から `infra` の 3 本をこの Step で削る。**

削るのは `ocvu_get_abi_version` / `ocvu_get_last_error_status` /
`ocvu_get_status_count` の 3 つの `[DllImport]` 宣言と、
`internal static class NativeMethods` を `internal static partial class NativeMethods`
に変える 1 行である。

Run: `pwsh tools/dev.ps1 test-managed`
Expected: PASS（L3 の 44 件が減らないこと）。

- [ ] **Step 4: 失敗する検査を書く（`tools/tests/BindingGenerator.Tests.ps1`）**

```powershell
#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$script:failures = @()
function Assert-That([bool]$condition, [string]$what) {
    if ($condition) { Write-Host "  PASS  $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures += $what }
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$dev = Join-Path $repoRoot 'tools/dev.ps1'

# --- 生成物が spec と一致していること ---
& pwsh -NoProfile -File $dev verify-generated | Out-Null
Assert-That ($LASTEXITCODE -eq 0) 'the generated bindings match the spec'

# --- **生成物を手で変えたら落ちること。** これが無いと検査が働いた証拠が無い ---
$header = Join-Path $repoRoot 'native/include/ocvu/infra.h'
$backup = Get-Content -LiteralPath $header -Raw
try {
    Add-Content -LiteralPath $header -Value '/* 手で足した行 */'
    & pwsh -NoProfile -File $dev verify-generated 2>&1 | Out-Null
    Assert-That ($LASTEXITCODE -ne 0) 'editing a generated file by hand fails the check'
}
finally { Set-Content -LiteralPath $header -Value $backup -NoNewline }

# --- 戻したら通ること（後始末が効いていることの確認） ---
& pwsh -NoProfile -File $dev verify-generated | Out-Null
Assert-That ($LASTEXITCODE -eq 0) 'restoring the generated file makes the check pass again'

# --- 生成物に「生成物である」と書いてあること ---
Assert-That ((Get-Content -LiteralPath $header -Raw) -match 'このファイルは生成物である') `
    'the generated header says it is generated'

if ($script:failures.Count -gt 0) {
    [Console]::Error.WriteLine("`n$($script:failures.Count) assertion(s) failed")
    exit 1
}
Write-Host "`nall assertions passed" -ForegroundColor Green
```

**`$ToolsTestScriptsFast` に足す** —— どのレーンからも走らない検査は検証機構ではない。
`tools/tests/OpenCvConfig.Tests.ps1` が「`tools/tests/*.Tests.ps1` が
`dev.ps1` に配線されていること」を見るので、足さないとそこが落ちる。

- [ ] **Step 5: 通ることを見る**

Run: `pwsh tools/dev.ps1 test`
Expected: PASS。`BindingGenerator.Tests.ps1` の 4 件が緑。

- [ ] **Step 6: 壊して落ちることを見る**

**壊す前にコミットする。** `Program.cs` の `--check` の分岐で
`return 1;` を `return 0;` に変える →
`editing a generated file by hand fails the check` が FAIL。戻して緑を確認する。

- [ ] **Step 7: コミット**

```bash
git add bindings/generator/Ocvu.Generator/Program.cs tools/dev.ps1 \
        tools/tests/BindingGenerator.Tests.ps1 \
        native/include/ocvu/infra.h \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.Infra.g.cs \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.cs
git commit -m "feat(m5): dev.ps1 generate と、生成物が古いと落ちる検査"
```

---

## Task 5: 残る 17 本を spec に移し、手書き側から外す

**Files:**
- Create: `bindings/spec/core.json`、`bindings/spec/imgproc.json`、`bindings/spec/imgcodecs.json`
- Modify: `bindings/spec/infra.json`（残る 6 本を足す）
- Modify: `native/include/opencv_unity_native.h`
- Modify: `Packages/.../Runtime/Interop/NativeMethods.cs`

**Interfaces:**
- Consumes: `dev.ps1 generate`（Task 4）
- Produces: `native/include/ocvu/{infra,core,imgproc,imgcodecs}.h` と
  `NativeMethods.{Infra,Core,Imgproc,Imgcodecs}.g.cs`

- [ ] **Step 1: 現状を数え、module を割り当てる**

```bash
grep -oE 'ocvu_[a-z_]+\(' native/include/opencv_unity_native.h | tr -d '(' | sort -u
```

**20 本ある。** 割り当て:

| module | 関数 |
| --- | --- |
| `infra` | `get_abi_version` / `get_last_error_status` / `get_last_error_message` / `get_status_count` / `get_status_value` / `get_opencv_version` / `get_build_information` / `debug_throw` / `debug_crash` |
| `core` | `mat_create` / `mat_release` / `mat_clone` / `mat_get_info` / `mat_copy_from_buffer` / `mat_copy_to_buffer` |
| `imgproc` | `cvt_color` / `resize` / `gaussian_blur` |
| `imgcodecs` | `imencode` / `imdecode` |

**注意点が 3 つある。**

1. **`ocvu_debug_crash` は `ocvu_status` を返さない**（戻らない前提の関数）。
   `"returns": "void"` / `"csReturns": "void"` / `"wrapInTryBarrier": false` にする
2. **`mat_copy_from_buffer` / `mat_copy_to_buffer` は C# 側に 2 宣言ある**
   （`byte[]` 版と `IntPtr` 版）。spec では
   `ocvu_mat_copy_from_buffer` と `ocvu_mat_copy_from_buffer_ptr` の 2 エントリにし、
   後者に `"entryPoint": "ocvu_mat_copy_from_buffer"` を書く。
   **C ヘッダには前者だけを出したいので、`ocvu_*_ptr` は
   `CHeaderEmitter` から除外する** —— Step 3 で対応する
3. **`ocvu_mat_info` の struct は生成しない。** 型は
   `opencv_unity_native.h` に手書きで残す

**シグネチャは 1 バイトも変えない。** `OCVU_ABI_VERSION` は 1 のままである。

- [ ] **Step 2: spec を書き、生成して差分を見る**

```bash
pwsh tools/dev.ps1 generate
git diff --stat native/include/ocvu/
```

- [ ] **Step 3: `ocvu_*_ptr` を C ヘッダから外す**

`CHeaderEmitter.Emit` で `EntryPoint` を持つ関数を飛ばす。
**C 側では同じ 1 本なので、2 度宣言すると重複定義になる。**

```csharp
foreach (var fn in spec.Functions)
{
    // EntryPoint を持つものは C# 側の別 overload であって、C の宣言は 1 本である。
    if (!string.IsNullOrEmpty(fn.EntryPoint)) { continue; }
    ...
}
```

`CHeaderEmitterTests.cs` に足す:

```csharp
    [Fact]
    public void OverloadsThatShareAnEntryPointAreNotDeclaredTwice()
    {
        var spec = new ModuleSpec("sample", new[]
        {
            new FunctionSpec("ocvu_sample_do", "本体。", "ocvu_status", "int", true,
                Array.Empty<ParamSpec>()),
            new FunctionSpec("ocvu_sample_do_ptr", "ポインタ版。", "ocvu_status", "int", true,
                Array.Empty<ParamSpec>(), BarrierNote: null, EntryPoint: "ocvu_sample_do"),
        });
        var text = CHeaderEmitter.Emit(spec);
        Assert.Contains("ocvu_sample_do(void);", text);
        Assert.DoesNotContain("ocvu_sample_do_ptr", text);
    }
```

- [ ] **Step 4: 手書きのヘッダから宣言を外す**

`native/include/opencv_unity_native.h` に残すのは
**`OCVU_API` の定義・`ocvu_status`・`OCVU_STATUS_LIST`・`ocvu_mat_handle`・
`ocvu_mat_info`・`OCVU_MAT_TYPE_*`・`OCVU_CVT_*`・`OCVU_INTER_*`・`OCVU_IMREAD_*`**
だけ。末尾に:

```c
/*
 * module ごとの宣言は生成物である（bindings/spec/*.json → ./tools/dev.ps1 generate）。
 * **ここに手で足さないこと。** 足しても generate で消える。
 */
#include "ocvu/infra.h"
#include "ocvu/core.h"
#include "ocvu/imgproc.h"
#include "ocvu/imgcodecs.h"
```

**`ocvu/*.h` はこのヘッダを include し、こちらもそれらを include するので
循環する。** include guard があるので展開は止まる。
`ocvu/*.h` 側の include は、**それを単体で include する利用者のために残す。**

- [ ] **Step 5: C# 側から宣言を外す**

`NativeMethods.cs` から生成対象の `[DllImport]` をすべて消す。
**残すのは `LibraryName` の `#if UNITY_IOS` 分岐と `ocvu_mat_info` の struct** である。

- [ ] **Step 6: 全レーンを回す**

```
pwsh tools/dev.ps1 test
pwsh tools/dev.ps1 test-asan
pwsh tools/dev.ps1 test-unity-editmode
```

Expected: すべて PASS。**L1 44 件 / L3 44 件 / EditMode 33 件が 1 件も減らないこと** ——
減っていたら生成が宣言を落としている。

- [ ] **Step 7: 壊して落ちることを見る**

**壊す前にコミットする。** `bindings/spec/imgproc.json` から
`ocvu_resize` を消して `dev.ps1 generate` → **L1 と L3 がリンクエラーで落ちる**。
戻して緑を確認する。

- [ ] **Step 8: コミット**

```bash
git add bindings/spec bindings/generator native/include \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop
git commit -m "refactor(m5): 20 本の宣言を spec から生成する（module ごと）"
```

---

## Task 6: 到達性 conformance test の生成

**Files:**
- Create: `bindings/generator/Ocvu.Generator/ReachabilityEmitter.cs`
- Create: `bindings/generator/Ocvu.Generator.Tests/ReachabilityEmitterTests.cs`
- Create: `tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs`（生成物）
- Modify: `bindings/generator/Ocvu.Generator/Program.cs`
- Modify: `tests/UnityProject/Assets/Tests/EditMode/AbiSurfaceTests.cs`
- Modify: `tests/UnityProject/Assets/Tests/PlayMode/AbiSurfacePlayerTests.cs`

**Interfaces:**
- Consumes: `IReadOnlyList<ModuleSpec>`
- Produces: `ReachabilityEmitter.Emit(IReadOnlyList<ModuleSpec>)` → `string`。
  `public static class AbiReachabilityChecks { public static int CallEveryEntryPoint(); }`
  を含み、**呼んだ entry point の本数を返す**

**なぜこれが要るか。** M4 の点検で実測した —— **手書きの 19 本のうち 7 本が
Editor でも Player でも一度も呼ばれていなかった**（`imgcodecs` 全部を含む）。
L1 と L3 は見ているが、**stripping で消えないことを確かめられるのは Player だけ**である。
**呼ばれない宣言は、消えても誰も気づかない。**

- [ ] **Step 1: 失敗するテストを書く**

```csharp
using System;
using System.Collections.Generic;
using Xunit;

namespace Ocvu.Generator.Tests;

public class ReachabilityEmitterTests
{
    private static IReadOnlyList<ModuleSpec> Sample() => new[]
    {
        new ModuleSpec("sample", new[]
        {
            new FunctionSpec("ocvu_sample_do", "何かする。", "ocvu_status", "int", true,
                new[] { new ParamSpec("handle", "ocvu_mat_handle", "ulong", "in") }),
        }),
    };

    [Fact]
    public void CallsEveryEntryPoint()
    {
        Assert.Contains("NativeMethods.ocvu_sample_do(", ReachabilityEmitter.Emit(Sample()));
    }

    // **数を返すこと。** 「呼んだ」ではなく「何本呼んだ」を見たい。
    [Fact]
    public void ReturnsHowManyItCalled()
    {
        var text = ReachabilityEmitter.Emit(Sample());
        Assert.Contains("public static int CallEveryEntryPoint()", text);
        Assert.Contains("return 1;", text);
    }

    // **意図的に落ちる関数は呼ばない。** ocvu_debug_crash は戻らない。
    [Fact]
    public void SkipsTheCrashProbe()
    {
        var spec = new[]
        {
            new ModuleSpec("infra", new[]
            {
                new FunctionSpec("ocvu_debug_crash", "意図的に落ちる。", "void", "void", false,
                    new[] { new ParamSpec("kind", "int32_t", "int", "in") }),
                new FunctionSpec("ocvu_get_abi_version", "版を返す。", "int32_t", "int", false,
                    Array.Empty<ParamSpec>()),
            }),
        };
        var text = ReachabilityEmitter.Emit(spec);
        Assert.DoesNotContain("ocvu_debug_crash", text);
        Assert.Contains("ocvu_get_abi_version", text);
        Assert.Contains("return 1;", text);
    }

    [Fact]
    public void SaysItIsGenerated()
    {
        Assert.Contains("このファイルは生成物である", ReachabilityEmitter.Emit(Sample()));
    }
}
```

- [ ] **Step 2: 落ちることを見る**

Run: `pwsh tools/dev.ps1 test-managed`
Expected: FAIL —— `ReachabilityEmitter` が存在しない。

- [ ] **Step 3: `ReachabilityEmitter.cs` を書く**

**引数は「型ごとの無害な既定値」で埋める。** 目的は**呼べること**であって
正しい結果ではない。ほとんどは失敗の status を返すが、
**entry point が解決したことは証明できる。**

```csharp
using System.Text;

namespace Ocvu.Generator;

public static class ReachabilityEmitter
{
    // 型ごとの無害な実引数。**結果は見ない。呼べることだけを見る。**
    private static string Argument(ParamSpec p) => p.CsType switch
    {
        "ulong" => "0UL",
        "int" => "0",
        "long" => "0L",
        "double" => "0.0",
        "byte[]" => "null",
        var t when t.StartsWith("out ") => "out _",
        _ => "default",
    };

    public static string Emit(IReadOnlyList<ModuleSpec> specs)
    {
        var fns = specs.SelectMany(s => s.Functions)
            // **意図的に落ちる関数は呼ばない。** ocvu_debug_crash は戻らない。
            .Where(f => f.Name != "ocvu_debug_crash")
            .ToList();

        var sb = new StringBuilder();
        sb.AppendLine("// このファイルは生成物である。手で編集しないこと。");
        sb.AppendLine("// 正本: bindings/spec/*.json");
        sb.AppendLine("// 生成: ./tools/dev.ps1 generate");
        sb.AppendLine("//");
        sb.AppendLine("// **なぜ在るか。** IL2CPP の stripping は、呼ばれない P/Invoke 宣言を");
        sb.AppendLine("// 消せる。M4 の点検では、手書きの 19 本のうち 7 本が Editor でも");
        sb.AppendLine("// Player でも一度も呼ばれていなかった。**呼ばれない宣言は、消えても");
        sb.AppendLine("// 誰も気づかない。** ここは全 entry point を 1 回ずつ呼ぶ。");
        sb.AppendLine("// 結果は見ない —— 呼べたことだけを見る。");
        sb.AppendLine();
        sb.AppendLine("using CvUnity.Interop;");
        sb.AppendLine();
        sb.AppendLine("public static class AbiReachabilityChecks");
        sb.AppendLine("{");
        sb.AppendLine("    public static int CallEveryEntryPoint()");
        sb.AppendLine("    {");

        foreach (var fn in fns)
        {
            var args = string.Join(", ", fn.Params.Select(Argument));
            sb.AppendLine($"        NativeMethods.{fn.Name}({args});");
        }

        sb.AppendLine($"        return {fns.Count};");
        sb.AppendLine("    }");
        sb.AppendLine("}");
        return sb.ToString();
    }
}
```

**`NativeMethods` は `internal` なので、Unity の test assembly からは見えない。**
`Packages/.../Runtime/Interop/AssemblyInfo.cs` は**既に在り**、
`CvUnity.Core` / `CvUnity.Tests.Managed` / `CvUnity.Runtime` の 3 つを許している。
**1 行足す**:

```csharp
// 到達性テスト（生成物）は NativeMethods を直接呼ぶ。**公開 API 経由では、
// どの entry point が呼ばれたかを spec から機械的に導けない。**
[assembly: InternalsVisibleTo("CvUnity.Tests.Shared")]
```

**同じファイルのコメントが「public にはしない — P/Invoke 宣言は実装詳細であり、
利用者向けの API ではない」と書いている。** この追加はその方針を変えない ——
見えるようにするのはテスト assembly に対してだけである。

`Runtime/Interop` の asmdef に変更は要らない。

- [ ] **Step 4: `Program.cs` に出力を足す**

**module ごとではなく 1 ファイル**である（全 entry point を横断するため）。
`foreach (var spec in specs)` の**外**に置く:

```csharp
outputs.Add((Path.Combine(repoRoot, "tests", "UnityProject", "Assets", "Tests",
                          "Shared", "AbiReachabilityChecks.g.cs"),
             ReachabilityEmitter.Emit(specs)));
```

- [ ] **Step 5: Unity の入口を足す**

`AbiSurfaceTests.cs`（EditMode）に足す:

```csharp
    [Test]
    public void EveryEntryPointIsReachable()
    {
        var called = AbiReachabilityChecks.CallEveryEntryPoint();
        // **0 件で緑にしない。** spec が空でも「呼び終えた」と言えてしまう。
        Assert.Greater(called, 10, "spec が空だと 0 本になる");
    }
```

`AbiSurfacePlayerTests.cs`（PlayMode。**こちらが本命**）に足す:

```csharp
    [UnityTest]
    public IEnumerator EveryEntryPointIsReachable()
    {
        // **stripping が P/Invoke を消していたら、ここで
        // EntryPointNotFoundException になる。** Mono では再現しない。
        var called = AbiReachabilityChecks.CallEveryEntryPoint();
        Assert.Greater(called, 10, "spec が空だと 0 本になる");
        yield return null;
    }
```

- [ ] **Step 6: 両レーンを回す**

```
pwsh tools/dev.ps1 generate
pwsh tools/dev.ps1 test-unity-editmode
pwsh tools/dev.ps1 test-unity-player
```

Expected: EditMode が **34 passed**、Player が **19 passed**（それぞれ +1）。

- [ ] **Step 7: 壊して落ちることを見る**

**壊す前にコミットする。** `NativeMethods.Imgcodecs.g.cs` の
`ocvu_imencode` の宣言に `EntryPoint = "ocvu_does_not_exist"` を足して
EditMode を回す → `EveryEntryPointIsReachable` が
`EntryPointNotFoundException` で FAIL する。戻して緑を確認する。

**M4 で同じ壊し方をしたときは 33 件中 2 件だけが落ちた**（encode を使う 2 件）。
**いまは 1 件で全 entry point を守る。**

- [ ] **Step 8: コミット**

```bash
git add bindings/generator tests/UnityProject/Assets/Tests \
        Packages/com.ayutaz.opencv-unity-native/Runtime/Interop
git commit -m "feat(m5): 全 entry point を呼ぶ到達性テストを生成する"
```

---

## Task 7: API 対応表の生成

**Files:**
- Create: `bindings/generator/Ocvu.Generator/ApiMapEmitter.cs`
- Create: `bindings/generator/Ocvu.Generator.Tests/ApiMapEmitterTests.cs`
- Create: `docs/api-map.md`（生成物）
- Modify: `bindings/generator/Ocvu.Generator/Program.cs`
- Modify: `docs/README.md`

**Interfaces:**
- Consumes: `IReadOnlyList<ModuleSpec>`
- Produces: `ApiMapEmitter.Emit(IReadOnlyList<ModuleSpec>)` → `string`（Markdown）

**roadmap の完了条件**: 「API 対応表を生成し、**「OpenCV 全対応」という曖昧な表現を使わない**」。

- [ ] **Step 1: 失敗するテストを書く**

```csharp
using System;
using System.Collections.Generic;
using Xunit;

namespace Ocvu.Generator.Tests;

public class ApiMapEmitterTests
{
    private static IReadOnlyList<ModuleSpec> Sample() => new[]
    {
        new ModuleSpec("imgproc", new[]
        {
            new FunctionSpec("ocvu_resize", "大きさを変える。", "ocvu_status", "int", true,
                Array.Empty<ParamSpec>()),
        }),
    };

    [Fact]
    public void ListsEveryFunctionWithItsModule()
    {
        Assert.Contains("| `imgproc` | `ocvu_resize` | 大きさを変える。 |",
                        ApiMapEmitter.Emit(Sample()));
    }

    // **総数を書く。** 「全対応」ではなく数を出すのがこの表の役目である。
    [Fact]
    public void StatesTheCount()
    {
        Assert.Contains("**公開している C ABI は 1 本**", ApiMapEmitter.Emit(Sample()));
    }

    [Fact]
    public void SaysItIsGenerated()
    {
        Assert.Contains("このファイルは生成物である", ApiMapEmitter.Emit(Sample()));
    }
}
```

- [ ] **Step 2: 落ちることを見る**

Run: `pwsh tools/dev.ps1 test-managed`
Expected: FAIL —— `ApiMapEmitter` が存在しない。

- [ ] **Step 3: `ApiMapEmitter.cs` を書く**

```csharp
using System.Text;

namespace Ocvu.Generator;

public static class ApiMapEmitter
{
    public static string Emit(IReadOnlyList<ModuleSpec> specs)
    {
        var all = specs.SelectMany(s => s.Functions.Select(f => (Module: s.Module, Fn: f)))
                       .ToList();
        var sb = new StringBuilder();
        sb.AppendLine("# API 対応表");
        sb.AppendLine();
        sb.AppendLine("<!-- このファイルは生成物である。手で編集しないこと。 -->");
        sb.AppendLine("<!-- 正本: bindings/spec/*.json  生成: ./tools/dev.ps1 generate -->");
        sb.AppendLine();
        sb.AppendLine($"**公開している C ABI は {all.Count} 本**である。");
        sb.AppendLine();
        sb.AppendLine("**「OpenCV 全対応」とは書かない** —— 何が在って何が無いかは、この表が示す。");
        sb.AppendLine("ここに無い関数は**まだ無い**のであって、隠れているのではない。");
        sb.AppendLine();
        sb.AppendLine("| module | 関数 | 内容 |");
        sb.AppendLine("| --- | --- | --- |");
        foreach (var (module, fn) in all.OrderBy(x => x.Module, StringComparer.Ordinal)
                                        .ThenBy(x => x.Fn.Name, StringComparer.Ordinal))
        {
            sb.AppendLine($"| `{module}` | `{fn.Name}` | {fn.Summary} |");
        }
        return sb.ToString();
    }
}
```

- [ ] **Step 4: `Program.cs` に足し、生成する**

```csharp
outputs.Add((Path.Combine(repoRoot, "docs", "api-map.md"), ApiMapEmitter.Emit(specs)));
```

Run: `pwsh tools/dev.ps1 generate`

- [ ] **Step 5: `docs/README.md` の一覧に足す**

```markdown
- [API 対応表](./api-map.md)（**生成物**。`bindings/spec/*.json` が正本。
  ここに無い関数は「まだ無い」のであって、隠れているのではない）
```

- [ ] **Step 6: 通ることを見る**

Run: `pwsh tools/dev.ps1 test`
Expected: PASS。**`ci-lint` の文書リンク検査も通ること**（`docs/api-map.md` が実在する）。

- [ ] **Step 7: 壊して落ちることを見る**

**壊す前にコミットする。** `docs/api-map.md` の行を 1 つ手で消す →
`BindingGenerator.Tests.ps1` の `the generated bindings match the spec` が FAIL。
戻して緑を確認する。

- [ ] **Step 8: コミット**

```bash
git add bindings/generator docs/api-map.md docs/README.md
git commit -m "feat(m5): API 対応表を spec から生成する"
```

---

## Task 8: 文書の更新と判定

**Files:**
- Modify: `.claude/skills/add-abi-function/SKILL.md`
- Modify: `CLAUDE.md`
- Modify: `docs/roadmap.md`
- Modify: `docs/abi-ownership-and-versioning.md`
- Modify: `docs/api-reference.md`

- [ ] **Step 1: `add-abi-function` skill を書き換える**

**この skill の手順は「ヘッダに手で書く」前提である。** M5 の後は
**spec に 1 エントリ書いて `dev.ps1 generate`** になる。**古い手順を残すと、
次のエージェントが手書きの宣言を足して `verify-generated` で落ちる。**

「## 手順」の直前に足す:

```markdown
## M5 以降: 宣言は手で書かない

`bindings/spec/<module>.json` に 1 エントリ足して `./tools/dev.ps1 generate` を
実行する。**C ヘッダ・C# の P/Invoke・到達性テスト・API 対応表が同時に出る。**
**手で書いた宣言は `verify-generated` が落とす**（`dev.ps1 test` に入っている）。

手で書くのは**実装（`native/src/*.cpp`）と、意味のあるテスト（L1 / L3）だけ**である。
下の手順のうち「ヘッダに宣言する」「C# 側の P/Invoke を足す」の 2 つは、
**spec を書くことに置き換わる。** 残りはそのまま有効である。

**`wrapInTryBarrier` を spec に正しく書くこと。** 囲ってはならない関数の一覧は
`native/src/ocvu_error.h` にある —— `ocvu_get_last_error_*` は囲うと
報告すべきエラーを自分で消す。
```

- [ ] **Step 2: `CLAUDE.md` を直す**

- 開発コマンドの表に `generate` と `verify-generated` を足す
- ファイル配置の表に `bindings/spec/`、`bindings/generator/`、
  `native/include/ocvu/`、`docs/api-map.md` を足す
- **「`bindings/`（M5 予定）だけがまだ無い」を消す** —— 在る
- 「リポジトリの現状」に M5 の段落を足す
- 現在地を M5 に進める
- **skill の表の `add-abi-function` の行に「M5 以降は spec を書く」と足す**

- [ ] **Step 3: `docs/abi-ownership-and-versioning.md` §2 に留保を書く**

roadmap の M7 決定 1 がこう指示している:

> **`OCVU_ABI_VERSION` は単一の整数のまま**である（正本は §2 の「決定」。
> ここで再オープンしない）。module 分離がこの決定に影響しうるなら、
> **正本のほうに留保を書く**

§2 に足す:

```markdown
**M5 で C ABI を module ごとのヘッダに割ったが、`OCVU_ABI_VERSION` は
単一の整数のままである。** module ごとに版を持たせていない —— 配るのは
1 つの binary で、**「部分的に古い module」というものが存在しない**からである。
`dnn` を別 target・別 binary にした場合はこの前提が崩れうるので、
**そのとき再検討する**（M7 の決定 1）。
```

- [ ] **Step 4: `docs/api-reference.md` と生成物の関係を書く**

冒頭に足す:

```markdown
**この文書は手書きである。** 機械的な一覧は [API 対応表](./api-map.md)（生成物）にある。
こちらが持つのは**契約と落とし穴**（所有権、stride、2 回呼びの作法、
`WebCamTextureConverter` の上下反転など）で、**関数の一覧ではない。**
```

- [ ] **Step 5: `docs/roadmap.md` に M5 の判定表を書く**

```markdown
**5 件中 4 件を満たし、1 件は次の計画に送る。**

| # | 完了条件 | 判定 |
| --- | --- | --- |
| 1 | spec を正本として生成物が作られ、golden test で一致が検証される | **満たす**。`bindings/spec/*.json` → `dev.ps1 generate`。`verify-generated` が `dev.ps1 test` に入っており、**生成物を手で変えると落ちる**（実測） |
| 2 | `geometry` / `calib` / `features` / `objdetect` を利用例に基づいて追加 | **閉じていない。** 別の subsystem なのでこの計画から外した（理由は計画の冒頭）。次の計画で閉じる |
| 3 | M3.5 で手書きした関数を spec の側へ寄せる | **満たす**。`imgcodecs` の 2 本を含む 20 本すべてが spec から出ている |
| 4 | API 対応表を生成し、「OpenCV 全対応」という曖昧な表現を使わない | **満たす**。`docs/api-map.md` |
| 5 | 生成された P/Invoke が IL2CPP stripping を生き延びることを L5 で確認 | **満たす**。`AbiReachabilityChecks.g.cs` が全 entry point を呼び、Player レーンが実行する。**壊すと `EntryPointNotFoundException` で落ちる**（実測） |
```

**部分的な達成を完了と呼ばない。**

- [ ] **Step 6: 全レーンを回して数を確かめる**

```
pwsh tools/dev.ps1 test
pwsh tools/dev.ps1 test-asan
pwsh tools/dev.ps1 test-unity-editmode
pwsh tools/dev.ps1 test-unity-player
pwsh tools/dev.ps1 test-tools-slow
```

**`CLAUDE.md` に書いた件数と実測が一致すること。** 数はリポジトリ中に
散らばっていて一斉に古くなる（`milestone-complete` skill）。
`git grep -c` で数え直すこと。

- [ ] **Step 7: AI レビューを受ける**

**書いていない別のエージェント**にブランチ全体の差分を見せる。
**何を指摘してほしくないかを事前に伝えない。**

- [ ] **Step 8: コミットして PR**

```bash
git add CLAUDE.md docs .claude/skills/add-abi-function/SKILL.md
git commit -m "docs(m5): 生成に切り替えたことを文書に反映する"
```

PR 本文には**実測値**と、**条件 2 を次の計画に送った理由**を書く。**穴があるなら隠さず書く。**

---

## この計画の後に残るもの

- **完了条件 2**（新しい module の追加）は次の計画。
  `geometry` / `calib` / `features` / `objdetect` を足すと
  `COMPONENTS` / `Modules` / `THIRD_PARTY_NOTICES.md` / 成果物の大きさ /
  依存 allowlist が動く（**M3.5 の `imgcodecs` で実際に全部動いた**）
- **M7 の決定 1 の残り** —— C# を別 assembly に割ること（決定 1 の 2）と、
  OpenCV の版を跨げるようにすること（同 3）。**この計画は C ABI のヘッダだけを割った。**
  `Runtime/Interop` は 1 つの assembly のままである
- **実装（`.cpp`）は生成しない。** spec は境界の**形**を持つが、中で何をするかは持たない。
  生成する価値が出るのは、「`Mat` を 2 つ取って 1 つ返す」ような
  **型どおりの薄い関数が増えたとき**である。いまの 20 本はどれも
  引数の検証や 2 回呼びの作法を持っており、**生成しても薄くならない**


---

## 実施の結果（2026-09-01）

**8 タスクすべてを Subagent-Driven Development で実行した。** タスクごとに、その
差分を書いていないエージェントがレビューし、修正のたびにスコープを絞って再レビュー
した。最後にブランチ全体を、1 行も書いていないエージェントが読んだ。

| | |
| --- | --- |
| コミット | **30**（PR #55 を出した時点。`gh pr view 55 --json commits` で実測。この文書更新はその後に足した） |
| レビュー | タスクごとに 1 回 + ブランチ全体で 1 回。**修正は 7 波** |
| Critical | **0 件** |
| Important | **11 件**（すべて修正）。**うち 1 件はこの節自身へのレビューで出た** —— ここに書いた数が 2 つとも誤っていた（コミット数と、この行の件数）|
| CI | **必須 21 本すべて緑**（PR #55） |

### この計画には 12 個のバグがあった

**計画を書いたのは、実行を指揮したのと同じエージェントである。** それでもこれだけ
出た。**内訳を残すのは、次に計画を書くときの材料にするためである:**

| 種別 | 件数 | 見つけた者 |
| --- | --- | --- |
| **Files 一覧の漏れ** | **5** | 着手前の走査 3、実装者 2 |
| 実物と食い違う呼び出し例（`Invoke-Checked` の引数順） | 1 | 実装者 |
| 実物と食い違うパス導出（`$PSCommandPath` は `tools/` を指す） | 1 | 実装者 |
| **「こうすると壊れる」が実際には壊れない** | 1 | 実装者 |
| 実物と食い違う件数（「L1 44 件」は 64 / 4） | 1 | 実装者 |
| 完了条件の根拠が検査の片側にしか触れていない | 1 | 実装者 |
| レーン一覧が指示と食い違う | 1 | 実装者 |
| controller が用意した「直す数字の在り処」の漏れ | **7 箇所** | 実装者 |

**最も多いのは Files 一覧の漏れである。** 計画は「このタスクが触るファイル」を
書くが、**実際に触らないと済まないファイルはそれより多い** —— C# の partial 化、
`InternalsVisibleTo`、emitter の変更、コメントの訂正。**着手前に全タスクを
走査して 3 件見つけたが、それでも 2 件は実装中に出た。**

**「こうすると壊れる」が壊れなかった 1 件は性質が違う。** 計画は「`_ptr` を 2 度
宣言すると重複定義になる」と書いたが、**C は同一シグネチャの再宣言を許すので
ビルドは緑のまま通る**（実測）。**コンパイラが番人になると仮定して書いた検査は、
その仮定を確かめるまで動くと言えない。**

### レビューが見つけた最も重いもの

**門の作り方を 4 度間違えた。** うち 3 件は「列挙に基づく門は、必ず著者が
思いついた範囲で止まる」形で、1 件（3 番目）は列挙そのものは正しかった:

1. **生成物 10 個のうち、名指しで守られていたのは 2 個だけだった。** 到達性テストの
   配線を外しても検査は全部 PASS した ——「生成器が申告する出力から導く」形に変えた
2. **禁止文字の集合が「思いついた範囲」だった。** `docs/api-map.md` については
   **出口で構造を見る**門（各行がちょうど 5 列）を足して、文字に依存しなくした
3. **`.NET` の `$` は末尾の `
` の直前にも一致する。** 列挙した文字は正しかったが、
   **アンカーの意味を確かめていなかった** —— 「一致したか」ではなく
   **「値全体を覆ったか」**を見る形に変えた
4. **手で持つ数字が古くなる。** これは**4 度開き直った**（閉じ、**12 箇所**開き、
   3 箇所見つかり、5 箇所残る）。**閉じ方は毎回「見つけて直す」で、機構は無い**

**ただし配分がある。** 出口の構造検査を足す価値があったのは `docs/api-map.md` だけ
だった —— **C ヘッダの構造検査は既にコンパイラが持っている**（`*/` を入れると
`C2143` で落ちるのを実測）。**下流に検査が 1 つも無いところにだけ足すのが最適である。**

### 前提が 1 つ覆った

「Shim は `TreatWarningsAsErrors=true` なので `<` や `&` でビルドが落ちる」は
**誤りだった** —— `GenerateDocumentationFile` がどの csproj にも無いので
**compiler は doc comment を構文解析しない**。**この誤りは 3 者が 4 タスクに
わたって持ち回り、誰も試していなかった。** 実測で確定させ、禁止は維持したまま
説明のほうを直した（`*/` は落ちるので気づくが、`<>&` は**壊れたまま緑になる**側）。

### 「手前に別の門があると番人に到達しない」を 4 度踏んだ

`prove-a-check-works` skill が既に持っていた節だが、**それでも 4 度踏んだ**。
4 度目でようやく**事前に**気づいた（自分の門が既存テスト 6 件の手前に立ち、
その 6 件が「通っているが何も見ていない」状態へ移りかけた）。

**壊し方を間違えた例も 2 度あった** —— 生の改行を JSON に入れたら
`System.Text.Json` が先に落とし、門そのものを外したら「照合の有無に関係なく
落ちる」ので直した価値を何も示さなかった。**壊し方の設計自体が検査の一部である。**
