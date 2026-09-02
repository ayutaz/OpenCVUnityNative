---
name: add-abi-function
description: Use when adding, changing, or removing a function in the ocvu_ C ABI - the TDD order across the binding spec, native implementation, L1 test and L3 test, plus the ownership, buffer and exception-barrier rules that the boundary must satisfy. Since M5 the C header and the C# P/Invoke are generated from bindings/spec, never written by hand. Triggers on work involving bindings/spec, dev.ps1 generate, native/include/ocvu, opencv_unity_native.h, native/src, NativeMethods, OCVU_TRY_BEGIN, ocvu_status, or any new ocvu_* entry point.
---

# C ABI 関数を追加する

ABI 関数を 1 本足す作業は 5〜7 ファイルにまたがる。順序を守らないと、実装が
先にできてしまいテストが後追いになるか、C# 側との対応が抜けたまま緑になる。

**この ABI が唯一の native contract である。** ここを通る型・所有権・エラーの
規約が、以降のすべての C# API と生成コードの形を決める。**M5 で generator が
実在するようになったので、これはもう予告ではない** —— spec に曖昧な契約を
書けば、C ヘッダ・C# の P/Invoke・到達性テスト・API 対応表の 4 箇所へ
同時に複製される。

## 先に決めること

コードを書く前に 3 つ答える。答えが出ないなら、まだ実装に入らない。

1. **所有権は誰にあるか。** 呼び出し側が確保したバッファに書くのか、native が
   確保して handle を返すのか。返す場合、解放する関数は何か。
   **呼び出し側が確保する場合、その大きさを呼び出し側が知り得るか。** 知り得ないなら
   2 回呼び（`BUFFER_TOO_SMALL` + `out_required_size`）にする —— 下の
   「出力の大きさを呼び出し側が知り得ないなら」を読む。
2. **失敗し得るか。** 失敗するなら `ocvu_status` を返す。失敗し得ないなら
   `int32_t` などを直接返してよいが、その根拠をコメントに書く。
3. **境界に出る型は固定サイズか。** `int32_t`、`uint64_t`、明示 struct、
   opaque handle のみ。`std::string`、`std::vector`、`cv::Mat` は出せない。

## M5 以降: 宣言は手で書かない

`bindings/spec/<module>.json` に 1 エントリ足して `./tools/dev.ps1 generate` を
実行する。**C ヘッダ・C# の P/Invoke・到達性テスト・API 対応表が同時に出る。**
**手で書いた宣言は `verify-generated` が落とす**（`dev.ps1 test` に入っている）。

手で書くのは**実装（`native/src/*.cpp`）と、意味のあるテスト（L1 / L3）だけ**である。
下の手順のうち「ヘッダに宣言する」（手順 2）と「C# 側の P/Invoke を足す」（手順 5）は、
**spec を書くことに置き換わる。** 残りはそのまま有効である。

**`wrapInTryBarrier` を spec に正しく書くこと。** 囲ってはならない関数の一覧は
`native/src/ocvu_error.h` にある —— `ocvu_get_last_error_*` は囲うと
報告すべきエラーを自分で消す。`false` にするなら `barrierNote` に理由を書く
（印だけ付けて理由が無い spec は生成器が拒む）。

**`reachable` も同じ形で決める。** 既定は `true` で、生成された到達性テストが
その宣言を 1 回呼ぶ。**呼べない関数だけ `false` にし、`reachableNote` に理由を書く**
（いまこれに当たるのは `ocvu_debug_crash` の 1 本だけである —— 呼ぶと戻ってこない）。
**`false` を選ぶのは最後の手段である**: IL2CPP の stripping が消せるのは
呼ばれない宣言なので、**呼ばない宣言は消えても誰も気づかない。**

**逆向きの検査が見ているのは `native/src/**/*.cpp` だけである。**
`tools/tests/BindingGenerator.Tests.ps1` は、そこにある
`extern "C"` の `ocvu_*` を全部拾って spec に無いものを落とす。
**他所に定義を置くと網に入らない** —— 「一覧を持つ場所」がこれで 1 つ増えた。
`native/src` の外に ABI の実装を置くなら、この検査の走査範囲も一緒に広げること。

