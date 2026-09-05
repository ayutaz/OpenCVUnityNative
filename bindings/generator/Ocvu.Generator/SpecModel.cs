using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Ocvu.Generator;

public sealed class SpecFormatException : Exception
{
    public SpecFormatException(string message) : base(message) { }
}

public sealed record ParamSpec(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("cType")] string CType,
    [property: JsonPropertyName("csType")] string CsType,
    [property: JsonPropertyName("direction")] string Direction);

public sealed record FunctionSpec(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("summary")] string Summary,
    [property: JsonPropertyName("returns")] string Returns,
    [property: JsonPropertyName("csReturns")] string CsReturns,
    [property: JsonPropertyName("wrapInTryBarrier")] bool WrapInTryBarrier,
    [property: JsonPropertyName("params")] IReadOnlyList<ParamSpec> Params,
    [property: JsonPropertyName("barrierNote")] string? BarrierNote = null,
    [property: JsonPropertyName("entryPoint")] string? EntryPoint = null,
    [property: JsonPropertyName("reachable")] bool? Reachable = null,
    [property: JsonPropertyName("reachableNote")] string? ReachableNote = null)
{
    /// <summary>
    /// 到達性テスト（<c>ReachabilityEmitter</c>）がこの関数を呼ぶか。
    /// </summary>
    /// <remarks>
    /// **既定は true である。** spec が <c>reachable</c> を書いていない関数は
    /// 呼ぶ側に回る —— 「呼べる」が普通で、「呼べない」ほうが例外だからで、
    /// 書き忘れが静かな除外にならないようにするためでもある。
    ///
    /// **nullable にしてあるのは、既定値の解釈を JSON 実装に委ねないため。**
    /// bool の必須でない値をそのまま受けると「書かれていない」と「false と
    /// 書かれている」が区別できず、既定が false 側に倒れれば到達性テストは
    /// 1 本も呼ばないまま緑になる。ここで null と false を分けておけば、
    /// どちらに転んでも既定は true のままである。
    /// </remarks>
    public bool IsReachable => Reachable != false;
}

public sealed record ModuleSpec(
    [property: JsonPropertyName("module")] string Module,
    [property: JsonPropertyName("functions")] IReadOnlyList<FunctionSpec> Functions);

public static class SpecModel
{
    private static readonly JsonSerializerOptions Options = new()
    {
        // **知らないフィールドを黙って捨てない。** 綴り間違いは形の誤りである。
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        ReadCommentHandling = JsonCommentHandling.Disallow,
    };

    public static IReadOnlyList<ModuleSpec> Load(string specDir)
    {
        // **schema.json を実際に読む。** C# レコードの必須引数と
        // UnmappedMemberHandling.Disallow はフィールド名の綴りと必須性しか
        // カバーしない。enum / pattern を強制するのはここから先の役目で、
        // その enum / pattern 自体は schema.json から読み取る（手で複製しない）。
        var schemaConstraints = SchemaConstraints.ReadFrom(Path.Combine(specDir, "schema.json"));

        var files = Directory.GetFiles(specDir, "*.json")
            .Where(f => Path.GetFileName(f) != "schema.json")
            .OrderBy(f => f, StringComparer.Ordinal)
            .ToList();

        if (files.Count == 0)
        {
            throw new SpecFormatException($"spec が 1 件も見つかりません: {specDir}");
        }

        var result = new List<ModuleSpec>();
        foreach (var file in files)
        {
            ModuleSpec? spec;
            try
            {
                spec = JsonSerializer.Deserialize<ModuleSpec>(File.ReadAllText(file), Options);
            }
            catch (JsonException ex)
            {
                throw new SpecFormatException($"{Path.GetFileName(file)} を読めません: {ex.Message}");
            }
            if (spec is null)
            {
                throw new SpecFormatException($"{Path.GetFileName(file)} が null になりました");
            }
            ValidateAgainstSchema(Path.GetFileName(file), spec, schemaConstraints);
            result.Add(spec);
        }
        return result;
    }

