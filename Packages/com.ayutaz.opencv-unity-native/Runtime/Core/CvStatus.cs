namespace CvUnity
{
    /// <summary>
    /// ネイティブ C ABI が返す status code。
    /// ネイティブ側の唯一の定義元は native/include/opencv_unity_native.h の
    /// OCVU_STATUS_LIST。片方だけに追加すると L3 の StatusCodeSyncTests が赤になる。
    /// </summary>
    public enum CvStatus
    {
        Ok = 0,
        InvalidArgument = 1,
        NullPointer = 2,
        OutOfMemory = 3,
        OpenCvError = 4,
        UnknownError = 5,

        /// <summary>
        /// 出力バッファが必要量に満たない。**失敗ではなく、必要サイズを
        /// 問い合わせる正規の使い方の結果である。** buffer に null を渡して
        /// サイズだけを聞き、返った大きさで確保して呼び直す。
        /// status を一律に例外へ変換する経路で、これを失敗として扱わないこと。
        /// </summary>
        BufferTooSmall = 6,

        /// <summary>
        /// handle が未知か、解放済みである。生ポインタではなく世代番号つきの
        /// table 索引にしていることの帰結として観測できる status
        /// （docs/abi-ownership-and-versioning.md §1）。
        /// </summary>
        InvalidHandle = 7,
    }
}
