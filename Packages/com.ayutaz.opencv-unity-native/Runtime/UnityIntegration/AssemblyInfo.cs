using System.Runtime.CompilerServices;

// FillFlipped（RenderTextureConverter の internal）を検証本体（GPU に依らない
// 経路）から直接呼ぶための internal 公開。public にしないのは
// Runtime/Interop/AssemblyInfo.cs と同じ理由で、これは実装詳細であって
// 利用者向けの API ではない。
[assembly: InternalsVisibleTo("CvUnity.Tests.Shared")]
