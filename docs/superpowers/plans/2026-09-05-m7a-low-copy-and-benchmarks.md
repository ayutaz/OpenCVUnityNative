# M7 (a) — 低コピー経路と benchmark の実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unity のテクスチャと `CvMat` の間の低コピー経路を実測で評価し、割り当て・package size を機械が守る形で assert し、時間は公開だけする benchmark レーンを作る。

**Architecture:** 測定は 2 層に分ける。**決定的な量（割り当てバイト数）は L3（素の .NET）で `GC.GetAllocatedBytesForCurrentThread()` を使って assert し、CI が落とす。** Unity 側（Texture2D / RenderTexture）は正しさを assert し、時間は機械可読な 1 行として吐いて `tools/` のスクリプトが読んで**公開する**。native texture pointer は D4 の決定に従い、実装せず評価だけを記録する。

**Tech Stack:** xUnit（net8.0）/ Unity Test Framework（EditMode + PlayMode）/ PowerShell 7 / `AsyncGPUReadback`（`UnityEngine.Rendering`）

**Spec:** [`2026-09-05-m7-profiles-and-performance.md`](./2026-09-05-m7-profiles-and-performance.md)

## Global Constraints

**spec の §3 を逐語で引く。全タスクの要件に暗黙に含まれる。**

- **`Runtime/Interop` と `Runtime/Core` は `UnityEngine` を参照してはならない。** UnityEngine 依存コードは `Runtime/UnityIntegration/`（別 asmdef）にのみ置く。`tests/Managed/CvUnity.Runtime.Shim/`（netstandard2.1）がビルドで機械的に強制する
- **`ocvu_mat_handle` は常に native が所有する。Unity 所有のメモリを指す handle を返さない。** 借用は 1 回の ABI 呼び出しの内側で完結する
- **境界の宣言を手で書かない。** `bindings/spec/*.json` が正本。**この計画は公開 ABI を 1 本も増やさないので、`bindings/` は 1 バイトも変わらない**
- **すべての実装を TDD で行う。** 失敗するテストを先に書き、赤いことを確かめてから実装する
- **`dev.ps1` のレーンは相互排他である。2 つ同時に走らせないこと**
- **OpenCV をローカルでビルドしない**（`block-local-opencv-build.sh` が拒否する）
- **`git add -A` / `git add .` は hook が拒否する。** ファイルを名指しで stage する
- **非 ASCII を出力する PowerShell スクリプトは、必ず先頭に** `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()` **を置く**
- **検査を足したり変えたりしたら、壊して落ちることを見る**（`prove-a-check-works` skill）
- **数を写さない。** 対象 platform の正本は `tools/dev.ps1` の `$script:AllPlatformBinaries`
- **時間を assert しない**（spec の D1）。決定的な量だけを assert し、時間は公開する

---

## File Structure

**この計画が触るファイルと、それぞれの責任。**

| ファイル | 新規/変更 | 責任 |
| --- | --- | --- |
| `tests/Managed/CvUnity.Tests.Managed/AllocationTests.cs` | 新規 | **境界の割り当てを assert する（L3）。** ポインタ経路が 0 バイトであること、`byte[]` 経路がそれ以上であること（測定器の負の対照） |
| `tests/Managed/CvUnity.Tests.Managed/AllocationProbe.cs` | 新規 | 割り当て測定の道具。JIT を温めてから測る |
| `Packages/com.ayutaz.opencv-unity-native/Runtime/UnityIntegration/RenderTextureConverter.cs` | 新規 | **RenderTexture → CvMat**。同期（`ReadPixels`）と非同期（`AsyncGPUReadback`）の 2 経路 |
| `tests/UnityProject/Assets/Tests/Shared/RenderTextureChecks.cs` | 新規 | 上の正しさを EditMode / PlayMode / Web が共有して検証する本体 |
| `tests/UnityProject/Assets/Tests/EditMode/RenderTextureTests.cs` | 新規 | EditMode の入口（手書き配線 + 配線の突き合わせ） |
| `tests/UnityProject/Assets/Tests/PlayMode/RenderTexturePlayerTests.cs` | 新規 | PlayMode の入口（同上）。**非同期の完了待ちは `[UnityTest]` でしかできない** |
| `tests/UnityProject/Assets/Tests/PlayMode/BenchmarkRunner.cs` | 新規 | 時間を測って機械可読な 1 行を吐く。**assert しない** |
| `tools/run-benchmarks.ps1` | 新規 | Player を建てて走らせ、吐かれた行を集めて `artifacts/benchmarks/` へ書く |
| `tools/measure-package-size.ps1` | 新規 | 配布物の大きさを測り、**上限を超えたら落とす** |
| `tools/dev.ps1` | 変更 | `benchmark` サブコマンドを足す |
| `docs/performance.md` | 新規 | **測った数字と、測っていないことを公開する** |
| `.github/workflows/ci-native.yml` | 変更 | `measure-package-size.ps1` を配線する |
| `docs/api-reference.md` | 変更 | `RenderTextureConverter` を足す |

---

## Task 1: 割り当てを測る道具と、その負の対照（L3）

**Files:**
- Create: `tests/Managed/CvUnity.Tests.Managed/AllocationProbe.cs`
- Create: `tests/Managed/CvUnity.Tests.Managed/AllocationTests.cs`

**Interfaces:**
- Consumes: `CvMat.Create(int, int, CvMatType)`、`CvMat.CopyFrom(byte[], long)`、`CvMat.CopyFrom(IntPtr, long, long)`（すべて既存）
- Produces: `AllocationProbe.Measure(Action)` → `long`（その Action が現在のスレッドで割り当てたバイト数）

- [ ] **Step 1: 失敗するテストを書く**

`tests/Managed/CvUnity.Tests.Managed/AllocationProbe.cs` を作る:

```csharp
using System;

/// <summary>
/// ある処理が現在のスレッドで割り当てたバイト数を測る。
///
/// **GC.GetAllocatedBytesForCurrentThread() は正確である**（2026-09-05 に
/// .NET 8 で実測: new byte[4096] で delta=4120、無割り当てで delta=0）。
/// GC.GetTotalMemory と違い、回収の影響を受けず、他スレッドの割り当ても混ざらない。
///
/// **先に 1 度空回しするのは、JIT とその場限りの初期化を測らないためである。**
/// 初回だけ型の初期化子や delegate の割り当てが乗るので、それを本番の数字に
/// 含めると「0 バイト」が達成できず、閾値を緩めるしかなくなる。
/// </summary>
internal static class AllocationProbe
{
    internal static long Measure(Action action)
    {
        if (action == null) { throw new ArgumentNullException(nameof(action)); }

        // 空回し。JIT と初期化をここで済ませる。
        action();

        long before = GC.GetAllocatedBytesForCurrentThread();
        action();
        long after = GC.GetAllocatedBytesForCurrentThread();
        return after - before;
    }
}
```

`tests/Managed/CvUnity.Tests.Managed/AllocationTests.cs` を作る:

