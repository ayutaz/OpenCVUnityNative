using System.Runtime.CompilerServices;

// **到達性テストだけが例外である。** 理由は Runtime/Interop/AssemblyInfo.cs の
// 末尾にあるものと同じで、公開 API 経由では「どの entry point が呼ばれたか」を
// spec から機械的に導けない。**profile が変わっても、その理由は変わらない。**
[assembly: InternalsVisibleTo("CvUnity.Tests.Shared.Dnn")]

// **M7c Task 4 で、上を「唯一の例外」から「例外の 1 つ」に変えた。**
//
// Runtime/Interop の AssemblyInfo.cs が持つ 3 つの InternalsVisibleTo
// （CvUnity.Core / CvUnity.Tests.Managed / CvUnity.Runtime）を、同じ理由で
// Interop.Dnn 側にも用意する ―― CvUnity.Dnn（Runtime/Dnn/CvDnn.cs）が
// ocvu_net_handle を包む CvNet を実装するには NativeMethodsDnn を直接
// 呼ぶ必要があり、CvUnity.Interop.Dnn には「Core 層に相当するもの」が
// まだ無いので、公開 API 層自身に internal を見せる。
//
// public にはしない ―― P/Invoke 宣言は実装詳細であり、利用者向けの API では
// ない（Runtime/Interop/AssemblyInfo.cs と同じ方針）。
[assembly: InternalsVisibleTo("CvUnity.Dnn")]
[assembly: InternalsVisibleTo("CvUnity.Tests.Managed")]
[assembly: InternalsVisibleTo("CvUnity.Runtime")]

// 逆向き（Interop が Dnn を見る）は出さない。既定 profile が opt-in profile を
// 知っていたら、切り離せていない。
