# CvUnity.Interop.Dnn

**dnn profile の P/Invoke 宣言が入る場所。** いまは空である。

`OCVU_PROFILE_DNN` が立っていなければ、この assembly はコンパイルされない
（`defineConstraints`）。**それが「dnn が入らないビルドで参照が壊れない」の
実体である** —— 実行時に `EntryPointNotFoundException` が出るのではなく、
**参照するコードがビルドを通らない。**

中身は `bindings/spec/dnn.json` に `"profile": "dnn"` を書いて
`./tools/dev.ps1 generate` を実行すると生成される。**手で書かない。**