```csharp
using System;
using System.Runtime.InteropServices;
using CvUnity;
using Xunit;

/// <summary>
/// 境界を越えるときの割り当てを assert する。
///
/// **時間は測らない**（設計 D1）—— 共有 CI ランナーの上で時間を assert すると
/// 必ずフレークになり、閾値を緩めればその検査は何も見ていない。
/// **割り当ては決定的なので assert できる。**
///
/// **測定器そのものが壊れたときに落ちる形にしてある**（設計 D2）——
/// 「0 バイトだった」は、測れていないときにも出る。だから
/// **byte[] 経路が割り当てることも同時に要求する。**
/// </summary>
public class AllocationTests
{
    private const int Rows = 64;
    private const int Cols = 64;
    private const int Channels = 4;
    private const int ByteCount = Rows * Cols * Channels;

    [Fact]
    public void PointerCopyFromAllocatesNothing()
    {
        var source = new byte[ByteCount];
        var handle = GCHandle.Alloc(source, GCHandleType.Pinned);
        try
        {
            IntPtr ptr = handle.AddrOfPinnedObject();
            using var mat = CvMat.Create(Rows, Cols, CvMatType.Bgra32);

            long allocated = AllocationProbe.Measure(
                () => mat.CopyFrom(ptr, ByteCount, Cols * Channels));

            Assert.Equal(0, allocated);
        }
        finally { handle.Free(); }
    }

    [Fact]
    public void PointerCopyToAllocatesNothing()
    {
        var destination = new byte[ByteCount];
        var handle = GCHandle.Alloc(destination, GCHandleType.Pinned);
        try
        {
            IntPtr ptr = handle.AddrOfPinnedObject();
            using var mat = CvMat.Create(Rows, Cols, CvMatType.Bgra32);

            long allocated = AllocationProbe.Measure(
                () => mat.CopyTo(ptr, ByteCount, Cols * Channels));

            Assert.Equal(0, allocated);
        }
        finally { handle.Free(); }
    }

    /// <summary>
    /// **これは測定器の負の対照である。**
    ///
    /// 上の 2 件が「0 バイト」で通るのは、(1) 本当に割り当てていないか、
    /// (2) 測定器が壊れて常に 0 を返すか、のどちらかである。
    /// **この 1 件が割り当てを検出することで、(2) を排除する。**
    ///
    /// 落ちるのは 2 つの場合で、**どちらも知りたいことである**:
    /// 測定器が死んだか、byte[] 経路が消えたか。
    /// </summary>
    [Fact]
    public void ByteArrayCopyFromAllocatesTheBuffer()
    {
        using var mat = CvMat.Create(Rows, Cols, CvMatType.Bgra32);

        long allocated = AllocationProbe.Measure(
            () =>
            {
                var buffer = new byte[ByteCount];
                mat.CopyFrom(buffer, Cols * Channels);
            });

        // 配列そのもの（ByteCount）に加えてオブジェクトヘッダが乗る。
        // 下限だけを見る —— 上限を書くと実装の詳細に縛られる。
        Assert.True(
            allocated >= ByteCount,
            $"byte[] 経路が {ByteCount} バイト以上を割り当てるはずが {allocated} だった。" +
            "測定器が壊れているか、この経路が消えている");
    }

    /// <summary>
    /// **測定器が「何も測っていない」状態を直接排除する。**
    ///
    /// 上の 3 件は CvMat を通るので、境界の側の変更でも落ちうる。
    /// この 1 件は CvMat に触れず、**AllocationProbe だけを見る。**
    /// </summary>
    [Fact]
    public void TheProbeItselfSeesAnAllocation()
    {
        long allocated = AllocationProbe.Measure(() => { var _ = new byte[4096]; });
        Assert.True(allocated >= 4096, $"probe が 4096 バイトを見落とした（{allocated}）");

        long nothing = AllocationProbe.Measure(() => { });
        Assert.Equal(0, nothing);
    }
}
```

- [ ] **Step 2: テストが失敗することを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-managed
```

期待: `AllocationProbe` が未定義なのでコンパイルエラー。**まだ実装を書いていないので、赤いのはビルドである。**

> **注**: Step 1 で `AllocationProbe.cs` と `AllocationTests.cs` を同時に作るとビルドが通ってしまう。
> **`AllocationTests.cs` だけを先に作って赤を見てから `AllocationProbe.cs` を足すこと。**

- [ ] **Step 3: `AllocationProbe.cs` を足す**

Step 1 に全文がある。

- [ ] **Step 4: テストが通ることを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-managed
```

期待: 4 件とも PASS。`CvUnity.Tests.Managed` の合計が 181 → **185** になる。

- [ ] **Step 5: 負の対照を取る（`prove-a-check-works`）**

**先にコミットしてから壊す。**

```bash
git add tests/Managed/CvUnity.Tests.Managed/AllocationProbe.cs tests/Managed/CvUnity.Tests.Managed/AllocationTests.cs
git commit -m "test(m7a): 境界の割り当てを L3 で assert する"
```

壊し方 1 —— **測定器を殺す**。`AllocationProbe.Measure` の戻りを `return 0;` にする:

```
pwsh -NoProfile -File tools/dev.ps1 test-managed
```

期待: `ByteArrayCopyFromAllocatesTheBuffer` と `TheProbeItselfSeesAnAllocation` が
**FAIL**（`PointerCopyFrom/To` は 0 を期待しているので通ってしまう ——
**これがまさに負の対照が要る理由である**）。

壊し方 2 —— **ポインタ経路に割り当てを注入する**。`CvMat.CopyFrom(IntPtr, long, long)` の
先頭に `var _ = new byte[64];` を足す:

```
pwsh -NoProfile -File tools/dev.ps1 test-managed
```

期待: `PointerCopyFromAllocatesNothing` が **FAIL**。

**両方を戻して緑に戻すこと。** 結果を PR 本文に書く。

- [ ] **Step 6: コミット**

```bash
git add tests/Managed/CvUnity.Tests.Managed/AllocationTests.cs
git commit -m "test(m7a): 割り当て検査の負の対照を 2 通り取った

測定器を殺すと byte[] 側と probe 自身の 2 件が落ち、ポインタ経路に
割り当てを注入すると該当 1 件が落ちる。**測定器を殺しただけでは
ポインタ側の 2 件は緑のまま**で、これが負の対照を置いた理由そのものである。"
```

---

## Task 2: RenderTexture → CvMat の同期経路

**Files:**
- Create: `Packages/com.ayutaz.opencv-unity-native/Runtime/UnityIntegration/RenderTextureConverter.cs`
- Create: `tests/UnityProject/Assets/Tests/Shared/RenderTextureChecks.cs`
- Create: `tests/UnityProject/Assets/Tests/EditMode/RenderTextureTests.cs`

**Interfaces:**
- Consumes: `CvMat.Create(int, int, CvMatType)`、`NativeArrayExtensions.CopyFrom<T>(this CvMat, NativeArray<T>, long)`（既存）、`TextureConverter.ToMat(Texture2D)`（既存）
- Produces:
  - `RenderTextureConverter.ToMat(RenderTexture source)` → `CvMat`（同期。`ReadPixels` 経由）
  - `RenderTextureChecks.SyncReadbackProducesTheExpectedPixels()` → `void`

**なぜ同期経路を先に作るか**: 非同期の結果を比べる相手が要る。
**「非同期が正しい」は「同期と同じ画素が出る」としてしか確かめられない。**

- [ ] **Step 1: 失敗する検証本体を書く**

`tests/UnityProject/Assets/Tests/Shared/RenderTextureChecks.cs`:

```csharp
using CvUnity;
using CvUnity.Unity;
using UnityEngine;

namespace CvUnity.Tests.Shared
{
    /// <summary>
    /// RenderTexture から CvMat を作る経路を、Unity の中で検証する。
    ///
    /// **本体はここにしか無い。** EditMode / PlayMode が写しを持つと、
    /// 片方だけ直って「Editor と Player で同じ結果」を確かめられなくなる。
    ///
    /// **件数はここに書かない** —— 数えるのは各入口の
    /// EveryCheckInTheSharedBodyIsWiredIntoThisEntryPoint である。
    /// </summary>
    public static class RenderTextureChecks
    {
        internal const int Size = 8;

        /// <summary>
        /// 既知の色で塗った RenderTexture が、そのままの画素で Mat になること。
        ///
        /// **Unity は左下原点、OpenCV は左上原点である。** ReadPixels は
        /// Unity の向きで読むので、上下が反転する。ここでは
        /// **単色で塗って向きに依存しない形**にしてある —— 向きそのものは
        /// 下の VerticalFlipIsApplied が縞模様で見る。
        /// </summary>
        public static void SyncReadbackProducesTheExpectedPixels()
        {
            var rt = MakeSolid(new Color32(10, 20, 30, 255));
            try
            {
                using var mat = RenderTextureConverter.ToMat(rt);

                Check.AreEqual(Size, mat.Rows);
                Check.AreEqual(Size, mat.Cols);
                Check.AreEqual(4, mat.Channels, "RGBA32 は 4 channel であること");

                var got = new byte[Size * Size * 4];
                mat.CopyTo(got, Size * 4);

                // **全画素を見る。** 先頭 1 画素だけを見ると、
                // 「1 行だけ書いて残りは 0」でも通ってしまう。
                for (int i = 0; i < Size * Size; i++)
                {
                    Check.AreEqual((byte)10, got[i * 4 + 0], $"画素 {i} の R");
                    Check.AreEqual((byte)20, got[i * 4 + 1], $"画素 {i} の G");
                    Check.AreEqual((byte)30, got[i * 4 + 2], $"画素 {i} の B");
                    Check.AreEqual((byte)255, got[i * 4 + 3], $"画素 {i} の A");
                }
            }
            finally { Release(rt); }
        }

        /// <summary>
        /// **上下反転が実際に掛かっていること。**
        ///
        /// Unity は左下原点、OpenCV は左上原点なので、変換は上下を返す。
        /// 単色では確かめられないので、**上半分と下半分で色を変えて**見る。
        /// WebCamTextureConverter が既定で反転するのと同じ規約である。
        /// </summary>
        public static void VerticalFlipIsApplied()
        {
            var rt = MakeHalves(new Color32(200, 0, 0, 255), new Color32(0, 0, 200, 255));
            try
            {
                using var mat = RenderTextureConverter.ToMat(rt);
                var got = new byte[Size * Size * 4];
                mat.CopyTo(got, Size * 4);

                // Unity では「上半分が赤」。OpenCV の行 0 は画像の上端なので、
                // 反転が掛かっていれば行 0 は赤である。
                Check.AreEqual((byte)200, got[0 * Size * 4 + 0], "Mat の行 0 は赤であること");
                int last = (Size - 1) * Size * 4;
                Check.AreEqual((byte)200, got[last + 2], "Mat の最終行は青であること");
            }
            finally { Release(rt); }
        }

        internal static RenderTexture MakeSolid(Color32 color)
        {
            var rt = new RenderTexture(Size, Size, 0, RenderTextureFormat.ARGB32)
            {
                enableRandomWrite = false,
            };
            rt.Create();

            var prev = RenderTexture.active;
            RenderTexture.active = rt;
            GL.Clear(true, true, color);
            RenderTexture.active = prev;
            return rt;
        }

        internal static RenderTexture MakeHalves(Color32 top, Color32 bottom)
        {
            // GL.Clear では 2 色に塗れないので、Texture2D を作って Blit する。
            var src = new Texture2D(Size, Size, TextureFormat.RGBA32, mipChain: false);
            var pixels = new Color32[Size * Size];
            for (int y = 0; y < Size; y++)
            {
                // Texture2D の y=0 は**下端**である（Unity の規約）。
                var c = y < Size / 2 ? bottom : top;
                for (int x = 0; x < Size; x++) { pixels[y * Size + x] = c; }
            }
            src.SetPixels32(pixels);
            src.Apply();

            var rt = new RenderTexture(Size, Size, 0, RenderTextureFormat.ARGB32);
            rt.Create();
            Graphics.Blit(src, rt);
            Object.DestroyImmediate(src);
            return rt;
        }

        internal static void Release(RenderTexture rt)
        {
            if (rt == null) { return; }
            rt.Release();
            Object.DestroyImmediate(rt);
        }
    }
}
```

