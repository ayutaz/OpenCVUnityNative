"""tiny.onnx を生成するスクリプト。

**tiny.onnx は外から取ってきたモデルではなく、このスクリプトが作った。**
外部のモデルは (1) ライセンスの確認が要り、(2) リポジトリに数 MB が入り、
(3) 上流が消すと CI が壊れる。この 3 つを避けるため、`Identity` 1 ノードだけの
最小の ONNX を自分で作る。

`tiny.onnx` は binary なので中身が読めない。作り方をここに残していないと、
次に誰かが opset を上げたくなったときに作り直せない —— それがこのファイルが
モデルの隣に置いてある理由である。

実行方法（リポジトリ root から）:

    uv run --with onnx python tests/Managed/CvUnity.Tests.Managed/TestModels/tiny.onnx.py

**ライセンスの扱い**: このモデルは自作の合成物（重みも構造も無い恒等写像）
であり、第三者の権利が存在しないので THIRD_PARTY_NOTICES.md には何も
足していない。ライセンス表記が要るのは「よそから持ってきたもの」に対して
であって、自分で作ったものにはそもそも記載する third party が無い。
"""

import onnx
from onnx import helper, TensorProto

# 入力をそのまま返すだけのネットワーク。**推論の正しさは OpenCV の責任で、
# ここが確かめるのは「境界を通ったか」である。**
node = helper.make_node('Identity', ['input'], ['output'])
graph = helper.make_graph(
    [node], 'tiny',
    [helper.make_tensor_value_info('input',  TensorProto.FLOAT, [1, 3, 4, 4])],
    [helper.make_tensor_value_info('output', TensorProto.FLOAT, [1, 3, 4, 4])])
model = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 13)])
onnx.checker.check_model(model)

import os
out_path = os.path.join(os.path.dirname(__file__), 'tiny.onnx')
onnx.save(model, out_path)
print('bytes:', len(model.SerializeToString()), '->', out_path)
