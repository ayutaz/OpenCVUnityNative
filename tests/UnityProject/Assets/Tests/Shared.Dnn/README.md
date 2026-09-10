# CvUnity.Tests.Shared.Dnn

**dnn profile の到達性テストが入る場所。** `bindings/spec/dnn.json` が
`"profile": "dnn"` を宣言したので、生成器（`./tools/dev.ps1 generate`）が
`AbiReachabilityChecks.Dnn.g.cs`（`AbiReachabilityChecksDnn.CallEveryEntryPoint()`。
dnn の 4 entry を 1 回ずつ呼ぶ）をこの assembly の下に書き出している——
**もう空ではない。**

**ただし、生成された `CallEveryEntryPoint()` を実際に呼ぶ入口は、この
assembly の外にある**（`Shared` / `Shared.Dnn` はどちらも NUnit を参照しない
プレーンな C# ライブラリで、`[Test]` / `[UnityTest]` はここには置けない）。
呼び出しは `tests/UnityProject/Assets/Tests/PlayMode/AbiSurfaceDnnPlayerTests.cs`
（`#if OCVU_PROFILE_DNN` で自分を守る）が担う。**この 1 箇所が無いと、
IL2CPP の stripping が dnn の 4 宣言を消しても誰も気づけない**——レビューで
指摘され、追加した（詳細は同ファイルの docstring と `docs/roadmap.md` の
`### M7c の判定`）。

生成の仕組み自体は spec を書き換えて `./tools/dev.ps1 generate` を再実行すれば
自動で追従する（D8）。**手で書かない。**

`OCVU_PROFILE_DNN` が立っていなければ、この assembly はコンパイルされない
（`defineConstraints`）。**dnn の到達性テストが既定ビルドを壊さない**のは
この仕組みが実体である —— 到達性テストは `CvUnity.Interop.Dnn` の internal を
直接呼ぶので、`references` にそれを持つ。`CvUnity.Interop.Dnn` 自身も同じ define
で切られているので、両者は常に揃って現れるか、揃って消える。