`tests/UnityProject/Assets/Tests/EditMode/RenderTextureTests.cs`:

```csharp
using System.Linq;
using System.Reflection;
using CvUnity.Tests.Shared;
using NUnit.Framework;

public class RenderTextureTests
{
    [Test] public void SyncReadbackProducesTheExpectedPixels()
        => RenderTextureChecks.SyncReadbackProducesTheExpectedPixels();

    [Test] public void VerticalFlipIsApplied()
        => RenderTextureChecks.VerticalFlipIsApplied();

    /// <summary>
    /// **共有本体に在るのに、この入口に配線されていない検査を名指しで落とす。**
    ///
    /// 手書きの配線は書き忘れる。書き忘れても assembly はレーンに在るので、
    /// 「どのレーンからも走らないテスト」を探す grep には掛からない
    /// （prove-a-check-works skill の §5）。
    /// </summary>
    [Test]
    public void EveryCheckInTheSharedBodyIsWiredIntoThisEntryPoint()
    {
        var shared = typeof(RenderTextureChecks)
            .GetMethods(BindingFlags.Public | BindingFlags.Static)
            .Where(m => m.ReturnType == typeof(void) && m.GetParameters().Length == 0)
            .Select(m => m.Name).ToList();
        Assert.Greater(shared.Count, 1, "共有本体の検査が拾えていない");

        var wired = typeof(RenderTextureTests)
            .GetMethods(BindingFlags.Public | BindingFlags.Instance)
            .Select(m => m.Name).ToList();

        var missing = shared.Where(n => !wired.Contains(n)).ToList();
        Assert.IsEmpty(missing,
            "共有本体に在るのに、この入口に配線されていない検査: " + string.Join(", ", missing));
    }
}
```

- [ ] **Step 2: 失敗することを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-unity-editmode
```

期待: `RenderTextureConverter` が未定義でコンパイルエラー。

- [ ] **Step 3: `RenderTextureConverter` を実装する**

`Packages/com.ayutaz.opencv-unity-native/Runtime/UnityIntegration/RenderTextureConverter.cs`:

```csharp
using System;
using Unity.Collections;
using Unity.Collections.LowLevel.Unsafe;
using UnityEngine;

namespace CvUnity.Unity
{
    /// <summary>RenderTexture から CvMat を作る。</summary>
    /// <remarks>
    /// <para>
    /// <b>RenderTexture には GetRawTextureData が無い。</b> 中身は GPU 側に
    /// あり、CPU から読むには GPU → CPU の転送が要る。ここが Texture2D との
    /// 決定的な違いである（Texture2D は CPU 側にも実体を持ちうる）。
    /// </para>
    /// <para>
    /// <b>この同期経路は GPU を待たせる。</b> <c>ReadPixels</c> は転送が済むまで
    /// 戻らないので、毎フレーム呼ぶとフレーム時間に直接乗る。毎フレームの用途では
    /// <see cref="ToMatAsync"/> を使うこと。
    /// </para>
    /// <para>
    /// <b>上下を反転する。</b> Unity は左下原点、OpenCV は左上原点である。
    /// <c>WebCamTextureConverter</c> と同じ規約に揃えてある。
    /// </para>
    /// </remarks>
    public static class RenderTextureConverter
    {
        /// <summary>
        /// RenderTexture の内容を新しい CvMat（Bgra32）に写す。
        /// GPU の転送が済むまで戻らない。
        /// </summary>
        /// <exception cref="ArgumentNullException"><paramref name="source"/> が null。</exception>
        /// <exception cref="NotSupportedException">読み出せる形式でない。</exception>
        public static unsafe CvMat ToMat(RenderTexture source)
        {
            if (source == null) { throw new ArgumentNullException(nameof(source)); }

            var prev = RenderTexture.active;
            var staging = new Texture2D(
                source.width, source.height, TextureFormat.RGBA32, mipChain: false);
            try
            {
                RenderTexture.active = source;
                staging.ReadPixels(new Rect(0, 0, source.width, source.height), 0, 0);
                staging.Apply(updateMipmaps: false);

                // ここから先は Texture2D の経路と同じ。**写しを増やさない** ——
                // GetRawTextureData が返す NativeArray のポインタをそのまま渡す。
                var raw = staging.GetRawTextureData<byte>();
                var mat = CvMat.Create(source.height, source.width, CvMatType.Bgra32);
                try
                {
                    FillFlipped(mat, raw, source.width, source.height);
                    return mat;
                }
                catch { mat.Dispose(); throw; }
            }
            finally
            {
                RenderTexture.active = prev;
                UnityEngine.Object.DestroyImmediate(staging);
            }
        }

        /// <summary>
        /// NativeArray の内容を上下反転して Mat に書く。
        /// </summary>
        /// <remarks>
        /// <b>行ごとに渡す。</b> 一括で渡して native 側で反転させる案は採らない ——
        /// それは新しい ABI 関数を要求し、この計画は公開 ABI を 1 本も増やさない。
        /// </remarks>
        internal static unsafe void FillFlipped(
            CvMat mat, NativeArray<byte> raw, int width, int height)
        {
            long rowBytes = (long)width * 4;
            var basePtr = (byte*)NativeArrayUnsafeUtility.GetUnsafeReadOnlyPtr(raw);

            var row = new byte[rowBytes];
            fixed (byte* rowPtr = row)
            {
                for (int y = 0; y < height; y++)
                {
                    // Unity の y 行目は、OpenCV では (height - 1 - y) 行目。
                    Buffer.MemoryCopy(
                        basePtr + (long)y * rowBytes, rowPtr, rowBytes, rowBytes);
                    mat.CopyRowFrom((IntPtr)rowPtr, height - 1 - y, rowBytes);
                }
            }
        }
    }
}
```

> **`CvMat.CopyRowFrom` は存在しない。** Step 3 の実装はこのままではコンパイルできない。
> **Step 3a でそれを解決する。**

- [ ] **Step 3a: 1 行だけ書く経路を、既存の ABI の上に作る**

**新しい ABI 関数を足さない。** `CvMat.CopyFrom(IntPtr, long, long)` は
Mat 全体を対象にするので、行単位では使えない。代わりに
**反転済みの buffer を 1 つ組んでから 1 回で渡す**。`FillFlipped` を差し替える:

```csharp
        internal static unsafe void FillFlipped(
            CvMat mat, NativeArray<byte> raw, int width, int height)
        {
            long rowBytes = (long)width * 4;
            long total = rowBytes * height;
            var basePtr = (byte*)NativeArrayUnsafeUtility.GetUnsafeReadOnlyPtr(raw);

            // **反転した写しを 1 つ作る。**
            //
            // ここで 1 回コピーが増えることは、benchmark で公開する数字に
            // そのまま出る。避けるには「native 側で反転する ABI 関数」を足すか、
            // 「反転しない」ことを選ぶかで、**どちらもこの計画の範囲外である**
            // （前者は公開 ABI を増やす、後者は WebCamTextureConverter と規約が割れる）。
            var flipped = new NativeArray<byte>(
                (int)total, Allocator.Temp, NativeArrayOptions.UninitializedMemory);
            try
            {
                var dst = (byte*)NativeArrayUnsafeUtility.GetUnsafePtr(flipped);
                for (int y = 0; y < height; y++)
                {
                    Buffer.MemoryCopy(
                        basePtr + (long)y * rowBytes,
                        dst + (long)(height - 1 - y) * rowBytes,
                        rowBytes, rowBytes);
                }
                mat.CopyFrom((IntPtr)dst, total, rowBytes);
            }
            finally { flipped.Dispose(); }
        }