### 生成物を増やすなら、先頭 5 行で名乗らせる

emitter を足して新しい生成物を出すときは、**その出力の先頭 5 行に
「このファイルは生成物である。手で編集しないこと。」を必ず含めること。**
既存の 4 つの emitter は全部そうしており、**2 つの機構がこの規約に乗っている**:

- `tools/tests/BindingGenerator.Tests.ps1` —— 「冒頭で生成物だと名乗るファイルが
  全部 `--list-outputs` の申告に載っているか」を見る。**名乗るのに申告されない
  ファイルがあれば落ちる**（配線が外れると、ファイルは名乗ったまま残り誰も
  再生成しなくなる）
- `.claude/hooks/check-generated-file-edit.sh` —— **編集した瞬間に指摘する。**
  一致は `verify-generated` も見るが、そちらが赤くなるのはずっと後で、
  そのとき手で書いた分は全部無駄になっている

**どちらも一覧を持たない。名乗りだけを見る。** 一覧にすると新しい生成物が
静かに漏れる —— M5 でその形を踏んだ（生成物 10 個のうち名指しで守られていたのは
2 個だけで、**到達性テストの配線を外しても検査は全部 PASS した**）。

**名乗らない生成物は、どちらの網にも入らない。** これが現在の限界である。

**もう 1 つ限界がある。** hook は速い経路として `.h` / `.cs` / `.md` を含む payload
だけを見る（`jq` の起動が 1 回 62 ms かかり、sh 本体の 0.19 秒に対して無視できない
ため）。**これは拡張子の一覧なので、別の拡張子の生成物を出すと、名乗っていても
黙って素通しする**（実測: 名乗る `.json` は捕まらない）。**新しい拡張子の生成物を
足すなら、`.claude/hooks/check-generated-file-edit.sh` の `case` にも足すこと。**
一覧が残るのはここだけで、**漏れる場所を 1 箇所に固定してある。**

## 手順

### 新しい OpenCV module を足すなら、先にリンクを実証する

**`cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` に足すだけでは、binary は
1 バイトも増えない。** 静的リンクは参照された object しか引かないので、
**「ビルドされている」と「リンクされている」は別**である（M3.5 の `imgcodecs` で
取り違え、M5 の module 追加で改めて実測した）。

したがって **`cv::` のシンボルを実際に参照する L1 テストだけが証拠になる。**
`native/tests/test_module_linkage.cpp` がその形で、`COMPONENTS` から外すと
`LNK2019` が出て戻すと通ることを確かめてある。

**`tools/opencv-config.psd1` の `Modules` を触るのは、それ自体が 1 つの作業である。**
あれは OpenCV 側が何をビルドするかで、変えると構成ハッシュが変わり 5 platform 分の
OpenCV を作り直す（実測: `calib` を足したとき `4785d98e9aad` → `09fcbe260d87`）。
**`COMPONENTS` を変えてもハッシュは変わらない** —— ハッシュを算出する
`Get-OpenCvConfigHash` が読むのは `psd1` だけである。

**`Modules` を足したら、同じ commit で次も動く**（2026-09-02 に `calib` で実測）:

- **`tools/verify-opencv-artifact.ps1` の `$AcceptedTransitiveModules`** ——
  新しい module が別の module を推移的に引き込むと、依存 allowlist が拒否する。
  `calib` は `stereo` を引き、**4 platform とも最初のビルドがここで落ちた。**
  **これは検査が働いた例であって、回避すべき障害ではない** —— 引き込まれたものを
  確かめてから明示的に足す。
- **`THIRD_PARTY_NOTICES.md` の module 列挙**（配布物に同梱される法的通知文書）
- **`README.md` の「which OpenCV modules this plugin links」**
- **`tools/tests/OpenCvConfig.Tests.ps1` の module 検査**（spec と両方向に突き合わせる）
- **module 一覧を散文で持っている文書** —— `docs/roadmap.md` の M7 節、
  `docs/unity-opencv-integration-research-and-plan.md` の競合比較表、
  `CLAUDE.md` の `opencv-config.psd1` の行。**この 3 つは 2026-09-02 に
  実際に取りこぼし、レビューで指摘されて直した** —— 上の 4 つと違って
  「module 一覧」という語で grep できないので、**目で探すしかない。**

