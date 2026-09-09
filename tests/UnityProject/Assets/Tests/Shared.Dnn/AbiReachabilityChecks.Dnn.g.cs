// このファイルは生成物である。手で編集しないこと。
// 正本: bindings/spec/*.json
// 生成: ./tools/dev.ps1 generate
//
// **なぜ在るか。** IL2CPP の stripping は、呼ばれない P/Invoke 宣言を
// 消せる。M4 の点検では、手書きの 19 本のうち 7 本が Editor でも
// Player でも一度も呼ばれていなかった。**呼ばれない宣言は、消えても
// 誰も気づかない。** ここは spec が載せる宣言を 1 つ残らず 1 回ずつ
// 呼ぶ。結果は見ない —— 呼べたことだけを見る。
//
// 呼ばないのは spec が reachable: false と書いた関数だけで、
// 理由は spec の reachableNote にある（印だけ付けて理由が
// 無い spec は SpecModel が拒む）。

using CvUnity.Interop.Dnn;

public static class AbiReachabilityChecksDnn
{
    /// <summary>
    /// 呼んだ宣言の本数を返す。C の entry point 1 本に対して C# の宣言が
    /// 2 つある場合（byte[] 版とポインタ版）は 2 本と数える —— 消えるのは
    /// entry point ではなく宣言のほうだからである。
    /// </summary>
    public static int CallEveryEntryPoint()
    {
        NativeMethodsDnn.ocvu_dnn_net_read_onnx(null, 0, out _);
        NativeMethodsDnn.ocvu_dnn_net_release(0UL);
        NativeMethodsDnn.ocvu_dnn_blob_from_image(0UL, 0UL, 0.0, 0, 0, 0.0, 0.0, 0.0, 0, 0);
        NativeMethodsDnn.ocvu_dnn_net_forward(0UL, 0UL, 0UL);
        return 4;
    }
}
