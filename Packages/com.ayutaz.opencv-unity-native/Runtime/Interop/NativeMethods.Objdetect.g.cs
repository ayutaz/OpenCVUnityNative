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

        /// <summary>src に写っているチェスボードの内側の格子点を見つけて out_corners へ x と y が交互に並ぶ形で書き、書いた float の個数を out_count に返す。capacity は out_corners の float の個数であり、点の個数ではない（x と y の 2 つで 1 点なので、必要な float 数は pattern_cols * pattern_rows * 2 である）。呼ぶ側は必要量を事前に知り得るので 2 回呼ぶ必要は無い（capacity がそれに満たなければ何も書かずに OCVU_STATUS_BUFFER_TOO_SMALL を返し out_count に必要な float 数を入れる）。pattern_cols と pattern_rows はどちらも 2 以上でなければならず、その積が OCVU_CHESSBOARD_MAX_CORNERS を超える場合も OCVU_STATUS_INVALID_ARGUMENT を返す（int32 の乗算オーバーフローを避けるための歯止めであり、実用上のチェスボードパターンがこれを超えることは無い）。out_count が NULL なら OCVU_STATUS_NULL_POINTER を返す。capacity が正で out_corners が NULL なら OCVU_STATUS_NULL_POINTER、capacity が負なら OCVU_STATUS_INVALID_ARGUMENT を返す。src が空なら OCVU_STATUS_INVALID_ARGUMENT を返す（現在の ABI では ocvu_mat_create が空の Mat を作れないので実際には到達しない防御である）。これらいずれの失敗経路でも out_count には常に 0 を書く（BUFFER_TOO_SMALL のときだけ必要な float 数を書く）。格子が写っていなければ OCVU_STATUS_NOT_FOUND を返し、これは誤りではない。buffer の所有権は最初から最後まで呼ぶ側にある。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_find_chessboard_corners(ulong src, int pattern_cols, int pattern_rows, float[] out_corners, int capacity, out int out_count);

        /// <summary>辞書とマーカー ID からマーカーの画像を生成して dst に入れる。dst は結果に応じて丸ごと置き換わり、side_pixels 四方の 8 bit 1 channel になる（作ったときの形と型は残らない）。dictionary_id は OCVU_ARUCO_DICT_* のいずれかで、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す —— cv::aruco には AprilTag 系の辞書もあるが、この plugin では検証していないので出していない。marker_id は 0 以上、その辞書が持つ個数未満でなければならない（DICT_4X4_50 なら 0 から 49 まで）。side_pixels は 1 以上 OCVU_ARUCO_MAX_MARKER_PIXELS 以下で、さらに「その辞書の格子の一辺 + border_bits の 2 倍」以上でなければならない（それより小さいと格子 1 つが 1 画素に満たない。これはこの ABI が自分で決めた制限であり、OpenCV の挙動を根拠にしていない）。border_bits は 1 以上で、マーカーの内側に置く黒い枠の太さ（格子単位）である —— 検出にはこの枠のさらに外側に白い余白が要るが、それを付けるのは呼ぶ側の仕事である。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。どの失敗経路でも dst は書き換えない。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_aruco_generate_marker(int dictionary_id, int marker_id, int side_pixels, int border_bits, ulong dst);

        /// <summary>src から ArUco マーカーを検出し、その ID を out_ids へ、4 隅の座標を out_corners へ書いて、見つかった個数を out_count に返す。src は 8 bit の 1 channel か 3 channel か 4 channel でなければならず、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す（3 channel と 4 channel はこの関数がグレースケールへ落としてから検出する —— Unity のテクスチャは 4 channel なので、呼ぶ側に変換を強いない）。dictionary_id は OCVU_ARUCO_DICT_* のいずれかで、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す。ids_capacity と corners_capacity はどちらも配列の要素数である（バイト数ではない）—— 1 マーカーにつき ID が 1 個、隅の座標が 8 個（x と y が交互に 4 隅ぶん）要るので、n 個を受けるには ids_capacity が n 以上、corners_capacity が n の 8 倍以上でなければならない。隅は OpenCV の detectMarkers が返す順、すなわち時計回りで、最初がマーカーの左上である。容量が足りないときはどちらの配列にも 1 バイトも書かずに OCVU_STATUS_BUFFER_TOO_SMALL を返し、out_count には実際に見つかった個数を入れる —— 容量 0 とポインタ NULL の組み合わせは「何個写っているか」を先に問い合わせる正規の呼び方で、そこで得た個数ぶん確保して呼び直せる。容量が正なのにポインタが NULL なら OCVU_STATUS_NULL_POINTER を返す。1 個も見つからないのは誤りではない —— OCVU_STATUS_OK を返して out_count に 0 を入れる。out_count が NULL なら他の何より先に OCVU_STATUS_NULL_POINTER を返し、通ったあとはどの失敗経路でも out_count に 0 を書く。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。buffer の所有権は最初から最後まで呼ぶ側にある。</summary>
        [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ocvu_aruco_detect_markers(ulong src, int dictionary_id, int[] out_ids, int ids_capacity, float[] out_corners, int corners_capacity, out int out_count);

    }
}