**テストが module 名を写していると、CI に投げるまで分からないことがある。**
`tools/tests/VerifyOpenCvArtifact.Tests.ps1` は合成ツリーの中身を
リテラルで**持っていた**（いまは正本から作る）。`calib` を足した瞬間に
2 platform が落ちた
（2026-09-02 に実測）。**このレーンは `test-tools-slow`（CI 専用）にあり、
ローカルの `dev.ps1 test` では走らない。**

**直し方は「正本から読む」ではなく「結果を見る」だった。** 一覧を正規表現で
読む形にしたが、**取り落としても緑のまま通った** ——
`@('a', 'b') + @('c')` のように連結で書かれると 1 つ落とすのに、
その module は必須ではないのでテストは通る。**落ちない読み取りは、
読んでいないのと同じである。** いまは合成ツリーを `config.Modules` だけで作り、
推移的依存は「許可されるか」という**結果**を 1 つ名指しで見ている
（許可リストから外すと実際に落ちる。実測済み）。

**新しい module が推移的に引かれるかは、足す前に測れる。** `COMPONENTS` に足す前に
その module の関数を呼ぶ L1 テストを書き、**リンクが落ちるかを見る。**
`geometry` は落ちなかった（`features` / `objdetect` の依存として既に引かれていた）が、
`calib` は `LNK2019` で落ちた —— **どちらかは推測できないので、実際に走らせる。**

**関数を書いた後の binary の大きさを測って記録する。** roadmap は module を足すとき
同時に動く 5 つの 1 つに成果物の大きさを挙げており、`docs/abi-ownership-and-versioning.md`
の §3.5 / §3.6 に前例がある。**M5 の module 追加では 10,177,536 → 20,136,960 バイトで
約 2 倍になった**（Windows の debug）。

**`cv::Exception` は個別に受ける。** `OCVU_TRY_END` は `std::exception` を
`OCVU_STATUS_UNKNOWN_ERROR` にするので、そこへ落とすと **OpenCV 由来の失敗が
「原因不明」として報告される**。`native/src/ocvu_imgcodecs.cpp` が確立済みの形で、
M5 の 3 本もそれに揃えてある。**spec の `summary` が `OPENCV_ERROR` を約束しているなら、
それを実証する L1 テストも書くこと** —— 約束だけして実装が返さない状態は、
ビルドも既存テストも緑のまま隠れる。

**module 名が既存の生成物のファイル名を部分文字列として含まないか見る。**
`tools/tests/BindingGenerator.Tests.ps1` の「申告された出力が `verify-generated`
の報告に出るか」は**部分一致**で照合しているので、**leaf 名どうしに包含関係が
生まれた瞬間に空振りする。** いま安全なのは偶然である ——
`objdetect.h` は **`detect.h` を含み**、`imgproc.h` は `proc.h` を含む。
**`detect` はこの分野でごく自然な module 名なので、絵空事ではない** ——
足した日に、`detect.h` が報告に出ていなくても `objdetect.h` が満たしてしまう。
**その日に気づけるよう、ここに書いてある。**

### 1. 失敗する L1 テストを先に書く

`native/tests/test_*.cpp` に、これから作る関数の契約をテストとして書く。
既存のテストファイルに足すか、新規なら `native/tests/CMakeLists.txt` の
`ocvu_tests` のソース一覧にも追加する。

```
pwsh tools/dev.ps1 test-native
```

**RED を目で確認する。** 未定義シンボルでも、コンパイルエラーでもよい。
落ちない場合はテストが契約を検査していない。

### 2. spec に 1 エントリ足して生成する