    /// <summary>
    /// <c>cType</c> ごとに、spec が書いてよい <c>csType</c> の集合。
    /// </summary>
    /// <remarks>
    /// **なぜ在るか。** <c>cType</c> の側は C++ コンパイラが閉じている
    /// （生成したヘッダと実装が食い違えばビルドが落ちる）が、<c>csType</c> は
    /// **誰も見ていなかった** —— <c>int64_t</c> に <c>int</c> と書いても、
    /// C も C# も <c>verify-generated</c> も到達性テストも全部緑になり、
    /// 実行時の marshalling だけが壊れる。**壊れるのは呼んだ場所ではなく、
    /// 後から無関係な場所である**（<c>docs/abi-ownership-and-versioning.md</c> §1
    /// が借用 handle を禁じたのと同じ理由づけ）。
    ///
    /// **buffer の 2 つは一意に決まらない。** <c>byte[]</c>（managed 配列を
    /// marshal する版）と <c>System.IntPtr</c>（アドレスを直接渡す版）は
    /// 同じ C の entry point に対する別の入口で、どちらも正しい。**その 2 つの
    /// うちどちらを書いたかは、ここでは見ていない**（残る穴。roadmap の M5 の
    /// 判定に書いてある）。
    ///
    /// **知らない <c>cType</c> は拒む。** 素通しにすると、型が 1 つ増えるたびに
    /// その 1 つだけが静かに網から外れる。足す人がここへ C# 側の相手を
    /// 書くことで、表は定義上いつも完全である。
    /// </remarks>
    private static readonly IReadOnlyDictionary<string, string[]> AllowedCsTypes =
        new Dictionary<string, string[]>(StringComparer.Ordinal)
        {
            ["int32_t"] = new[] { "int" },
            ["int64_t"] = new[] { "long" },
            ["double"] = new[] { "double" },
            // **1 つの cType が 2 つの意味を持つ** —— スカラー 1 個の出力
            // （見つかった個数、選ばれたしきい値の位置）と、配列への書き出し
            // （検出したマーカーの ID、輪郭ごとの点数）である。C 側の型は
            // どちらも int32_t* で同じなので、どちらになるかは spec の
            // direction と csType が決める。**下の double* とまったく同じ形**で、
            // あちらが先例である（ocvu_calibrate_camera が再投影誤差を
            // out double で、カメラ行列を double[] で返す）。
            //
            // **受け入れているコスト**: 足したことで、以後 int32_t* の param は
            // out int と int[] のどちらでも表を通る —— 「配列を渡すつもりで
            // out int と書いた」取り違えを、この表はもう捕まえない。
            // double* で既に同じコストを払っているので新しい種類の穴ではないが、
            // **1 つ増えたことは事実である。**
            ["int32_t*"] = new[] { "out int", "int[]" },
            ["ocvu_mat_handle"] = new[] { "ulong" },
            ["ocvu_mat_handle*"] = new[] { "out ulong" },
            ["ocvu_mat_info*"] = new[] { "out OcvuMatInfo" },
            // 点の座標を渡す配列（x と y が交互に並ぶ）。buffer と同じ形。
            ["const float*"] = new[] { "float[]", "System.IntPtr" },
            // 点の座標を書き出す配列（x と y が交互に並ぶ）。const float* の書き込み版。
            ["float*"] = new[] { "float[]", "System.IntPtr" },
            // カメラ行列・歪み係数など、小さい固定長を借用で渡す配列。
            ["const double*"] = new[] { "double[]", "System.IntPtr" },
            // const double* の書き込み版（const float* に対する float* と同じ関係）。
            // **1 つの cType が 2 つの意味を持つ** —— 配列への書き出し
            // （カメラ行列・歪み係数・姿勢）と、スカラー 1 個の出力
            // （再投影誤差）である。C 側の型はどちらも double* で同じなので、
            // どちらになるかは spec の direction と csType が決める。
            ["double*"] = new[] { "double[]", "out double", "System.IntPtr" },
            // 特徴点配列。managed 配列版とアドレス版のどちらも正しい（buffer と同じ形）。
            ["ocvu_keypoint*"] = new[] { "OcvuKeyPoint[]", "System.IntPtr" },
            // 記述子どうしの対応の配列。ocvu_keypoint* とまったく同じ形である。
            ["ocvu_dmatch*"] = new[] { "OcvuDMatch[]", "System.IntPtr" },
            // byte 列を渡す 4 つ。managed 配列版とアドレス版のどちらも正しい。
            ["const uint8_t*"] = new[] { "byte[]", "System.IntPtr" },
            ["uint8_t*"] = new[] { "byte[]", "System.IntPtr" },
            ["const char*"] = new[] { "byte[]", "System.IntPtr" },
            ["char*"] = new[] { "byte[]", "System.IntPtr" },
        };

    private static void RequireTheCsTypeMatchesTheCType(
        string fileName, string fnName, ParamSpec p)
    {
        if (!AllowedCsTypes.TryGetValue(p.CType, out var allowed))
        {
            throw new SpecFormatException(
                $"{fileName}: {fnName}.{p.Name} の cType '{p.CType}' を知りません。" +
                "SpecModel.AllowedCsTypes に、この C の型に対応する C# の型を足してください" +
                "（素通しにすると、その 1 つだけが marshalling の検査から静かに外れます）。");
        }

        if (!allowed.Contains(p.CsType, StringComparer.Ordinal))
        {
            throw new SpecFormatException(
                $"{fileName}: {fnName}.{p.Name} の csType '{p.CsType}' は cType '{p.CType}' に対応しません" +
                $"（許すのは {string.Join(" / ", allowed.Select(a => $"'{a}'"))}）。" +
                "食い違っても C も C# もビルドは通り、実行時の marshalling だけが壊れます。");
        }
    }

