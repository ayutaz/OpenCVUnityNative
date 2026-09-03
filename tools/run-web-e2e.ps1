#!/usr/bin/env pwsh
<#
.SYNOPSIS
    ビルドした WebGL Player を実際にブラウザで動かし、結果を回収する（M6）。

.DESCRIPTION
    **これが「動く」を主張できる唯一のレーンである。**
    ビルドできること（`dev.ps1 test-unity-web`）と、配れること
    （`PluginGatingTests`）と、動くことは別である
    （`add-a-platform` skill の完了の判定）。

    通す経路: ブラウザ -> Unity Web Player -> C# -> P/Invoke ->
    wasm の plugin -> OpenCV。**途中のどこが切れていても、ここが赤くなる。**

    Player の中では `WebSmokeRunner` が
    `AbiSurfaceChecks` と `AbiReachabilityChecks` を走らせ、
    **他の platform と同じ検証本体**の結果を 1 行で出す:

        OCVU_WEB_RESULT: passed=N failed=M reachable=R

    このスクリプトはそれをブラウザのコンソールから読む。

    **「0 件で緑にしない」をここでも守る** —— 目印の行が 1 度も出なければ、
    それは成功ではなく**結果が取れなかった**である。Player が起動すら
    しなかったときに緑になるのが、このレーンで最も避けたい壊れ方である。

.PARAMETER PlayerDir
    ビルド済みの WebGL Player（既定 build/web-player）。

.PARAMETER TimeoutSeconds
    Player の起動から結果が出るまでの上限。既定 180 秒。

.PARAMETER Port
    serve する port。既定 8123。
#>
[CmdletBinding()]
param(
    [string]$PlayerDir,
    [int]$TimeoutSeconds = 180,
    [int]$Port = 8123
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $PlayerDir) { $PlayerDir = Join-Path $RepoRoot 'build/web-player' }

function Fail([string[]]$Lines) {
    [Console]::Error.WriteLine(($Lines -join "`n"))
    exit 1
}

if (-not (Test-Path -LiteralPath (Join-Path $PlayerDir 'index.html'))) {
    Fail @(
        "WebGL Player がありません: $PlayerDir/index.html"
        "先に './tools/dev.ps1 test-unity-web' を実行してください。"
    )
}

# --- Playwright を用意する ---
#
# **node の在り処を決め打ちしない。** ローカルには Unity 同梱の node も
# 在るが、Playwright は npm から入れるので PATH の node/npx を使う。
$npx = (Get-Command 'npx' -ErrorAction SilentlyContinue)?.Source
if (-not $npx) {
    Fail @(
        'npx が見つかりません。Node.js が要ります。'
        '**これは SKIP ではなく失敗である** —— ブラウザで動かさない限り'
        '「動く」は主張できないので、道具が無いことを緑にしない。'
    )
}

$driver = Join-Path $RepoRoot 'build/web-e2e/drive.mjs'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $driver) | Out-Null

# **目印は C# 側の定数と揃える。** ここに文字列を書き写しているので、
# 食い違ったら結果が取れなくなる —— 下の「1 度も出なければ失敗」が
# その食い違いを捕まえる（黙って緑にはならない）。
@'
import { chromium } from 'playwright';

const url = process.argv[2];
const timeoutMs = Number(process.argv[3]);
const RESULT = 'OCVU_WEB_RESULT:';
const FAILURE = 'OCVU_WEB_FAIL:';

const browser = await chromium.launch({ args: ['--no-sandbox'] });
const page = await browser.newPage();

let result = null;
const failures = [];
const pageErrors = [];

const allConsole = [];
page.on('console', (msg) => {
    const text = msg.text();
    allConsole.push(`[${msg.type()}] ${text}`);
    if (text.includes(RESULT)) { result = text.slice(text.indexOf(RESULT)); }
    if (text.includes(FAILURE)) { failures.push(text.slice(text.indexOf(FAILURE))); }
});
// **応答も記録する。** 200 を返していても中身の解釈で落ちることがあるので、
// 何をどの Content-Encoding で受けたかが要る。
const responses = [];
page.on('response', (r) => {
    responses.push(`${r.status()} ${r.url()} enc=${r.headers()['content-encoding'] ?? '-'} ` +
                   `type=${r.headers()['content-type'] ?? '-'}`);
});
// **Player の中の例外も拾う。** 起動直後に落ちると console には
// 目印が出ないので、そのときの手がかりが無くなる。
page.on('pageerror', (err) => { pageErrors.push(String(err)); });