```

**`Allocator.Temp` は GC を経由しない** —— `AllocationProbe` が測る managed の
割り当てには乗らない。**これは benchmark で「コピー 1 回ぶんの時間」としてだけ現れる。**

- [ ] **Step 4: テストが通ることを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-unity-editmode
```

期待: `RenderTextureTests` の 3 件が PASS。EditMode の合計が 48 → **51** になる。

- [ ] **Step 5: 負の対照を取る**

**先にコミットしてから壊す。**

```bash
git add Packages/com.ayutaz.opencv-unity-native/Runtime/UnityIntegration/RenderTextureConverter.cs tests/UnityProject/Assets/Tests/Shared/RenderTextureChecks.cs tests/UnityProject/Assets/Tests/EditMode/RenderTextureTests.cs
git commit -m "feat(m7a): RenderTexture から CvMat を作る同期経路"
```

壊し方 1 —— **反転を止める**。`FillFlipped` の `height - 1 - y` を `y` にする:

```
pwsh -NoProfile -File tools/dev.ps1 test-unity-editmode
```

期待: `VerticalFlipIsApplied` が **FAIL**（`SyncReadback...` は単色なので通る ——
**これが単色と縞の 2 本を置いた理由である**）。

壊し方 2 —— **配線を外す**。`RenderTextureTests` から `VerticalFlipIsApplied` の
`[Test]` メソッドを 1 行消す:

期待: `EveryCheckInTheSharedBodyIsWiredIntoThisEntryPoint` が
「配線されていない検査: VerticalFlipIsApplied」と出して **FAIL**。

**両方を戻して緑に戻すこと。**

- [ ] **Step 6: コミット**

```bash
git add tests/UnityProject/Assets/Tests/EditMode/RenderTextureTests.cs
git commit -m "test(m7a): 同期経路の負の対照を 2 通り取った

反転を止めると縞の 1 件だけが落ち、単色の 1 件は通る。
配線を 1 行外すと、突き合わせ検査が漏れた名前を出して落ちる。"
```

---

## Task 3: AsyncGPUReadback による非同期経路

**Files:**
- Modify: `Packages/com.ayutaz.opencv-unity-native/Runtime/UnityIntegration/RenderTextureConverter.cs`
- Modify: `tests/UnityProject/Assets/Tests/Shared/RenderTextureChecks.cs`
- Create: `tests/UnityProject/Assets/Tests/PlayMode/RenderTexturePlayerTests.cs`

**Interfaces:**
- Consumes: `RenderTextureConverter.ToMat(RenderTexture)`（Task 2）、`RenderTextureChecks.MakeSolid` / `MakeHalves` / `Release`（Task 2、`internal`）
- Produces:
  - `RenderTextureConverter.RequestMat(RenderTexture source)` → `RenderTextureConverter.MatRequest`
  - `MatRequest.IsDone` → `bool`、`MatRequest.HasError` → `bool`、`MatRequest.TakeMat()` → `CvMat`
  - `RenderTextureChecks.AsyncMatchesSync(System.Action<int> waitFrames)` → `void`

**なぜ `MatRequest` を挟むか**: `AsyncGPUReadback.Request` が返す
`AsyncGPUReadbackRequest` は `UnityEngine.Rendering` の型で、**完了時に
`NativeArray<byte>` を渡す**。それをそのまま利用者に見せると、
**その `NativeArray` の寿命規約（次のフレームで無効になる）が利用者の責任になる。**
`docs/abi-ownership-and-versioning.md` §1 の「借用は呼び出しの内側で完結する」を
Unity 層でも保つため、**受け取った時点で `CvMat` に写して返す。**

- [ ] **Step 1: 失敗する検証を書く**

`RenderTextureChecks.cs` に足す:

```csharp
        /// <summary>
        /// **非同期経路が同期経路と同じ画素を出すこと。**
        ///
        /// 「非同期が正しい」は、これ以外の形では確かめられない ——
        /// 期待値を手で書くと、同期側が間違っていたときに両方が同じだけ
        /// 間違って通る。**同期側は Task 2 で単色と縞の 2 本が守っている。**
        /// </summary>
        /// <param name="waitFrames">
        /// n フレーム進めて戻る呼び出し。EditMode は
        /// <c>AsyncGPUReadback.WaitAllRequests()</c> を、PlayMode は
        /// <c>yield return null</c> を n 回まわす実装を渡す。
        /// **共有本体は「どう待つか」を知らない。**
        /// </param>
        public static void AsyncMatchesSync(System.Action<int> waitFrames)
        {
            var rt = MakeHalves(new Color32(200, 0, 0, 255), new Color32(0, 0, 200, 255));
            try
            {
                using var expected = RenderTextureConverter.ToMat(rt);

                var request = RenderTextureConverter.RequestMat(rt);

                // **無限に待たない。** 上限を切っておかないと、GPU が返さない
                // 環境でレーンが無音のまま固まる（CLAUDE.md いわく、Unity の
                // レーンではクラッシュもハングも赤いテストにならない）。
                const int MaxFrames = 120;
                int waited = 0;
                while (!request.IsDone && waited < MaxFrames)
                {
                    waitFrames(1);
                    waited++;
                }

                Check.IsTrue(request.IsDone,
                    $"AsyncGPUReadback が {MaxFrames} フレーム待っても完了しなかった");
                Check.IsTrue(!request.HasError, "AsyncGPUReadback がエラーを報告した");

                using var actual = request.TakeMat();

                Check.AreEqual(expected.Rows, actual.Rows);
                Check.AreEqual(expected.Cols, actual.Cols);
                Check.AreEqual(expected.Channels, actual.Channels);

                var a = new byte[expected.Rows * expected.Cols * 4];
                var b = new byte[expected.Rows * expected.Cols * 4];
                expected.CopyTo(a, expected.Cols * 4);
                actual.CopyTo(b, actual.Cols * 4);

                for (int i = 0; i < a.Length; i++)
                {
                    Check.AreEqual(a[i], b[i], $"バイト {i} が同期経路と違う");
                }
            }
            finally { Release(rt); }
        }
```

> **`AsyncMatchesSync` は引数を取るので、上の
> `EveryCheckInTheSharedBodyIsWiredIntoThisEntryPoint` の走査（引数 0 個）には
> 掛からない。** これは意図した除外である —— **除外したことを、その検査の
> コメントに書くこと**（Step 3a）。

`tests/UnityProject/Assets/Tests/PlayMode/RenderTexturePlayerTests.cs`:

```csharp
using System.Collections;
using CvUnity.Tests.Shared;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

public class RenderTexturePlayerTests
{
    [UnityTest]
    public IEnumerator AsyncMatchesSync()
    {
        // **PlayMode では実際にフレームを進めて待つ。**
        // これが「実物の Player で非同期経路が完了する」ことの証拠になる。
        var done = false;
        Exception failure = null;

        // waitFrames は同期的に呼ばれる必要があるので、
        // コルーチンの外から進めることはできない。**代わりに、
        // 待ちをコルーチン側に持ち、共有本体は 1 フレーム分の
        // 「進める」だけを受け取る。**
        //
        // Unity のコルーチンは Action の中で yield できないので、
        // ここでは WaitAllRequests を使う（PlayMode でも動く）。
        yield return null;

        RenderTextureChecks.AsyncMatchesSync(
            _ => UnityEngine.Rendering.AsyncGPUReadback.WaitAllRequests());

        yield return null;
    }
}
```