**ヘッダを手で編集しない**（M5 以降。上の節を参照）。
`bindings/spec/<module>.json` の `functions` に 1 エントリ足し、
`./tools/dev.ps1 generate` を実行する。

エントリの `summary` には最低限これを書く。**これが C ヘッダの doc コメント・
C# の XML doc・API 対応表の「内容」列に同時に出る** —— 3 箇所に別々に書かない:

- 引数の意味と、NULL を許すかどうか
- 出力バッファがあるなら、必要サイズの求め方と NUL の扱い
- 所有権（呼び出し側が解放するのか、native が解放するのか）
- 失敗し得る status code

**`summary` は 1 行で書く。** 改行を入れると生成物が壊れるので、
`schema.json` の `pattern` が弾く。**その pattern は「一致したか」ではなく
「値の全体を覆ったか」で判定している** —— .NET の `$` は末尾の `\n` の
直前にも当たるので、`Regex.IsMatch` だけでは末尾の改行を通してしまう
（`prove-a-check-works` skill に実例がある）。

**module ごとにファイルが分かれている。** 既存の 6 つ（`infra` / `core` /
`imgproc` / `imgcodecs` / `objdetect` / `features`）のどれにも入らないなら新しい
`<module>.json` を作る —— そのとき生成されるヘッダも `native/include/ocvu/<module>.h`
として増え、`native/include/opencv_unity_native.h` の `#include` 一覧に手で 1 行足す
必要がある（**その 1 行だけは生成物ではない**）。

**生成される C# のファイル名は module 名が大文字である**（`NativeMethods.Objdetect.g.cs`）。
Windows は大文字小文字を区別しないので小文字で `git add` しても通ってしまうが、
実物は大文字である。**`.meta` は生成器が作らない**ので、既存のもの（60 バイト、
1 行目のみ CRLF、末尾改行なし）と同じ形で手で作り、guid がリポジトリ内で一意で
あることを確かめる。

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

**シグネチャは `extern "C" ocvu_status ocvu_名前(` までを 1 物理行に置く。**
`.claude/hooks/check-exception-barrier.sh` の awk は、戻り値・関数名・`(` が同じ行に
あることを前提に関数を認識する。戻り値と名前の間で折り返すと関数だと認識できないので、
hook は「シグネチャが折り返されていて認識できません」と指摘する（**囲ってあっても
指摘する** —— 黙って素通しにすると、出力が「囲われている」場合と区別できず、
指摘が出ないことが証拠にならなくなるためである）。引数側の改行は問題ない。
ヘッダの宣言は対象外なので、そちらは折り返してよい。

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

**引数に handle があるなら（M2 で確立した規約）**

`ocvu_mat_handle` のような opaque handle を引数に取る関数は、生ポインタを
直接受け取ってはならない。代わりに `native/src/ocvu_mat_table.h` の table 経由で
解決する:

1. `ocvu::mat_table_get(handle)` で `cv::Mat*` を得る。
2. 戻り値が `nullptr` なら `OCVU_STATUS_INVALID_HANDLE` を返す。handle が
   `0`（`OCVU_MAT_HANDLE_NONE`）、解放済み（世代が合わない）、未知の索引の
   いずれでも同じ status になる — 呼び出し側は理由を区別できないし、区別する
   必要も無い。
3. 得たポインタは呼び出しの内側でだけ使う。**保持しない。** 同じスレッドで
   別の呼び出しが `release` すると無効になる。

新しい種類の handle（Mat 以外）を足す場合も、この「世代番号つき table」の形を
再利用する。生ポインタを handle にすると、解放後の再利用が未定義動作になり、
sanitizer の無い環境（配布された Unity Player）では黙って壊れる
（`docs/abi-ownership-and-versioning.md` §1、`native/src/ocvu_mat_table.h` の
doc コメント）。

**引数に buffer があるなら（M2 で確立した規約）**

`(const uint8_t* data, int64_t length, int64_t stride)` の形を取る関数は、
**書く前にすべて検証し、1 つでも合わなければ何も書かずに返す。** 検証の順序:

