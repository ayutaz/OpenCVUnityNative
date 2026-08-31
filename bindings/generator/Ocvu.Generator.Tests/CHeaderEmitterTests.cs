using System;
using Xunit;

namespace Ocvu.Generator.Tests;

public class CHeaderEmitterTests
{
    private static ModuleSpec Sample() => new(
        Module: "sample",
        Functions: new[]
        {
            new FunctionSpec("ocvu_sample_do", "何かする。", "ocvu_status", "int", true,
                new[]
                {
                    new ParamSpec("handle", "ocvu_mat_handle", "ulong", "in"),
                    new ParamSpec("outValue", "int32_t*", "out int", "out"),
                }),
        });

    [Fact]
    public void EmitsTheDeclaration()
    {
        Assert.Contains(
            "OCVU_API ocvu_status ocvu_sample_do(ocvu_mat_handle handle, int32_t* outValue);",
            CHeaderEmitter.Emit(Sample()));
    }

    // 引数が無い関数は (void) にする。() は C では「引数不定」という別の意味になる。
    [Fact]
    public void NoParametersBecomesVoid()
    {
        var spec = new ModuleSpec("sample", new[]
        {
            new FunctionSpec("ocvu_sample_none", "何もしない。", "int32_t", "int", false,
                Array.Empty<ParamSpec>()),
        });
        Assert.Contains("OCVU_API int32_t ocvu_sample_none(void);", CHeaderEmitter.Emit(spec));
    }

    // **include guard が module ごとに違うこと。** 同じなら 2 つ目が丸ごと消える。
    [Fact]
    public void GuardIsPerModule()
    {
        Assert.Contains("#ifndef OCVU_SAMPLE_H", CHeaderEmitter.Emit(Sample()));
    }

    // **生成物であることが読んで分かること。** 手で直されると spec が正本でなくなる。
    [Fact]
    public void SaysItIsGenerated()
    {
        var text = CHeaderEmitter.Emit(Sample());
        Assert.Contains("このファイルは生成物である", text);
        Assert.Contains("bindings/spec/sample.json", text);
    }

    // **summary が落ちないこと。** 落ちると生成物のほうが情報量で負ける。
    [Fact]
    public void CarriesTheSummary()
    {
        Assert.Contains("何かする。", CHeaderEmitter.Emit(Sample()));
    }

    // **囲わない理由を書き出すこと。** 実装をレビューする人が最初に読む場所である。
    [Fact]
    public void CarriesTheBarrierNote()
    {
        var spec = new ModuleSpec("sample", new[]
        {
            new FunctionSpec("ocvu_sample_raw", "囲わない。", "ocvu_status", "int", false,
                Array.Empty<ParamSpec>(), BarrierNote: "自分でエラーを消してしまうため"),
        });
        Assert.Contains("例外バリアで囲まない: 自分でエラーを消してしまうため",
                        CHeaderEmitter.Emit(spec));
    }

    // **C 側の宣言は 1 本である。** entryPoint を持つものは C# 側の別 overload
    // （byte[] 版と IntPtr 版）を表すために spec に 2 エントリある。C ヘッダに
    // そのまま出すと同じ関数を 2 度宣言することになり、しかも型が違えば
    // 「異なる型での再宣言」でコンパイルが落ちる。
    [Fact]
    public void OverloadsThatShareAnEntryPointAreNotDeclaredTwice()
    {
        var spec = new ModuleSpec("sample", new[]
        {
            new FunctionSpec("ocvu_sample_do", "本体。", "ocvu_status", "int", true,
                Array.Empty<ParamSpec>()),
            new FunctionSpec("ocvu_sample_do_ptr", "ポインタ版。", "ocvu_status", "int", true,
                Array.Empty<ParamSpec>(), BarrierNote: null, EntryPoint: "ocvu_sample_do"),
        });
        var text = CHeaderEmitter.Emit(spec);
        Assert.Contains("ocvu_sample_do(void);", text);
        Assert.DoesNotContain("ocvu_sample_do_ptr", text);
    }
}