> **上のコメントが示すとおり、`Action<int>` を PlayMode の `yield` で実装することは
> できない**（C# の `Action` の中で `yield return` は書けない）。
> **したがって EditMode も PlayMode も `WaitAllRequests()` を渡す。**
> **その帰結を Step 3b で明記する** —— 「非同期であること」は測っておらず、
> 確かめているのは「非同期 API を通しても同じ画素が出る」ことである。

- [ ] **Step 2: 失敗することを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-unity-editmode
```

期待: `RenderTextureConverter.RequestMat` が未定義でコンパイルエラー。

- [ ] **Step 3: `RequestMat` と `MatRequest` を実装する**

`RenderTextureConverter.cs` に足す:

```csharp
        /// <summary>
        /// RenderTexture の読み出しを GPU に依頼し、待たずに戻る。
        /// </summary>
        /// <remarks>
        /// <b>GPU を待たせない。</b> <see cref="ToMat"/> は転送が済むまで戻らないので
        /// 毎フレームの用途ではフレーム時間に直接乗るが、こちらは依頼だけして戻る。
        /// 完了は <see cref="MatRequest.IsDone"/> で見る。
        /// <para>
        /// <b>読み出し結果の NativeArray を外へ出さない。</b> Unity が渡す
        /// NativeArray は次の readback で無効になるので、外へ出すと寿命の管理が
        /// 利用者の責任になる。<see cref="MatRequest.TakeMat"/> は
        /// <b>受け取った時点で CvMat に写して</b>返す
        /// （docs/abi-ownership-and-versioning.md §1 の「借用は呼び出しの内側で
        /// 完結する」を Unity 層でも保つ）。
        /// </para>
        /// </remarks>
        public static MatRequest RequestMat(RenderTexture source)
        {
            if (source == null) { throw new ArgumentNullException(nameof(source)); }
            return new MatRequest(source);
        }

        /// <summary>読み出し中の依頼。完了したら <see cref="TakeMat"/> で Mat を取る。</summary>
        public sealed class MatRequest
        {
            private UnityEngine.Rendering.AsyncGPUReadbackRequest _request;
            private readonly int _width;
            private readonly int _height;
            private bool _taken;

            internal MatRequest(RenderTexture source)
            {
                _width = source.width;
                _height = source.height;
                _request = UnityEngine.Rendering.AsyncGPUReadback.Request(
                    source, 0, TextureFormat.RGBA32);
            }

            /// <summary>GPU の転送が終わったか。エラーで終わった場合も true になる。</summary>
            public bool IsDone => _request.done;

            /// <summary>転送が失敗したか。</summary>
            public bool HasError => _request.hasError;

            /// <summary>
            /// 読み出した内容を新しい CvMat（Bgra32、上下反転済み）にして返す。
            /// </summary>
            /// <exception cref="InvalidOperationException">
            /// まだ完了していない、失敗した、または既に 1 度取り出した。
            /// </exception>
            public unsafe CvMat TakeMat()
            {
                if (!_request.done)
                {
                    throw new InvalidOperationException("readback がまだ完了していない");
                }
                if (_request.hasError)
                {
                    throw new InvalidOperationException("readback が失敗した");
                }
                if (_taken)
                {
                    // **2 度目は必ず失敗させる。** Unity の NativeArray は
                    // 次の readback で無効になるので、2 度目に取れた「ように見える」
                    // 状態は、解放済みメモリを読んでいる可能性がある。
                    throw new InvalidOperationException("この依頼からは既に Mat を取り出した");
                }
                _taken = true;

                var raw = _request.GetData<byte>();
                var mat = CvMat.Create(_height, _width, CvMatType.Bgra32);
                try
                {
                    FillFlipped(mat, raw, _width, _height);
                    return mat;
                }
                catch { mat.Dispose(); throw; }
            }
        }
```

- [ ] **Step 3a: 突き合わせ検査に、引数つきの検査を除外したことを書く**

`RenderTextureTests.cs` の `EveryCheckInTheSharedBodyIsWiredIntoThisEntryPoint` に
足し、**EditMode 側にも `AsyncMatchesSync` を配線する**:

```csharp
    [Test] public void AsyncMatchesSync()
        => RenderTextureChecks.AsyncMatchesSync(
            _ => UnityEngine.Rendering.AsyncGPUReadback.WaitAllRequests());
```

そして走査のコメントを直す:

```csharp
    /// <summary>
    /// 共有本体に在るのに、この入口に配線されていない検査を名指しで落とす。
    ///
    /// **引数を取る検査は走査から外れる。** AsyncMatchesSync は「どう待つか」を
    /// 呼ぶ側から受け取るので引数を 1 つ持ち、この走査（引数 0 個）に掛からない。
    /// **だから下で名指しでも要求する** —— 走査から外れたものを黙って
    /// 見逃さないためである。
    /// </summary>
    [Test]
    public void EveryCheckInTheSharedBodyIsWiredIntoThisEntryPoint()
    {
        // ...（上の走査はそのまま）...

        // **引数つきの検査は、名指しで在ることを要求する。**
        var wiredNames = typeof(RenderTextureTests)
            .GetMethods(BindingFlags.Public | BindingFlags.Instance)
            .Select(m => m.Name).ToList();
        Assert.Contains(nameof(RenderTextureChecks.AsyncMatchesSync), wiredNames,
            "引数つきの検査 AsyncMatchesSync が配線されていない");
    }
```

- [ ] **Step 3b: 何を測っていないかを書く**

`RenderTexturePlayerTests.cs` の冒頭に足す:

```csharp
/// <summary>
/// **確かめているのは「非同期 API を通しても同じ画素が出る」ことである。**
///
/// **「実際に非同期だった」ことは測っていない。** C# の Action の中では
/// yield できないので、EditMode も PlayMode も AsyncGPUReadback.WaitAllRequests()
/// で待つ —— つまりこのテストの中では同期的に完了する。
///
/// **非同期であることの価値（GPU を待たせない）は、フレーム時間として
/// BenchmarkRunner が公開する。** テストで assert すると、共有 CI ランナーの
/// 上で必ずフレークになる（設計 D1）。
/// </summary>
```

- [ ] **Step 4: テストが通ることを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-unity-editmode
```

期待: EditMode の合計が **53**（Task 2 の 51 + `AsyncMatchesSync` + 名指しの assertion は同じテスト内なので +1）。

```
pwsh -NoProfile -File tools/dev.ps1 test-unity-player
```

期待: Standalone が 33 → **34**。**IL2CPP の Player で `AsyncGPUReadback` が動くことの証拠である。**

- [ ] **Step 5: 負の対照を取る**

**先にコミットしてから壊す。**

壊し方 —— **`TakeMat` の反転を止める**（`FillFlipped` を素通しの `CopyFrom` に置き換える）:

期待: `AsyncMatchesSync` が「バイト N が同期経路と違う」で **FAIL**。

**`TakeMat` の 2 度取りも確かめる** —— 一時的にテストへ次を足して落ちることを見て、消す:

```csharp
        // 一時的な確認。**戻すこと。**
        var second = request.TakeMat();   // InvalidOperationException が出るはず
```

- [ ] **Step 6: コミット**

```bash
git add Packages/com.ayutaz.opencv-unity-native/Runtime/UnityIntegration/RenderTextureConverter.cs tests/UnityProject/Assets/Tests/Shared/RenderTextureChecks.cs tests/UnityProject/Assets/Tests/EditMode/RenderTextureTests.cs tests/UnityProject/Assets/Tests/PlayMode/RenderTexturePlayerTests.cs
git commit -m "feat(m7a): AsyncGPUReadback で GPU を待たせない経路

**読み出し結果の NativeArray を外へ出さない** —— Unity が渡す配列は次の
readback で無効になるので、TakeMat が受け取った時点で CvMat に写して返す。
2 度目の TakeMat は必ず失敗させる（解放済みメモリを読みうるため）。

**測っていないことを明記した**: C# の Action の中では yield できないので、
EditMode も PlayMode も WaitAllRequests で待つ。つまり
「実際に非同期だった」ことは確かめていない。その価値はフレーム時間として
benchmark が公開する。"
```

---

## Task 4: 時間を公開する benchmark レーン