1. ポインタが NULL → `OCVU_STATUS_NULL_POINTER`
2. handle が無効 → `OCVU_STATUS_INVALID_HANDLE`
3. `length` / `stride` が負 → `OCVU_STATUS_INVALID_ARGUMENT`
4. `stride` が Mat の 1 行のバイト数未満 → `OCVU_STATUS_INVALID_ARGUMENT`
5. buffer が `stride * rows` 分の長さを持たない → `OCVU_STATUS_INVALID_ARGUMENT`
   **ただし `stride * rows` を計算してはならない。** `stride` は呼び出し側が決める
   `int64_t` なので積が桁あふれし、負に反転して検査を素通りする。実際に M2 で
   これが起き、`stride = 2^62` でアクセス違反によりプロセスが即死した。
   `stride > length / rows` の形で比べること（除算なら桁あふれしない）。

コピーは行ごとに行う。Mat の `step` と外部 buffer の `stride` は一致しないことが
ある（Unity のテクスチャは行が整列されている場合がある）ので、一括 `memcpy` は
誤り得る。参照実装は `native/src/ocvu_mat_buffer.cpp` の `validate()`。

この検証を省略・弱めると、Unity のヒープを踏み越える誤りが「即座には落ちず、
後から無関係な場所が壊れる」形になる。Windows の ASan は Unity のアロケータを
見られないので CI でも検出できない（`docs/abi-ownership-and-versioning.md` §1）。
検証を足したり変えたりしたら、`prove-a-check-works` skill の手順で、境界条件を
1 つ緩めてテストが実際に赤くなることを確認してから戻すこと。

**出力の大きさを呼び出し側が知り得ないなら（M3.5 で確立した規約）**

上の buffer 規約は、**大きさを呼ぶ側が知っている**ことを前提にしている（画像の行は
`rows` と `stride` で決まる）。符号化した画像のように**呼んでみるまで大きさが決まらない**
出力はこの形に乗らない。その場合は
`(uint8_t* buffer, int32_t buffer_size, int32_t* out_required_size)` の **2 回呼び**に
する。参照実装は `native/src/ocvu_imgcodecs.cpp` の `ocvu_imencode`。

1 回目は `buffer = NULL` / `buffer_size = 0` で呼び、`out_required_size` に必要
バイト数を受け取る。戻り値は `OCVU_STATUS_BUFFER_TOO_SMALL` で、**これは失敗では
なく問い合わせの正常な答えである。** 2 回目にその大きさの buffer を渡す。
`ocvu_get_last_error_message` と `ocvu_get_opencv_version` が既に同じ形をしているので、
新しい idiom ではない。

**native が確保した blob を handle で返す形は採らない。**
`docs/abi-ownership-and-versioning.md` §1 が持つ所有権は「native 所有の handle」と
「呼び出しの内側で完結する借用」の 2 種類だけである。そこへ「native が確保して呼ぶ側が
別の関数で解放する blob」を足すと、解放し忘れと二重解放という壊れ方が 1 種類増える。
**出力の所有権は最初から最後まで呼ぶ側にある。**

検証の順序（`native/src/ocvu_imgcodecs.cpp` の `ocvu_imencode`）:

1. `out_required_size` が NULL → `OCVU_STATUS_NULL_POINTER`。**これを最初に見る。**
   無いと呼ぶ側は 2 回目の大きさを決められないので、他のどの引数より先に断る
2. 通ったら**何よりも先に `*out_required_size = 0` を書く。** どの経路で返っても、
   呼ぶ側が読む値が未初期化のままにならないようにする
3. 他の入力（`ext` の NULL・空文字列など）→ `NULL_POINTER` / `INVALID_ARGUMENT`
4. `buffer_size` が負 → `OCVU_STATUS_INVALID_ARGUMENT`
5. `buffer_size > 0` なのに `buffer` が NULL → `OCVU_STATUS_NULL_POINTER`。
   **`buffer == NULL` かつ `buffer_size == 0` は正常な問い合わせなので通す。**
   「buffer が NULL なら常に拒否」と書くと 1 回目が呼べなくなる