await page.goto(url, { waitUntil: 'domcontentloaded' });

const deadline = Date.now() + timeoutMs;
while (!result && Date.now() < deadline) {
    await page.waitForTimeout(500);
}

await browser.close();

for (const f of failures) { console.log(f); }
for (const e of pageErrors) { console.log('PAGE_ERROR: ' + e); }
if (!result) {
    // **結果が取れなかったときだけ、全部を吐く。** 通ったときに
    // 出力を埋めない。
    for (const r of responses) { console.log('HTTP ' + r); }
    // **先頭だけ見ない。** 起動のログで埋まって、肝心の末尾が落ちる。
    for (const c of allConsole.slice(0, 15)) { console.log('CONSOLE.head ' + c); }
    for (const c of allConsole.slice(-25)) { console.log('CONSOLE.tail ' + c); }
    console.log('CONSOLE.count ' + allConsole.length);
}
if (result) {
    console.log(result);
    process.exit(0);
}
console.log('NO_RESULT');
process.exit(2);
'@ | Set-Content -LiteralPath $driver -Encoding utf8NoBOM

# **playwright をローカルに導入する。**
#
# `npx playwright node <script>` は動かない —— playwright の CLI に
# `node` という subcommand は無い（2026-09-03 に実測:
# `error: unknown command 'node'`）。**`import { chromium } from 'playwright'`
# を解決するには node_modules が要る**ので、素直に入れる。
$node = (Get-Command 'node').Source
$e2eDir = Join-Path $RepoRoot 'build/web-e2e'
@'
{ "name": "ocvu-web-e2e", "private": true, "type": "module",
  "dependencies": { "playwright": "1.49.1" } }
'@ | Set-Content -LiteralPath (Join-Path $e2eDir 'package.json') -Encoding utf8NoBOM

$npm = (Get-Command 'npm' -ErrorAction SilentlyContinue)?.Source
if (-not $npm) { Fail @('npm が見つかりません。Node.js が要ります。') }

Write-Host '==> installing playwright...'
Push-Location $e2eDir
try {
    & $npm install --no-audit --no-fund 2>&1 | Select-Object -Last 3
    if ($LASTEXITCODE -ne 0) { Fail @("npm install が失敗しました (exit $LASTEXITCODE)") }
    & $npx --yes playwright@1.49.1 install chromium 2>&1 | Select-Object -Last 2
    if ($LASTEXITCODE -ne 0) { Fail @("chromium を用意できませんでした (exit $LASTEXITCODE)") }
} finally { Pop-Location }

# --- serve する ---
#
# **Unity 同梱の SimpleWebServer は使わない。** Windows にしか無く、
# CI（Linux）で使えない。**ローカルと CI で経路を分けない**ため、
# どちらでも動く node の静的サーバにする。
$server = Join-Path $RepoRoot 'build/web-e2e/serve.mjs'
@'
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const root = process.argv[2];
const port = Number(process.argv[3]);
const types = {
    '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json',
    '.wasm': 'application/wasm', '.data': 'application/octet-stream',
    '.css': 'text/css', '.png': 'image/png', '.ico': 'image/x-icon',
};

