using System.Runtime.CompilerServices;

// **CvUnity.Dnn（M7c Task 4）は CvMat.Handle を直接読む。**
//
// dnn の C ABI 関数（ocvu_dnn_blob_from_image / ocvu_dnn_net_forward）は
// ocvu_mat_handle を引数に取るので、CvUnity.Dnn の CvDnn はその値を CvMat から
// 取り出して NativeMethodsDnn に渡す必要がある —— CvCodecs や CvCalibration が
// 同じアセンブリの内側から Handle を読むのと同じ理由で、外側の別アセンブリに
// 対してもここで同じアクセスを開ける。
//
// public にはしない —— handle は実装詳細であり、利用者向けの API ではない
// （Runtime/Interop/AssemblyInfo.cs と同じ方針）。
[assembly: InternalsVisibleTo("CvUnity.Dnn")]
