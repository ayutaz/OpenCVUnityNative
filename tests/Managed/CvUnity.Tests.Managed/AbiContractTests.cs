using System;
using CvUnity;
using Xunit;

namespace CvUnity.Tests.Managed
{
    public class AbiContractTests
    {
        [Fact]
        public void AbiVersion_MatchesTheVersionThisPackageWasBuiltAgainst()
        {
            Assert.Equal(1, CvNative.AbiVersion);
        }

        [Fact]
        public void DebugThrow_StdException_ReturnsUnknownErrorInsteadOfCrashing()
        {
            var status = CvNative.DebugThrow(0);

            Assert.Equal((int)CvStatus.UnknownError, status);
            Assert.Equal(CvStatus.UnknownError, CvNative.GetLastErrorStatus());
            Assert.Contains("ocvu_debug_throw", CvNative.GetLastErrorMessage());
        }

        [Fact]
        public void DebugThrow_BadAlloc_MapsToOutOfMemory()
        {
            var status = CvNative.DebugThrow(1);

            Assert.Equal((int)CvStatus.OutOfMemory, status);
        }

        [Fact]
        public void DebugThrow_NonStandardException_IsStillContained()
        {
            var status = CvNative.DebugThrow(2);

            Assert.Equal((int)CvStatus.UnknownError, status);
            Assert.NotEmpty(CvNative.GetLastErrorMessage());
        }

        [Fact]
        public void DebugThrow_SuccessPath_ClearsPreviousError()
        {
            CvNative.DebugThrow(0);

            var status = CvNative.DebugThrow(3);

            Assert.Equal((int)CvStatus.Ok, status);
            Assert.Equal(CvStatus.Ok, CvNative.GetLastErrorStatus());
            Assert.Equal(string.Empty, CvNative.GetLastErrorMessage());
        }

        [Fact]
        public void ThrowIfFailed_ConvertsNonOkStatusIntoCvNativeException()
        {
            var status = CvNative.DebugThrow(0);

            var exception = Assert.Throws<CvNativeException>(
                () => CvNative.ThrowIfFailed(status));

            Assert.Equal(CvStatus.UnknownError, exception.Status);
            Assert.Contains("ocvu_debug_throw", exception.Message);
        }

        [Fact]
        public void ThrowIfFailed_DoesNothingOnOk()
        {
            CvNative.ThrowIfFailed((int)CvStatus.Ok);
        }

        [Fact]
        public void GetLastErrorMessage_RoundTripsUtf8WithoutTruncation()
        {
            CvNative.DebugThrow(0);

            var message = CvNative.GetLastErrorMessage();

            // NUL 終端が文字列に混入していないこと
            Assert.DoesNotContain('\0', message);
            Assert.EndsWith("std::runtime_error", message);
        }
    }
}
