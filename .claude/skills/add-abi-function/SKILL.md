---
name: add-abi-function
description: Use when adding, changing, or removing a function in the ocvu_ C ABI - the TDD order across the header, native implementation, L1 test, C# P/Invoke declaration and L3 test, plus the ownership, buffer and exception-barrier rules that the boundary must satisfy. Triggers on work involving opencv_unity_native.h, native/src, NativeMethods.cs, OCVU_TRY_BEGIN, ocvu_status, or any new ocvu_* entry point.
---

# C ABI 関数を追加する

ABI 関数を 1 本足す作業は 5〜7 ファイルにまたがる。順序を守らないと、実装が
先にできてしまいテストが後追いになるか、C# 側との対応が抜けたまま緑になる。

**この ABI が唯一の native contract である。** ここを通る型・所有権・エラーの
規約が、以降のすべての C# API と（M5 以降は）生成コードの形を決める。M0 の
時点で規約を曖昧にすると、generator が誤った契約を大量に複製することになる。

## 先に決めること

コードを書く前に 3 つ答える。答えが出ないなら、まだ実装に入らない。

1. **所有権は誰にあるか。** 呼び出し側が確保したバッファに書くのか、native が
   確保して handle を返すのか。返す場合、解放する関数は何か。
2. **失敗し得るか。** 失敗するなら `ocvu_status` を返す。失敗し得ないなら
   `int32_t` などを直接返してよいが、その根拠をコメントに書く。
3. **境界に出る型は固定サイズか。** `int32_t`、`uint64_t`、明示 struct、
   opaque handle のみ。`std::string`、`std::vector`、`cv::Mat` は出せない。

## 手順

### 1. 失敗する L1 テストを先に書く

`native/tests/test_*.cpp` に、これから作る関数の契約をテストとして書く。
既存のテストファイルに足すか、新規なら `native/tests/CMakeLists.txt` の
`ocvu_tests` のソース一覧にも追加する。

```
pwsh tools/dev.ps1 test-native
```

**RED を目で確認する。** 未定義シンボルでも、コンパイルエラーでもよい。
落ちない場合はテストが契約を検査していない。

### 2. ヘッダに宣言する

`native/include/opencv_unity_native.h` の `extern "C"` ブロック内に足す。
doc コメントには最低限これを書く:

- 引数の意味と、NULL を許すかどうか
- 出力バッファがあるなら、必要サイズの求め方と NUL の扱い
- 所有権（呼び出し側が解放するのか、native が解放するのか）
- 失敗し得る status code

新しい status code が要るなら `OCVU_STATUS_LIST` に 1 行足す。この X-macro が
status の唯一の定義元で、列挙子と実行時テーブルの両方がここから生成される。
**同時に `Runtime/Core/CvStatus.cs` にも同じ値を足すこと。** 片側だけ足すと
`StatusCodeSyncTests` が赤くなる（それが狙いの安全網）。

### 3. 実装する

`native/src/` の適切な `.cpp` に書き、新規ファイルなら
`native/CMakeLists.txt` の `OCVU_SOURCES` に足す。SHARED と STATIC の両方の
ターゲットがこのリストを共有しているので、1 箇所で済む。

**本体は例外バリアで囲む:**

```cpp
extern "C" ocvu_status ocvu_example(int32_t value, int32_t* out_result) {
    OCVU_TRY_BEGIN
    if (out_result == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_example: out_result is NULL");
    }
    *out_result = value * 2;
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
```

C++ 例外が `extern "C"` 関数を抜けて FFI 境界を越えると未定義動作になる。
`OCVU_TRY_BEGIN` は入口で last-error を消し、`OCVU_TRY_END` は例外を
status code と thread-local last-error に変換する。

**囲ってはならない関数がある。** `ocvu_get_last_error_status` と
`ocvu_get_last_error_message` は、`OCVU_TRY_BEGIN` が `clear_last_error()` を
呼ぶため、報告すべきエラーを読む直前に自分で消してしまう。`ocvu_status` を
返さない関数（`ocvu_get_abi_version` など）は `OCVU_TRY_END` の return と型が
合わないので構造的に囲えない。囲わない場合の条件は **throw し得ない実装で
あること**で、その理由をその場のコメントに書く。詳細は `native/src/ocvu_error.h`。

**エラー経路でアロケートしない。** `ocvu::set_last_error` は `noexcept` 契約で、
固定長バッファへの bounded copy しかしない。これは `OCVU_TRY_END` の
`catch (std::bad_alloc&)` の内側からも呼ばれるためで、ここでアロケートすると
メモリ逼迫時に二次的な例外が ABI を越える。

### 4. L1 を緑にする

```
pwsh tools/dev.ps1 test-native
```

### 5. C# 側の P/Invoke を足す

`Packages/com.ayutaz.opencv-unity-native/Runtime/Interop/NativeMethods.cs`:

```csharp
[DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
internal static extern int ocvu_example(int value, out int outResult);
```

`CallingConvention.Cdecl` は必須。C 側の型と 1 対 1 に対応させる。

公開 API を出すなら `Runtime/Core/` に薄いラッパを書く。**この 2 フォルダは
`UnityEngine` を参照してはならない。** 参照した瞬間に netstandard2.1 shim の
ビルドが落ち、Unity を起動しない L3 レーン（約 20 秒）が失われる。
UnityEngine に依存するコードは `Runtime/UnityIntegration/`（別 asmdef）へ置く。

### 6. L3 テストを書く

`tests/Managed/CvUnity.Tests.Managed/` に、実際の DLL を P/Invoke 越しに叩く
テストを書く。ここが「C 側の契約と C# 側の宣言が食い違っていないか」を
検査する唯一の層である。マーシャリング、バッファサイズ、status の対応を見る。

```
pwsh tools/dev.ps1 test-managed
```

### 7. 両レーンと sanitizer

```
pwsh tools/dev.ps1 test        # L1 + L3、約 20 秒
```

**メモリを触る関数を足したなら ASan まで回す:**

```
pwsh tools/dev.ps1 test-asan   # L2
```

MSVC の ASan に LeakSanitizer は含まれないので、リークはここでは出ない。
リーク検出は M3 の Linux レーンの担当である。

### 8. コミット

変更したパスを個別に stage する。`git add -A` と `git add .` はフックが拒否する。

## よくある取りこぼし

| 症状 | 原因 |
| --- | --- |
| `StatusCodeSyncTests` が赤い | `OCVU_STATUS_LIST` に足したが `CvStatus.cs` に足していない |
| リンクエラー（テストのみ） | 新規 `.cpp` を `OCVU_SOURCES` に足していない |
| L1 は緑だが L3 で `EntryPointNotFoundException` | ヘッダに宣言したが `.cpp` に定義がない、または名前が違う |
| L3 でスタックが壊れる | `CallingConvention.Cdecl` の付け忘れ、または型幅の不一致 |
| フックが例外バリアの囲い忘れを指摘する | `OCVU_TRY_BEGIN` / `OCVU_TRY_END` を書いていない |

## 参照

- `native/include/opencv_unity_native.h` — 公開 ABI と `OCVU_STATUS_LIST`
- `native/src/ocvu_error.h` — バリアのマクロと、囲ってはならない関数の一覧
- `docs/roadmap.md` — 対象マイルストーンのゴールと非ゴール
- `docs/unity-opencv-integration-research-and-plan.md` §6 — ABI 設計原則