createServer(async (req, res) => {
    try {
        let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
        if (p === '/') p = '/index.html';
        // **正規表現を使わない。** ここは PowerShell の here-string の中の
        // JavaScript なので、`\` の段が 2 つある。実際に 1 段落ちて
        // `/^([/\])+/` になり `SyntaxError: Invalid regular expression` で
        // サーバが起動しなかった（2026-09-03 に実測）。
        // **escape が要らない書き方にすれば、その段は最初から無い。**
        // **バックスラッシュを 1 文字も書かない。**
        //
        // ここは PowerShell の here-string の中の JavaScript を、さらに
        // 別の言語から書き出している。**escape の段が 3 つあり、2 度続けて
        // 1 段落ちた**（`/^([/\])+/` が `/^([/\])+/` になって
        // `SyntaxError: Invalid regular expression` でサーバが起動しなかった）。
        //
        // **URL の pathname は常に '/' 区切りである。** 正規表現も
        // バックスラッシュも要らない書き方にすれば、その段は最初から無い。
        const parts = p.split('/').filter((s) => s && s !== '.' && s !== '..');
        const file = join(root, ...parts);
        let body;
        let headers = {};
        let typeName = file;

        // **Unity は gzip 圧縮した物しか出さないことがある。**
        // 経路は 2 つあり、**どちらでも Content-Encoding を付ける**:
        //   - ブラウザが .js.gz / .wasm.gz を**そのまま**要求する
        //     （Unity の loader はビルド時の圧縮設定を知っているのでこちら）
        //   - ブラウザが .js / .wasm を要求し、こちらに .gz しか無い
        //
        // **前者を落としていた**（2026-09-03 に実測）—— 直接読めてしまうので
        // catch に入らず、生の gzip を返して
        // `Failed to parse binary data file ...` になった。
        if (file.endsWith('.gz')) {
            body = await readFile(file);
            headers['Content-Encoding'] = 'gzip';
            typeName = file.slice(0, -3);
        } else {
            try {
                body = await readFile(file);
            } catch {
                body = await readFile(file + '.gz');
                headers['Content-Encoding'] = 'gzip';
            }
        }
        headers['Content-Type'] = types[extname(typeName)] ?? 'application/octet-stream';
        res.writeHead(200, headers);
        res.end(body);
    } catch (e) {
        res.writeHead(404).end(String(e));
    }
}).listen(port, () => console.log('serving on ' + port));
'@ | Set-Content -LiteralPath $server -Encoding utf8NoBOM

Write-Host "==> serving $PlayerDir on http://127.0.0.1:$Port"
$serverProc = Start-Process -FilePath $node -ArgumentList @($server, $PlayerDir, $Port) `
    -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $RepoRoot 'build/web-e2e/serve.log') `
    -RedirectStandardError (Join-Path $RepoRoot 'build/web-e2e/serve.err.log')

try {
    Start-Sleep -Seconds 2
    Write-Host '==> driving chromium...'
    Push-Location $e2eDir
    try {
        $out = & $node $driver "http://127.0.0.1:$Port/index.html" ($TimeoutSeconds * 1000) 2>&1
    } finally { Pop-Location }
    $driveExit = $LASTEXITCODE
} finally {
    if (-not $serverProc.HasExited) { $serverProc.Kill() }
}

$text = ($out | Out-String)
Write-Host $text

# **目印の行が 1 度も出なければ、それは成功ではない。**
$m = [regex]::Match($text, 'OCVU_WEB_RESULT:\s*passed=(?<p>\d+)\s+failed=(?<f>\d+)\s+reachable=(?<r>-?\d+)')
if (-not $m.Success) {
    Fail @(
        'Player から結果が取れませんでした（OCVU_WEB_RESULT の行が 1 度も出ていません）。'
        "driver の exit: $driveExit"
        ''
        '**これは「検査が通った」ではない。** Player が起動しなかったか、'
        '起動直後に落ちたか、目印の綴りが C# 側とずれている。'
        '上の PAGE_ERROR と serve.log / serve.err.log を見ること。'
    )
}

$passed = [int]$m.Groups['p'].Value
$failed = [int]$m.Groups['f'].Value
$reachable = [int]$m.Groups['r'].Value

Write-Host "==> [web] passed=$passed failed=$failed reachable=$reachable"

if ($failed -gt 0) { Fail @("Web Player で $failed 件の検査が失敗しました。") }
if ($passed -eq 0) { Fail @('Web Player で 1 件も検査が走っていません（0 件で緑にしない）。') }
if ($reachable -le 0) {
    Fail @(
        "到達性テストが $reachable を返しました。"
        '**stripping が P/Invoke 宣言を消した可能性がある** —— これを'
        '確かめられるのは Player だけである。'
    )
}

Write-Host '==> [web] OK' -ForegroundColor Green
exit 0