6. handle が無効 → `OCVU_STATUS_INVALID_HANDLE`
7. 生成した結果が `INT32_MAX` を超える → `OCVU_STATUS_INVALID_ARGUMENT`。
   `int32_t` に入らない大きさは ABI で表現できないので、切り詰めずに断る
8. `buffer_size < needed` → `*out_required_size` に必要量を入れてから
   `OCVU_STATUS_BUFFER_TOO_SMALL` を返す。**buffer には 1 バイトも書かない。**
   部分的に書くと、呼ぶ側は途中まで正しい buffer を掴むことになり、壊れ方が
   「その場では気づけない」形になる

**どの失敗でも `*out_required_size` に 0 を書く。** NULL 判定の直後に 0 を入れ、
以降のすべての早期 return がその後ろに来るようにする。呼ぶ側は同じ変数を
使い回すので、**書かないと「失敗したのに前回のサイズが残る」**。その値を信じて
確保する経路ができ、次の呼び出しが偶然通ってしまう。

**この規則は、テストが 0 で初期化していると確かめられない。** 「書いていない」と
「0 を書いた」が区別できないためである。M3.5 では代入を消しても L1・L3 の
16 件が緑のまま通った。**わざと汚してから呼ぶ**こと:

```cpp
int32_t needed = 12345;                 // 0 ではない値で汚す
EXPECT_EQ(ocvu_imencode(src, nullptr, nullptr, 0, &needed), OCVU_STATUS_NULL_POINTER);
EXPECT_EQ(needed, 0) << "失敗時は 0 を書くこと";
```

代入を消して**落ちること**を確認する。M3.5 の実測では **L1 が 2 件落ちた**
（`Imgcodecs.EncodeRejectsInvalidArguments` と `EncodeRejectsUnknownExtension`。
その中の assertion は 7 つ）。**L3 は 44/44 のまま通った** —— L3 は失敗経路で
status しか見ていないからで、**この規則を守らせているのは L1 だけである。**

**L1 には境界を必ず入れる。** `buffer_size = needed - 1` で呼び、`BUFFER_TOO_SMALL`
が返ること、かつ **buffer が呼び出し前と 1 バイトも変わっていないこと**を見る
（`native/tests/test_imgcodecs.cpp` の `EncodeRejectsTooSmallBufferWithoutWriting`。
0xAB で埋めて全バイトを照合している）。「何も書かない」は、書かれていないことを
見る検査でしか確かめられない。

**C# 側は 2 回呼びを隠す**（`Runtime/Core/CvCodecs.cs` の `Encode`）。1 回目の
`BufferTooSmall` **だけ**を通し、**それ以外の status はそこで投げる** —— 無効な
handle も扱えない拡張子もサイズ問い合わせの段で判明するので、空配列を返して呼ぶ側に
気づかせない形にしない。1 回目が `OK` を返すのも契約違反なので、そこも例外にする
（0 バイトの出力は「成功」ではない）。返す配列は必要量ちょうどの長さにし、大きめに
確保した buffer をそのまま返さない。

**文字列引数は UTF-8 の NUL 終端 byte 列として自分で渡す。** `ext` のような引数を
`string` のまま marshaller に任せると、境界の文字コード変換が既定の CharSet に
依存する（Mono と IL2CPP で違い得る）。C# 側で `Encoding.UTF8` して NUL を足し、
`byte[]` として渡す（`CvCodecs` の `ToNulTerminatedUtf8`）。

**ファイルパスを ABI に出さない。** `ocvu_imencode` / `ocvu_imdecode` が受けるのは
メモリ上の byte 列だけである。理由は 2 つある: (a) Windows ではパスの文字コードが
呼ぶ側のコードページに依存する、(b) Android の StreamingAssets は APK の中にあり、
そもそもパスでは開けない。ファイルを開くのは呼ぶ側（C# の `File.ReadAllBytes`、
`UnityWebRequest`）の仕事にする。**この 2 本を「画像ファイルの読み書き」と説明しない。**

