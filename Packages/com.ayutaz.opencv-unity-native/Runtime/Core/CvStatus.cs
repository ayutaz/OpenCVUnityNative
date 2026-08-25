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
    }
}