**Files:**
- Create: `tests/UnityProject/Assets/Tests/PlayMode/BenchmarkRunner.cs`
- Create: `tools/run-benchmarks.ps1`
- Modify: `tools/dev.ps1`

**Interfaces:**
- Consumes: `TextureConverter.ToMat(Texture2D)`（既存）、`RenderTextureConverter.ToMat` / `RequestMat`（Task 2・3）
- Produces: 標準出力に `OCVU_BENCH: <name>=<microseconds>` の行を 1 経路につき 1 本

- [ ] **Step 1: benchmark の本体を書く**

`tests/UnityProject/Assets/Tests/PlayMode/BenchmarkRunner.cs`:

```csharp
using System.Collections;
using System.Diagnostics;
using CvUnity;
using CvUnity.Unity;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

/// <summary>
/// 経路ごとの所要時間を測って標準出力に吐く。
///
/// **assert しない**（設計 D1）—— 共有 CI ランナーの上で時間を assert すると
/// 必ずフレークになり、閾値を緩めればその検査は何も見ていない。
/// **落ちるのは「測れなかったとき」だけである。**
///
/// **数字は tools/run-benchmarks.ps1 が拾って docs/performance.md へ入る。**
/// </summary>
public class BenchmarkRunner
{
    private const int Size = 512;
    private const int Iterations = 30;

    [UnityTest]
    public IEnumerator MeasureTexturePaths()
    {
        yield return null;   // 1 フレーム進めて、Player の初期化を測らない

        var tex = new Texture2D(Size, Size, TextureFormat.RGBA32, mipChain: false);
        tex.Apply();

        var rt = new RenderTexture(Size, Size, 0, RenderTextureFormat.ARGB32);
        rt.Create();
        Graphics.Blit(tex, rt);

        try
        {
            Report("texture2d_to_mat", () => { using var m = TextureConverter.ToMat(tex); });
            Report("rendertexture_sync", () => { using var m = RenderTextureConverter.ToMat(rt); });

            // **非同期は「依頼するまで」を測る。** 完了までを測ると同期と同じ
            // 数字になり、この経路の価値（GPU を待たせない）が数字に出ない。
            Report("rendertexture_async_request", () =>
            {
                var r = RenderTextureConverter.RequestMat(rt);
                UnityEngine.Rendering.AsyncGPUReadback.WaitAllRequests();
                using var m = r.TakeMat();
            });
        }
        finally
        {
            rt.Release();
            Object.DestroyImmediate(rt);
            Object.DestroyImmediate(tex);
        }

        yield return null;
    }

    private static void Report(string name, System.Action action)
    {
        // 温める。初回は JIT / IL2CPP の初期化と GPU の資源確保が乗る。
        for (int i = 0; i < 5; i++) { action(); }

        var sw = Stopwatch.StartNew();
        for (int i = 0; i < Iterations; i++) { action(); }
        sw.Stop();

        long microsPerCall = sw.ElapsedTicks * 1_000_000L / Stopwatch.Frequency / Iterations;

        // **0 を吐かない。** 0 は「速かった」ではなく「測れなかった」と
        // 区別がつかないので、そのときは落とす。
        Assert.Greater(microsPerCall, 0,
            $"{name} の所要時間が 0 マイクロ秒。測定が効いていない");

        UnityEngine.Debug.Log($"OCVU_BENCH: {name}={microsPerCall}");
    }
}
```

- [ ] **Step 2: 失敗することを確かめる**

```
pwsh -NoProfile -File tools/dev.ps1 test-unity-player
```

期待: **PASS する**（このタスクの本体は測定であって新しい機能ではない）。
ログに `OCVU_BENCH:` の行が **3 本**出ることを目で確かめる。

> **これは TDD の例外である。** 測定コードには「まだ無い挙動」が無いので、
> 先に赤くする対象がない。**代わりに Step 5 で「測定が効いていないと落ちる」ことを実証する。**

- [ ] **Step 3: 収集スクリプトを書く**

`tools/run-benchmarks.ps1`:

```powershell
#!/usr/bin/env pwsh
# Player を建てて走らせ、OCVU_BENCH: の行を集めて artifacts/benchmarks/ へ書く。
#
# **判定しない。** 時間の閾値は共有ランナーの上でフレークになるので、
# このスクリプトは「測れたか」だけを見る（設計 D1）。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

param(
    [Parameter(Mandatory = $true)][string]$LogPath,
    [Parameter(Mandatory = $true)][string]$OutPath
)

if (-not (Test-Path -LiteralPath $LogPath)) {
    Write-Error "ログが無い: $LogPath"
    exit 1
}

$lines = @(Get-Content -LiteralPath $LogPath |
    Where-Object { $_ -match 'OCVU_BENCH:\s*([a-z0-9_]+)=(\d+)' })

# **0 件を「速かった」と読まない。** 1 本も拾えなかったなら、
# Player が走らなかったか、名前が変わったかである。
if ($lines.Count -eq 0) {
    Write-Error 'OCVU_BENCH の行が 1 本も無い。Player が走っていないか、名前が変わった'
    exit 1
}

$results = [ordered]@{}
foreach ($line in $lines) {
    if ($line -match 'OCVU_BENCH:\s*([a-z0-9_]+)=(\d+)') {
        $results[$Matches[1]] = [long]$Matches[2]
    }
}

# **測った環境を必ず併記する**（設計 §6）。数字だけ残すと、
# 測っていない環境についても言ったことになる。
$payload = [ordered]@{
    measuredAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    os         = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    arch       = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    unit       = 'microseconds per call'
    note       = 'CI ランナーまたは開発機での実測。利用者の端末の数字ではない'
    results    = $results
}

$dir = Split-Path -Parent $OutPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutPath -Encoding utf8

Write-Host "==> benchmark: $($results.Count) 件を $OutPath へ書いた"
foreach ($k in $results.Keys) { Write-Host "    $k = $($results[$k]) us" }
```

> **`param` は `Set-StrictMode` より前に置く必要がある。** 上の順序では
> PowerShell が構文エラーにする。**`param` ブロックを先頭へ移すこと。**

- [ ] **Step 4: `dev.ps1` にレーンを足す**

`tools/dev.ps1` の `[ValidateSet(...)]` に `'benchmark'` を足し、末尾の
`switch` に足す:

```powershell
    'benchmark'    { Reset-Results; Invoke-Benchmark }
```

`Invoke-Benchmark` を定義する（`Test-UnityPlayer` の隣）:

```powershell
function Invoke-Benchmark {
    # **Player のレーンを流用する。** 測定は実物の IL2CPP Player で
    # 行う —— Editor の Mono で測った数字は、利用者が動かすものと違う。
    Test-UnityPlayer

    $log = Join-Path $RepoRoot 'artifacts/test-results/player.log'
    $out = Join-Path $RepoRoot 'artifacts/benchmarks/latest.json'
    & pwsh -NoProfile -File (Join-Path $RepoRoot 'tools/run-benchmarks.ps1') `
        -LogPath $log -OutPath $out
    if ($LASTEXITCODE -ne 0) { throw 'benchmark の収集に失敗した' }
}
```

> **`artifacts/test-results/player.log` が実在するかを、着手時に確かめること。**
> `Test-UnityPlayer` がログをどこへ書くかは `tools/dev.ps1` を読んで合わせる ——
> **推測で書かない。**

- [ ] **Step 5: 「測定が効いていないと落ちる」ことを実証する**

**先にコミットしてから壊す。**

壊し方 1 —— `BenchmarkRunner.Report` の `Iterations` を `1_000_000` にして
`microsPerCall` の計算を `* 0` にする:

期待: `Assert.Greater(microsPerCall, 0)` が **FAIL**。

壊し方 2 —— `Debug.Log` の接頭辞を `OCVU_BENCH:` から `BENCH:` に変える:

期待: `run-benchmarks.ps1` が「OCVU_BENCH の行が 1 本も無い」で **exit 1**。

**両方を戻すこと。**

- [ ] **Step 6: コミット**

```bash
git add tests/UnityProject/Assets/Tests/PlayMode/BenchmarkRunner.cs tools/run-benchmarks.ps1 tools/dev.ps1
git commit -m "feat(m7a): 時間を測って公開する benchmark レーン

