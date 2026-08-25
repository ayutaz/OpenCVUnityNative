using System;

namespace CvUnity
{
    /// <summary>ネイティブ層が非 OK status を返したときに送出される。</summary>
    public class CvNativeException : Exception
    {
        public CvStatus Status { get; }

        public CvNativeException(CvStatus status, string message)
            : base(message)
        {
            Status = status;
        }
    }
}
