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
//
// **Runtime/Interop/AssemblyInfo.cs は「profile ごとに InternalsVisibleTo を
// 並べる」形を明示的に拒んでいる**（LibraryName は生成器が #if 分岐ごと
// 複製する形で答えた）。ここは逆に、profile（CvUnity.Dnn）を名指しで 1 つ
// 足しており、一見すると同じことを Core 側でやっているように見える。
//
// **正当化できるのは CvMat.Handle が LibraryName と違う種類の値だからである**
// —— LibraryName は文字列定数で、profile ごとに複製しても値は変わらないので
// 生成器による複製で足りた。対して Handle は生きた値（native 側の状態を
// 指す handle そのもの）で、複製のしようがない。この違いが無ければ、
// ここも Interop と同じく複製で答えるべきだった。
//
// **将来 profile が増えても、この行を Interop 側でやってよい理由にしない
// こと。** Interop 側で同じ形が要る事態が来たら、それは「複製できない
// 共通の何か」が新たに見つかったということであり、まず疑うべきは
// Interop 自体を切り出すこと（docs/abi-ownership-and-versioning.md §4）で、
// この Core の前例を根拠に InternalsVisibleTo を並べ始めることではない。
[assembly: InternalsVisibleTo("CvUnity.Dnn")]