    // **何が禁じられているかを、拒むときに全部言う。** pattern だけを見せられても
    // 「どの 1 文字が引っかかったのか」「なぜ禁じられているのか」は読み取れない。
    // 直すのは spec を書いた人なので、言い換えの手掛かりまで出す。
    /// <summary>
    /// pattern が値の<b>全体</b>を覆ったか。
    /// </summary>
    /// <remarks>
    /// **<c>Regex.IsMatch</c> で済ませない。** .NET の <c>$</c> は「文字列の
    /// 末尾」だけでなく「末尾の改行の直前」にも一致するので、
    /// <c>^[^X]+$</c> の形は末尾に改行が 1 つ付いた値を**通してしまう**（実測）。
    /// summary の末尾に改行が入ると Markdown の表の行がそこで割れる ——
    /// C ヘッダはブロックコメントなので無事で、**ビルドは緑のまま**である。
    ///
    /// **覆った長さで見れば pattern の書き方に依存しない。** 末尾を厳密に
    /// 縛る anchor へ書き換える手もあるが、それは schema.json 側の綴りに
    /// 賭ける形になる。しかも JSON Schema（ECMA-262）の <c>$</c> は入力末尾に
    /// しか一致しないので、いまの形は**自分が読んでいる正本より弱い**。
    /// 読む側で閉じる。
    /// </remarks>
    private static bool CoversTheWholeValue(string value, string pattern)
    {
        var m = Regex.Match(value, pattern);
        return m.Success && m.Length == value.Length;
    }

    private static void RequireSafeText(
        string fileName, string fnName, string field, string value, string pattern)
    {
        if (CoversTheWholeValue(value, pattern)) { return; }

        throw new SpecFormatException(
            $"{fileName}: {fnName}.{field} が schema の pattern '{pattern}' に一致しません。" +
            "生成物を壊す文字は禁じています —— 改行は Markdown の表の行を割り、" +
            "'*/' は C ヘッダのブロックコメントをそこで終わらせ（残りが C のコードになり、" +
            "実測でコンパイルエラー C2143 になります）、" +
            "'<' '>' '&' は C# の XML doc を壊します" +
            "（doc ファイルを生成していない現状では compiler は黙っていますが、" +
            "IDE の表示は壊れ、生成を有効にした時点で一斉にエラーになります）。" +
            "これらを使わない言い回しに直してください。");
    }

