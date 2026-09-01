// このファイルは生成物である。手で編集しないこと。
// 正本: bindings/spec/objdetect.json
// 生成: ./tools/dev.ps1 generate

using System.Runtime.InteropServices;

namespace CvUnity.Interop
{
    internal static partial class NativeMethods
    {
        /// <summary>text を QR コードの画像に符号化して dst に入れる。dst の形状と型は結果に応じて上書きされ、8 bit 1 channel の正方形になる。text は NUL 終端の UTF-8 byte 列で、NULL と空文字列は拒否する。符号化できない長さの text は OCVU_STATUS_OPENCV_ERROR になる。失敗したときは dst を書き換えない。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_qr_encode(byte[] text, ulong dst);

        /// <summary>src に写っている QR コードを 1 つ検出して復号し、NUL 終端の UTF-8 byte 列として buffer へ書く。検出の前に白い余白（quiet zone）を必ず足し、短いほうの辺が 200 px 未満の画像はさらに最近傍補間で拡大してから検出する。復号後の長さは呼ぶ側に分からないので 2 回呼ぶ（1 回目は buffer に NULL を渡して out_required_size に NUL を含む必要バイト数を受け取る。そのとき返る OCVU_STATUS_BUFFER_TOO_SMALL は失敗ではない）。buffer の所有権は最初から最後まで呼ぶ側にあり、足りなければ何も書かない。QR が写っていなければ OCVU_STATUS_NOT_FOUND を返し、これは誤りではない。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_qr_decode(ulong src, byte[] buffer, int buffer_size, out int out_required_size);

        /// <summary>src に写っているチェスボードの内側の格子点を見つけて out_corners へ x と y が交互に並ぶ形で書き、書いた float の個数を out_count に返す。capacity は out_corners の float の個数であり、点の個数ではない（x と y の 2 つで 1 点なので、必要な float 数は pattern_cols * pattern_rows * 2 である）。呼ぶ側は必要量を事前に知り得るので 2 回呼ぶ必要は無い（capacity がそれに満たなければ何も書かずに OCVU_STATUS_BUFFER_TOO_SMALL を返し out_count に必要な float 数を入れる）。pattern_cols と pattern_rows はどちらも 2 以上でなければならず、その積が OCVU_CHESSBOARD_MAX_CORNERS を超える場合も OCVU_STATUS_INVALID_ARGUMENT を返す（int32 の乗算オーバーフローを避けるための歯止めであり、実用上のチェスボードパターンがこれを超えることは無い）。out_count が NULL なら OCVU_STATUS_NULL_POINTER を返す。capacity が正で out_corners が NULL なら OCVU_STATUS_NULL_POINTER、capacity が負なら OCVU_STATUS_INVALID_ARGUMENT を返す。これらいずれの失敗経路でも out_count には常に 0 を書く（BUFFER_TOO_SMALL のときだけ必要な float 数を書く）。格子が写っていなければ OCVU_STATUS_NOT_FOUND を返し、これは誤りではない。buffer の所有権は最初から最後まで呼ぶ側にある。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_find_chessboard_corners(ulong src, int pattern_cols, int pattern_rows, float[] out_corners, int capacity, out int out_count);

    }
}