**新しいモジュールの公開 API は新しいクラスに置く。** `CvOps` は imgproc に範囲を
限っているので、imgcodecs は `CvCodecs` という別クラスにした。1 つのクラスに全
モジュールを詰めると、この plugin がどの OpenCV モジュールをリンクしているかが
C# 側から読み取れなくなる。

### 4. L1 を緑にする

```
pwsh tools/dev.ps1 test-native
```

### 5. C# 側の P/Invoke —— **手順 2 で既に出ている**

`NativeMethods.<module>.g.cs` に `[DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]`
付きで生成済みである。**`NativeMethods.cs` に手で足さないこと** —— そこに残すのは
`LibraryName` と、spec が表現しない型（`OcvuMatInfo` のような struct）だけである。

**C の entry point 1 本に C# の入口を 2 つ出したいとき**（`byte[]` 版と `IntPtr` 版など）は、
spec に**もう 1 エントリ**書いて `entryPoint` に元の C の名前を指す。**C ヘッダには
出ない**（C 側の宣言は 1 本のまま）が、C# の宣言と到達性テストは 2 本になる。
参照は `ocvu_mat_copy_from_buffer_ptr` / `ocvu_mat_copy_to_buffer_ptr`。

公開 API を出すなら `Runtime/Core/` に薄いラッパを書く。**こちらは生成しない。****この 2 フォルダは
`UnityEngine` を参照してはならない。** 参照した瞬間に netstandard2.1 shim の
ビルドが落ち、Unity を起動しない L3 レーンが失われる。
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
pwsh tools/dev.ps1 test        # tools の速いテスト + L1 + L3（所要時間は CLAUDE.md の表）
```

**メモリを触る関数を足したなら ASan まで回す:**

```
pwsh tools/dev.ps1 test-asan   # L2
```

MSVC の ASan に LeakSanitizer は含まれないので、リークはここでは出ない。
リーク検出は `ci-sanitizers.yml` の Linux ASan+LSan job だけが担う。ローカルでも
Windows の CI でも出ないので、**リークするコードは PR を出すまで緑に見える。**

### 8. コミット

変更したパスを個別に stage する。`git add -A` と `git add .` はフックが拒否する。

**生成物も一緒にコミットする。** `native/include/ocvu/*.h`、
`Runtime/Interop/NativeMethods.<module>.g.cs`（**`.meta` も**）、
`tests/UnityProject/Assets/Tests/Shared/AbiReachabilityChecks.g.cs`、
`docs/api-map.md` は git が追跡している。spec だけ入れて生成物を入れないと、
**CI の `dev.ps1 test` が全 platform で落ちる。**

## よくある取りこぼし

| 症状 | 原因 |
| --- | --- |
| `StatusCodeSyncTests` が赤い | `OCVU_STATUS_LIST` に足したが `CvStatus.cs` に足していない |
| リンクエラー（テストのみ） | 新規 `.cpp` を `OCVU_SOURCES` に足していない |
| L1 は緑だが L3 で `EntryPointNotFoundException` | spec に書いて生成したが `.cpp` に定義がない、または名前が違う |
| `dev.ps1 test` が「生成物が spec と食い違っています」で落ちる | spec を直して `dev.ps1 generate` を実行していない（生成物をコミットするところまでが 1 手である）か、生成物を手で編集した |
| `BindingGenerator.Tests.ps1` の「every extern C ocvu_* in native/src is declared in the spec」が落ちる | 実装だけ書いて spec に書いていない。**逆向きの網はここだけが持つ** |
| spec を書いたのに生成器が受け付けない | `wrapInTryBarrier: false` に `barrierNote` が無い / `reachable: false` に `reachableNote` が無い / `summary` に改行が入っている / `schema.json` の enum に無い型を書いた |
| L3 でスタックが壊れる | `CallingConvention.Cdecl` の付け忘れ、または型幅の不一致 |
| フックが例外バリアの囲い忘れを指摘する | `OCVU_TRY_BEGIN` / `OCVU_TRY_END` を書いていない |
| `cv::` の関数だけがリンクエラー（`LNK2019` / undefined reference） | そのモジュールが `cmake/FindOpenCvUnityDeps.cmake` の `COMPONENTS` に無い。**「OpenCV がそのモジュールを含んでビルドされている」と「この plugin がそれをリンクしている」は別である** —— `tools/opencv-config.psd1` の `Modules` に載っていれば OpenCV 側は当然ビルドされ、`ocvu_get_build_information()` も `To be built:` にその名前を出す。それを根拠にすると誤る（M3.5 の `imgcodecs` がこれで、リンカが `cv::imencode` / `cv::imdecode` を未解決にして初めて分かった） |
| ヘッダの `#define` が OpenCV の定数とずれる | `static_assert` で固定していない。`OCVU_IMREAD_*` のように OpenCV の値をそのまま出す定数は、実装 `.cpp` の先頭に `static_assert(OCVU_X == cv::X, "...")` を書き、写し間違いをコンパイル時に落とす（`native/src/ocvu_imgcodecs.cpp`、`native/src/ocvu_imgproc.cpp`） |

| クロスビルドだけリンクエラー / 挙動が違う | 対象 platform が host と一致しないことを忘れている。`dev.ps1 build` は既定で**実行中の OS 向け**にビルドするので、モバイルは `-Platform android-arm64` のように明示する（M4 で host から切り離した）。`OCVU_BUILD_TESTS` はクロスの preset で `OFF` —— **クロスビルドした GoogleTest は host で実行できない**ので、L1 の代わりは実機の smoke test である（`docs/m4-device-verification.md`） |
| iOS で `DllNotFoundException` / シンボルが見つからない | iOS はアプリの外から共有ライブラリを読み込めない。`native/CMakeLists.txt` は `CMAKE_SYSTEM_NAME STREQUAL "iOS"` のとき **`STATIC`** を作り、Unity が IL2CPP のバイナリへ静的リンクして `DllImport("__Internal")` で解決する。**`SHARED` のままでもビルドは成功する**ので、Unity に入れて初めて壊れる |

## platform を足すとき

**`add-a-platform` skill を使うこと。** ABI 関数の話ではないが、同じファイル群を
触るのでここから指す。

直す場所は **17 箇所**あり（M4 で実測）、`.meta` のキー名・ファイル名の衝突・
クロスでの `find_package` の閉じ込め・静的ライブラリの依存の束ねなど、
**ビルドが通ってから CI で 8 回落ちた**罠がそこにまとまっている。

## 参照

- `bindings/spec/*.json` — **宣言の正本（M5）。** ここに 1 エントリ書くのが関数を足す唯一の経路
- `bindings/spec/schema.json` — spec の形を縛る。読めない enum / pattern があれば `SpecModel` が**素通りせず落ちる**
- `native/include/opencv_unity_native.h` — 型・定数・`OCVU_STATUS_LIST`。**関数宣言はもう無い**（`ocvu/*.h` を include する）
- `native/include/ocvu/*.h` — module ごとの `extern "C"` 宣言（**生成物**）
- `tools/tests/BindingGenerator.Tests.ps1` — 生成物と spec の一致、および**実装 → spec の逆向き**を見る
- `native/src/ocvu_error.h` — バリアのマクロと、囲ってはならない関数の一覧
- `native/src/ocvu_mat_table.h` / `.cpp` — 世代番号つき handle table の参照実装
- `native/src/ocvu_mat_buffer.cpp` — buffer 引数の検証順序の参照実装（`validate()`）
- `native/src/ocvu_imgcodecs.cpp` — 出力の大きさが事前に分からないときの 2 回呼びの参照実装（M3.5）
- `cmake/FindOpenCvUnityDeps.cmake` — **この plugin が**リンクする OpenCV モジュールの `COMPONENTS`。新しいモジュールの関数を出すならここも変える
- `docs/abi-ownership-and-versioning.md` — handle と buffer の所有権契約の正本（M2 で確定）
- `docs/roadmap.md` — 対象マイルストーンのゴールと非ゴール
- `docs/unity-opencv-integration-research-and-plan.md` §6 — ABI 設計原則