    private static void ValidateAgainstSchema(string fileName, ModuleSpec spec, SchemaConstraints c)
    {
        if (!CoversTheWholeValue(spec.Module, c.ModulePattern))
        {
            throw new SpecFormatException(
                $"{fileName}: module '{spec.Module}' が schema の pattern '{c.ModulePattern}' に一致しません");
        }

        foreach (var fn in spec.Functions)
        {
            if (!CoversTheWholeValue(fn.Name, c.FunctionNamePattern))
            {
                throw new SpecFormatException(
                    $"{fileName}: 関数名 '{fn.Name}' が schema の pattern '{c.FunctionNamePattern}' に一致しません");
            }
            // **生成物を壊す文字は逃がすのではなく禁じる。** summary は 3 つの
            // 生成物へ**生のまま**入る: Markdown の表のセル（docs/api-map.md）、
            // C のブロックコメント（native/include/ocvu/*.h）、C# の XML doc
            // （NativeMethods.*.g.cs）。どれも逃がし方が違う。**いちばん重いのは
            // C ヘッダで、`*/` を 1 つ入れると native のビルドが落ちる**（実測。
            // imgproc.h(18,51) で C2143）。XML doc のほうは、いまは doc ファイルを
            // 生成していないので compiler が黙る —— つまり**壊れたまま緑になる**。
            // summary は人が読む短い説明なので、この 4 つが書けなくても
            // 困らない —— 規約で禁じるのではなく、spec の側で表現できなくする
            // （docs/abi-ownership-and-versioning.md §1 と同じ考え方）。
            RequireSafeText(fileName, fn.Name, "summary", fn.Summary, c.SummaryPattern);

            // barrierNote は C ヘッダの同じブロックコメントへ入る（XML doc には
            // 入らないが、pattern を分ける理由もないので同じものを当てる）。
            if (fn.BarrierNote is not null)
            {
                RequireSafeText(fileName, fn.Name, "barrierNote", fn.BarrierNote, c.BarrierNotePattern);
            }

            // **例外バリアを外すなら理由を書かせる。** reachable: false に同じ
            // 強制が既に在るのに、こちらだけ無かった —— **安全性が高いほうに
            // 付いていない**。ABI 境界を越える unwind は未定義動作になり得るので、
            // 囲まないと決めた 1 本は「throw し得ない実装であること」が条件に
            // なる。その根拠が spec に無ければ、次に読む人は意図と事故を
            // 区別できない（native/src/ocvu_error.h のマクロの隣にある一覧と
            // 突き合わせる手掛かりでもある）。
            //
            // **実測: これが無い間、`add-abi-function` skill は「理由が無い spec は
            // 生成器が拒む」と書いていたが拒まなかった** —— barrierNote を消すと
            // generate は exit 0 で成功し、ヘッダから理由の行が黙って消えた。
            if (!fn.WrapInTryBarrier && string.IsNullOrWhiteSpace(fn.BarrierNote))
            {
                throw new SpecFormatException(
                    $"{fileName}: {fn.Name} は wrapInTryBarrier: false だが barrierNote がありません。" +
                    "例外バリアで囲まない理由（throw し得ない実装である根拠）を書いてください。");
            }
            if (!c.ReturnsEnum.Contains(fn.Returns))
            {
                throw new SpecFormatException(
                    $"{fileName}: {fn.Name}.returns '{fn.Returns}' は schema の enum" +
                    $"（{string.Join(", ", c.ReturnsEnum)}）のいずれでもありません");
            }
            if (!c.CsReturnsEnum.Contains(fn.CsReturns))
            {
                throw new SpecFormatException(
                    $"{fileName}: {fn.Name}.csReturns '{fn.CsReturns}' は schema の enum" +
                    $"（{string.Join(", ", c.CsReturnsEnum)}）のいずれでもありません");
            }
            if (fn.EntryPoint is not null && !CoversTheWholeValue(fn.EntryPoint, c.EntryPointPattern))
            {
                throw new SpecFormatException(
                    $"{fileName}: {fn.Name}.entryPoint '{fn.EntryPoint}' が schema の pattern " +
                    $"'{c.EntryPointPattern}' に一致しません");
            }
            // **「呼べない」と印を付けるなら理由を書かせる。** reachable: false は
            // 到達性テストの網から 1 本を外すので、なぜ外すのかが spec を読んで
            // 分からなければ、次に読む人はそれが意図か事故かを判定できない。
            if (!fn.IsReachable && string.IsNullOrWhiteSpace(fn.ReachableNote))
            {
                throw new SpecFormatException(
                    $"{fileName}: {fn.Name} は reachable: false だが reachableNote がありません。" +
                    "到達性テストから外す理由を書いてください。");
            }

            foreach (var p in fn.Params)
            {
                if (!CoversTheWholeValue(p.Name, c.ParamNamePattern))
                {
                    throw new SpecFormatException(
                        $"{fileName}: {fn.Name} の param 名 '{p.Name}' が schema の pattern " +
                        $"'{c.ParamNamePattern}' に一致しません");
                }
                RequireTheCsTypeMatchesTheCType(fileName, fn.Name, p);
                if (!c.DirectionEnum.Contains(p.Direction))
                {
                    throw new SpecFormatException(
                        $"{fileName}: {fn.Name}.{p.Name}.direction '{p.Direction}' は schema の enum" +
                        $"（{string.Join(", ", c.DirectionEnum)}）のいずれでもありません");
                }
                RequireNonConstPointersAreNotInbound(fileName, fn.Name, p);
            }
        }
    }

    /// <summary>
    /// 非 const のポインタ型（書き込み先）が <c>in</c> / <c>in-buffer</c> に
    /// 書かれていないことを見る。
    /// </summary>
    /// <remarks>
    /// **下流に門が無い向きだけを見る。** const のポインタを <c>out</c> /
    /// <c>out-buffer</c> に書く逆向きは、実装がそこへ書き込もうとした瞬間に
    /// C コンパイラが const 修飾違反として落とすので、下流に既に門がある。
    /// 非 const 側は <c>in</c> / <c>in-buffer</c> に書いても C も C# も
    /// ビルドが通り、実行時の意図の食い違いだけが残る —— こちらにだけ
    /// 検査を足す（<c>float*</c> / <c>const float*</c> が並んで以降、
    /// 意味を持つようになった。M5 module 追加のレビュー M6）。
    /// </remarks>
    private static void RequireNonConstPointersAreNotInbound(
        string fileName, string fnName, ParamSpec p)
    {
        if (!p.CType.EndsWith("*", StringComparison.Ordinal)) { return; }
        if (p.CType.StartsWith("const ", StringComparison.Ordinal)) { return; }
        if (p.Direction != "in" && p.Direction != "in-buffer") { return; }

        throw new SpecFormatException(
            $"{fileName}: {fnName}.{p.Name} の cType '{p.CType}' は const が付いていません" +
            $"（書き込み先です）が、direction は '{p.Direction}' です。" +
            "const を付けるか、direction を 'out' / 'out-buffer' にしてください。");
    }
}
