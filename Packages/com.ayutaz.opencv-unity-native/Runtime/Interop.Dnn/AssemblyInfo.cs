using System.Runtime.CompilerServices;

// **到達性テストだけが例外である。** 理由は Runtime/Interop/AssemblyInfo.cs の
// 末尾にあるものと同じで、公開 API 経由では「どの entry point が呼ばれたか」を
// spec から機械的に導けない。**profile が変わっても、その理由は変わらない。**
//
// **新しい例外を作っているのではなく、既にある例外を同じ理由で profile 側にも
// 置いている。** Runtime/Interop/AssemblyInfo.cs の「Dnn には InternalsVisibleTo を
// 出さない」は CvUnity.Dnn / CvUnity.Runtime / CvUnity.Tests.Managed の 3 つに
// ついての決定であって、この 1 本は含まない。
[assembly: InternalsVisibleTo("CvUnity.Tests.Shared.Dnn")]
