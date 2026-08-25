using System;
using CvUnity;
using CvUnity.Interop;
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

            Assert.Equal(CvStatus.UnknownError, status);
            Assert.Equal(CvStatus.UnknownError, CvNative.GetLastErrorStatus());
            Assert.Contains("ocvu_debug_throw", CvNative.GetLastErrorMessage());
        }

        [Fact]
        public void DebugThrow_BadAlloc_MapsToOutOfMemory()
        {
            var status = CvNative.DebugThrow(1);

            Assert.Equal(CvStatus.OutOfMemory, status);
        }

        [Fact]
        public void DebugThrow_NonStandardException_IsStillContained()
        {
            var status = CvNative.DebugThrow(2);

            Assert.Equal(CvStatus.UnknownError, status);
            Assert.NotEmpty(CvNative.GetLastErrorMessage());
        }

        [Fact]
        public void DebugThrow_SuccessPath_ClearsPreviousError()
        {
            CvNative.DebugThrow(0);

            var status = CvNative.DebugThrow(3);

            Assert.Equal(CvStatus.Ok, status);
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
            CvNative.ThrowIfFailed(CvStatus.Ok);
        }

        [Fact]
        public void SizeQuery_ReturnsBufferTooSmallRatherThanInvalidArgument()
        {
            CvNative.DebugThrow(0);

            int required;
            var status = (CvStatus)NativeMethods.ocvu_get_last_error_message(
                null, 0, out required);

            Assert.Equal(CvStatus.BufferTooSmall, status);
            Assert.True(required > 1, "required must include the message plus its NUL");
        }

        [Fact]
        public void UndersizedBuffer_ReturnsBufferTooSmallAndStillReportsRequiredSize()
        {
            CvNative.DebugThrow(0);

            int required;
            NativeMethods.ocvu_get_last_error_message(null, 0, out required);

            var tooSmall = new byte[required - 1];
            int reported;
            var status = (CvStatus)NativeMethods.ocvu_get_last_error_message(
                tooSmall, tooSmall.Length, out reported);

            Assert.Equal(CvStatus.BufferTooSmall, status);
            Assert.Equal(required, reported);
        }

        [Fact]
        public void BufferTooSmall_IsNotAFailure()
        {
            // サイズ問い合わせは正規の使い方なので、一律の例外変換に巻き込まれてはならない。
            // ここが失敗すると、文字列を返すすべての API が 2 回呼びのたびに例外を投げる。
            Assert.False(CvNative.IsFailure(CvStatus.BufferTooSmall));
            Assert.False(CvNative.IsFailure(CvStatus.Ok));
            Assert.True(CvNative.IsFailure(CvStatus.InvalidArgument));
            Assert.True(CvNative.IsFailure(CvStatus.NullPointer));

            CvNative.ThrowIfFailed(CvStatus.BufferTooSmall);
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
