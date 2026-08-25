using System;
using System.Collections.Generic;
using System.Linq;
using CvUnity;
using CvUnity.Interop;
using Xunit;

namespace CvUnity.Tests.Managed
{
    /// <summary>
    /// ネイティブの OCVU_STATUS_LIST と C# の <see cref="CvStatus"/> の同期を守る。
    ///
    /// 片方にだけ status を足すと (CvStatus)6 のような名前のない値が黙って通り、
    /// switch は default に落ちて、どのレーンも赤くならない。ここで止める。
    /// </summary>
    public class StatusCodeSyncTests
    {
        private static IReadOnlyList<int> ReadNativeStatusValues()
        {
            var count = NativeMethods.ocvu_get_status_count();
            Assert.InRange(count, 1, 4096);

            var values = new List<int>(count);
            for (var index = 0; index < count; index++)
            {
                int value;
                var status = NativeMethods.ocvu_get_status_value(index, out value);
                Assert.Equal((int)CvStatus.Ok, status);
                values.Add(value);
            }

            return values;
        }

        private static int[] ManagedStatusValues()
        {
            return Enum.GetValues(typeof(CvStatus)).Cast<CvStatus>()
                .Select(value => (int)value).ToArray();
        }

        [Fact]
        public void NativeAndManagedDeclareTheSameNumberOfStatusCodes()
        {
            var native = NativeMethods.ocvu_get_status_count();
            var managed = ManagedStatusValues().Length;

            Assert.True(
                native == managed,
                $"native declares {native} status codes but CvStatus declares {managed}. " +
                "Update OCVU_STATUS_LIST in native/include/opencv_unity_native.h and " +
                "CvStatus.cs together.");
        }

        [Fact]
        public void EveryNativeStatusHasANamedCvStatusMember()
        {
            foreach (var value in ReadNativeStatusValues())
            {
                Assert.True(
                    Enum.IsDefined(typeof(CvStatus), value),
                    $"native status code {value} has no CvStatus member. " +
                    "Add it to Packages/com.ayutaz.opencv-unity-native/Runtime/Core/CvStatus.cs.");
            }
        }

        [Fact]
        public void EveryCvStatusMemberIsDeclaredNatively()
        {
            var native = new HashSet<int>(ReadNativeStatusValues());

            foreach (var value in ManagedStatusValues())
            {
                Assert.True(
                    native.Contains(value),
                    $"CvStatus value {value} ({(CvStatus)value}) is not in the native " +
                    "OCVU_STATUS_LIST.");
            }
        }

        [Fact]
        public void NativeStatusValuesAreUnique()
        {
            var values = ReadNativeStatusValues();

            Assert.Equal(values.Count, values.Distinct().Count());
        }

        [Fact]
        public void StatusValueQueryRejectsOutOfRangeIndex()
        {
            int value;

            Assert.Equal(
                (int)CvStatus.InvalidArgument,
                NativeMethods.ocvu_get_status_value(-1, out value));
            Assert.Equal(
                (int)CvStatus.InvalidArgument,
                NativeMethods.ocvu_get_status_value(
                    NativeMethods.ocvu_get_status_count(), out value));
        }
    }
}