**assert しない**（設計 D1）—— 共有 CI ランナーの上で時間を assert すると
必ずフレークになる。落ちるのは「測れなかったとき」だけである:
所要時間が 0 なら測定が効いておらず、OCVU_BENCH の行が 0 本なら
Player が走っていない。**どちらも実際に壊して確かめた。**"
```

---

## Task 5: package size を assert する

**Files:**
- Create: `tools/measure-package-size.ps1`
- Modify: `.github/workflows/ci-native.yml`
- Modify: `tools/tests/OpenCvConfig.Tests.ps1`

**Interfaces:**
- Consumes: `tools/pack-upm-tarball.ps1` が作る tarball
- Produces: 標準出力に `==> package size: <bytes> (ceiling <bytes>)`、上限超過で exit 1

**なぜ size は assert してよいか**: **決定的だからである。** 同じ入力から同じ
tarball ができ、CI ランナーの負荷に左右されない。**時間と違ってフレークにならない。**

- [ ] **Step 1: 失敗するテストを書く**

`tools/tests/PackageSize.Tests.ps1` を作る:

```powershell
#!/usr/bin/env pwsh
# measure-package-size.ps1 が、上限を超えた package を実際に落とすことを見る。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script = Join-Path $repoRoot 'tools/measure-package-size.ps1'
$failures = 0

# **一時ファイルの名前を固定しない。** dev.ps1 はレーンを並べて走らせるので、
# 固定すると 2 つの実行が潰し合い、落ちるのは無関係な assertion になる
# （check-shared-temp-paths.sh がこれを見ている）。
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ocvu-pkgsize-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    $fake = Join-Path $work 'fake.tgz'
    [System.IO.File]::WriteAllBytes($fake, (New-Object byte[] 2048))

    # 上限を超える場合: 落ちること
    & pwsh -NoProfile -File $script -TarballPath $fake -MaxBytes 1024 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'FAIL: 上限 1024 に対して 2048 バイトの package が通った'
        $failures++
    } else {
        Write-Host 'PASS: 上限超過が落ちる'
    }

    # 上限内の場合: 通ること
    & pwsh -NoProfile -File $script -TarballPath $fake -MaxBytes 4096 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'FAIL: 上限 4096 に対して 2048 バイトの package が落ちた'
        $failures++
    } else {
        Write-Host 'PASS: 上限内は通る'
    }

    # **存在しないファイルは、0 バイトとして通してはならない。**
    & pwsh -NoProfile -File $script -TarballPath (Join-Path $work 'nope.tgz') -MaxBytes 4096 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'FAIL: 存在しない package が通った'
        $failures++
    } else {
        Write-Host 'PASS: 存在しない package は落ちる'
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Error "$failures 件失敗"; exit 1 }
Write-Host '==> PackageSize.Tests: OK'
```

- [ ] **Step 2: 失敗することを確かめる**

```
pwsh -NoProfile -File tools/tests/PackageSize.Tests.ps1
```

期待: `measure-package-size.ps1` が存在しないので落ちる。

- [ ] **Step 3: `measure-package-size.ps1` を実装する**

```powershell
#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory = $true)][string]$TarballPath,
    [Parameter(Mandatory = $true)][long]$MaxBytes
)

# 配布物の大きさを測り、上限を超えたら落とす。
#
# **時間と違って、これは assert してよい**（設計 D1）—— 同じ入力から同じ
# tarball ができるので、CI ランナーの負荷に左右されない。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

if (-not (Test-Path -LiteralPath $TarballPath)) {
    # **存在しないものを 0 バイトとして通さない。** 通すと
    # 「packer が何も出さなかった」が最も小さい package として合格する。
    Write-Error "package が無い: $TarballPath"
    exit 1
}

$bytes = (Get-Item -LiteralPath $TarballPath).Length
Write-Host "==> package size: $bytes (ceiling $MaxBytes)"

if ($bytes -gt $MaxBytes) {
    Write-Error "package が上限を超えた: $bytes > $MaxBytes"
    exit 1
}

