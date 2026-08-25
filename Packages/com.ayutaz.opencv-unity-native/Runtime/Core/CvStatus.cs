namespace CvUnity
{
    /// <summary>ネイティブ C ABI が返す status code。</summary>
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
