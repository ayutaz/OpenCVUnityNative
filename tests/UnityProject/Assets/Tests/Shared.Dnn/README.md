# CvUnity.Tests.Shared.Dnn

**dnn profile の到達性テストが入る場所。** いまは空である。

`bindings/spec/dnn.json` に `"profile": "dnn"` を書いて `./tools/dev.ps1 generate`
を実行すると、生成器がこの assembly の下に `AbiReachabilityChecks.g.cs`（の profile
別名）を書き出す（D8）。**手で書かない。**

`OCVU_PROFILE_DNN` が立っていなければ、この assembly はコンパイルされない
（`defineConstraints`）。**dnn の到達性テストが既定ビルドを壊さない**のは
この仕組みが実体である —— 到達性テストは `CvUnity.Interop.Dnn` の internal を
直接呼ぶので、`references` にそれを持つ。`CvUnity.Interop.Dnn` 自身も同じ define
で切られているので、両者は常に揃って現れるか、揃って消える。