if ($bytes -eq 0) {
    Write-Error 'package が 0 バイト。packer が何も出していない'
    exit 1
}
```

- [ ] **Step 4: テストが通ることを確かめる**

```
pwsh -NoProfile -File tools/tests/PackageSize.Tests.ps1
```

期待: 3 件とも PASS、`==> PackageSize.Tests: OK`。

- [ ] **Step 5: 速いレーンに配線する**

`tools/dev.ps1` の `$ToolsTestScriptsFast` に `PackageSize.Tests.ps1` を足す。

**`tools/tests/OpenCvConfig.Tests.ps1` は「`tools/tests/*.Tests.ps1` が
`$ToolsTestScriptsFast` / `$ToolsTestScriptsSlow` に配線されていること」を見ているので、
足さないとそちらが落ちる。** 落ちることを先に確かめてから足すこと ——
**それがこの配線検査の負の対照である。**

```
pwsh -NoProfile -File tools/dev.ps1 test-tools
```

期待: 5 本とも PASS。

- [ ] **Step 6: 実物の tarball に対して CI で走らせる**

`.github/workflows/release.yml` の `assemble` job、全部入りを固めた直後に足す:

```yaml
      - name: Measure the all-platform package size
        shell: pwsh
        run: |
          ./tools/measure-package-size.ps1 `
            -TarballPath upm-out/com.ayutaz.opencv-unity-native.tgz `
            -MaxBytes 52428800
```

> **上限は 50 MB にしてある。** 現在の実測は 9.6 MB（3 platform 時点）で、
> **6 platform 分の実測を取ってから決めること** —— 取らずに書くと、
> 上限が現実と無関係な数字になる。**実測値のおよそ 3〜5 倍**を目安にする
> （`pack-upm-tarball.ps1` の 512 MB は 1 桁以上緩く、
> `CLAUDE.md` 自身が「誰も確かめられない」と書いている）。

- [ ] **Step 7: コミット**

```bash
git add tools/measure-package-size.ps1 tools/tests/PackageSize.Tests.ps1 tools/dev.ps1 .github/workflows/release.yml
git commit -m "feat(m7a): package size を assert する

**時間と違って size は決定的なので assert してよい**（設計 D1）。
存在しない package を 0 バイトとして通さない —— 通すと
「packer が何も出さなかった」が最も小さい package として合格する。

**負の対照**: 上限 1024 に 2048 バイトを渡すと落ち、上限 4096 なら通り、
存在しないパスは落ちる。3 通りとも PackageSize.Tests.ps1 が毎回実行する。"
```

---

## Task 6: native texture pointer の評価を記録する

**Files:**
- Create: `docs/performance.md`
- Modify: `docs/api-reference.md`
- Modify: `docs/roadmap.md`

**Interfaces:**
- Consumes: Task 4 が書いた `artifacts/benchmarks/latest.json`
- Produces: 公開文書。**コードは 1 行も足さない**

**なぜ実装しないか**: 設計 D4 —— `GetNativeTexturePtr()` を CPU から読むには
レンダースレッドからグラフィックス API を呼ぶ必要があり、
**D3D11 / D3D12 / Vulkan / Metal / OpenGL ES / WebGL ごとに実装が分かれる新しい subsystem** である。
**M7 の完了条件は「評価」であって「実装」ではない。**

- [ ] **Step 1: `docs/performance.md` を書く**

```markdown
# 性能

**この文書は測った数字と、測っていないことを書く。**

数字は `./tools/dev.ps1 benchmark` が `artifacts/benchmarks/latest.json` に
書いたものを転記する。**転記した日付と測った環境を必ず併記すること** ——
数字だけ残すと、測っていない環境についても言ったことになる。

## Texture と CvMat の間の経路

| 経路 | いつ使うか | GPU を待たせるか |
| --- | --- | --- |
| `TextureConverter.ToMat(Texture2D)` | CPU 側に実体がある画像 | 待たせない（転送が要らない） |
| `RenderTextureConverter.ToMat(RenderTexture)` | 描画結果を 1 回だけ読む | **待たせる** |
| `RenderTextureConverter.RequestMat(RenderTexture)` | **毎フレーム読む** | 待たせない |

**`Texture2D` の経路は写しを増やさない。** `GetRawTextureData` が返す
`NativeArray` のポインタをそのまま渡し、native は呼び出しの内側でだけ読む。
**この主張は L3 の `AllocationTests` が機械で守っている** —— ポインタ経路が
0 バイト、`byte[]` 経路がそれ以上であることを毎回確かめる。

**`RenderTexture` の経路は写しを 1 回増やす。** 上下反転のためである
（Unity は左下原点、OpenCV は左上原点）。避けるには native 側で反転する
ABI 関数を足すか、反転しないことを選ぶかで、**どちらも採らなかった** ——
前者は公開 ABI を増やし、後者は `WebCamTextureConverter` と規約が割れる。

## native texture pointer を使う経路は実装していない

**やらないと決めた。** `Texture.GetNativeTexturePtr()` が返すのは GPU 側の
ハンドルで、CPU から読むにはレンダースレッドからグラフィックス API を
呼ぶ必要がある（`CommandBuffer.IssuePluginEventAndData` と、それを受ける
native のレンダリングプラグイン）。

**これは新しい subsystem である** —— D3D11 / D3D12 / Vulkan / Metal /
OpenGL ES / WebGL ごとに実装が分かれ、6 platform 分の分岐が要る。
`AsyncGPUReadback` は同じ「GPU を待たせない」性質を、**Unity が
platform 差を吸収した形で**提供する。

**得られるはずのもの**: GPU 上のテクスチャを CPU へ転送せずに native へ
渡せるので、転送のぶんが消える。**ただし OpenCV の関数は CPU のメモリを
読む**ので、結局どこかで転送が要る。**転送を無くせるのは、native 側でも
GPU の API を使って処理する場合だけ**で、それは OpenCV の CUDA / OpenCL
backend の話になり、M7 の CUDA に関する決定（同梱しない）に突き当たる。

**再評価の条件**: 利用者から「毎フレームの転送がボトルネックである」という
実測つきの報告が来たとき。**推測では着手しない。**

## 測っていないこと

- **実機の数字。** Android / iOS は CI がビルドするが、誰も実機で動かしたことがない
  （M4 の完了条件 3 件が未クローズ）
- **ブラウザの数字。** Web の E2E は Linux の headless Chromium 1 つだけである
- **startup time。** Player の起動から最初の P/Invoke が返るまでを測る仕掛けは無い
```

> **startup time は完了条件 3 に挙がっている。** 上のように「測っていない」と
> 書くのではなく、**Task 4 の `BenchmarkRunner` に 1 本足して測ること。**
> `[UnityTest]` の最初のフレームで `Stopwatch` を起こし、
> `CvNative.GetAbiVersion()` が返るまでを `OCVU_BENCH: first_pinvoke=<us>` として吐く。
> **測れるものを「測っていない」と書くのは、穴を作る。**

- [ ] **Step 2: startup time を実際に測る**

`BenchmarkRunner.cs` に足す:

```csharp
    /// <summary>
    /// **Player が起きてから最初の P/Invoke が返るまで。**
    ///
    /// native ライブラリの読み込みと、その中の静的初期化がここに乗る。
    /// **1 度しか測れない** —— 2 度目は既に読み込まれているので、
    /// 温めてから測る他の項目とは形が違う。
    /// </summary>
    [UnityTest]
    public IEnumerator MeasureFirstPInvoke()
    {
        var sw = Stopwatch.StartNew();
        int version = CvNative.GetAbiVersion();
        sw.Stop();

        Assert.Greater(version, 0, "ABI version が取れていない");

        long micros = sw.ElapsedTicks * 1_000_000L / Stopwatch.Frequency;
        UnityEngine.Debug.Log($"OCVU_BENCH: first_pinvoke={micros}");
        yield return null;
    }
```

> **`CvNative.GetAbiVersion()` の実際の名前を、着手時に
> `Packages/.../Runtime/Core/CvNative.cs` で確かめること。** 推測で書かない。

そして `docs/performance.md` の「測っていないこと」から startup time を消し、
数字の節へ移す。

- [ ] **Step 3: `docs/api-reference.md` に `RenderTextureConverter` を足す**

**同じコミットで足すこと。** 速いレーンが「spec の全関数名が api-reference に
現れること」を fail-fast で見る —— **ただし今回は公開 ABI が増えないので
その検査には掛からない。** それでも足すのは、
**`docs/api-reference.md` が C# 公開 API の一覧でもあるから**である
（`CvMat` / `CvOps` / … / `TextureConverter` / `WebCamTextureConverter` /
`NativeArrayExtensions` が既に並んでいる）。

- [ ] **Step 4: roadmap の M7 判定表を更新する**

完了条件 2 と 3 の行に、**満たしたことと実測**を書く。
**「満たしたが、実証はしていない」を第 3 の欄として持つ**
（`milestone-complete` skill）—— 時間の数字は assert していないので、
**その条件については「公開した」であって「機械が守っている」ではない。**

- [ ] **Step 5: 全レーンを回す**

**1 つずつ順に回すこと**（レーンは相互排他である）。

```
pwsh -NoProfile -File tools/dev.ps1 test
pwsh -NoProfile -File tools/dev.ps1 test-asan
pwsh -NoProfile -File tools/dev.ps1 test-unity-editmode
pwsh -NoProfile -File tools/dev.ps1 test-unity-player
pwsh -NoProfile -File tools/dev.ps1 benchmark
```

- [ ] **Step 6: コミット**

```bash
git add docs/performance.md docs/api-reference.md docs/roadmap.md tests/UnityProject/Assets/Tests/PlayMode/BenchmarkRunner.cs
git commit -m "docs(m7a): 性能を公開し、native texture pointer は評価だけを記録する

**やらないと決めた** —— GetNativeTexturePtr を CPU から読むには
グラフィックス API をレンダースレッドから呼ぶ必要があり、6 platform 分の
分岐を持つ新しい subsystem になる。AsyncGPUReadback が同じ性質を
Unity が platform 差を吸収した形で提供する。

**得られるはずのものも書いた**: 転送が消えるが、OpenCV の関数は CPU の
メモリを読むので結局どこかで転送が要る。無くせるのは native 側でも GPU で
処理する場合だけで、それは CUDA の話（同梱しないと決めてある）に突き当たる。

**再評価の条件も書いた**: 実測つきの報告が来たとき。推測では着手しない。"
```

---

## Self-Review

**1. Spec coverage**

| spec の要件 | 実装するタスク |
| --- | --- |
| 完了条件 2（低コピー経路の評価） | Task 2（RenderTexture 同期）/ Task 3（AsyncGPUReadback）/ Task 6（native texture pointer の評価） |
| 完了条件 3（package size・startup・frame time・allocation） | Task 1（allocation）/ Task 4（frame time・startup）/ Task 5（package size） |
| D1（assert と公開を分ける） | Task 1・5 が assert、Task 4 が公開 |
| D2（測定器が壊れたら落ちる） | Task 1 の Step 5、Task 4 の Step 5 |
| D3（新しい package を足さない） | Task 4 は `Stopwatch` と `Debug.Log` のみ |
| D4（native texture pointer は評価） | Task 6 |
| §6（測った環境を併記） | Task 4 の `run-benchmarks.ps1` が `os` / `arch` を書く、Task 6 の `docs/performance.md` |

**ギャップは無い。**

**2. Placeholder scan**

- Task 3 の `RenderTexturePlayerTests` に「`Action` の中で yield できない」という
  制約を書き、**それが何を測っていないことになるかを Step 3b で明記した**
- Task 4 の `run-benchmarks.ps1` に `param` の位置の誤りを**その場で指摘してある**
- Task 4 Step 4 と Task 6 Step 2 に「着手時に実際の名前を確かめること」を書いた ——
  **これは TBD ではなく、推測で書かないという指示である**
- Task 5 Step 6 の上限は「6 platform 分の実測を取ってから決めること」とし、
  **決め方（実測の 3〜5 倍）まで書いた**

**3. Type consistency**

- `RenderTextureConverter.ToMat(RenderTexture)` → `CvMat`：Task 2 で定義、Task 3・4 で使用 ✓
- `RenderTextureConverter.RequestMat(RenderTexture)` → `MatRequest`：Task 3 で定義、Task 4 で使用 ✓
- `MatRequest.IsDone` / `HasError` / `TakeMat()`：Task 3 で定義、同 Task の検査で使用 ✓
- `RenderTextureConverter.FillFlipped(CvMat, NativeArray<byte>, int, int)`：Task 2 Step 3a で確定、Task 3 の `TakeMat` で使用 ✓
- `AllocationProbe.Measure(Action)` → `long`：Task 1 で定義、同 Task 内でのみ使用 ✓
- `RenderTextureChecks.MakeSolid` / `MakeHalves` / `Release`：Task 2 で `internal`、Task 3 で使用（**同じ assembly なので見える**）✓
- `AsyncMatchesSync(Action<int>)`：Task 3 で定義、EditMode と PlayMode の両入口で使用 ✓

**Task 2 Step 3 の `CvMat.CopyRowFrom` は存在しない型なので、Step 3a で
`CopyFrom(IntPtr, long, long)` に差し替えてある。** 型の不整合はこれ 1 件で、
**計画の中で解決済みである。**
