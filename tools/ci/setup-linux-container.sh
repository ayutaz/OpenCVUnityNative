#!/usr/bin/env bash
#
# Linux のビルドを行うコンテナに、必要な道具を入れる。
#
# ## なぜコンテナでビルドするのか
#
# 共有ライブラリは、ビルドした環境と同じかそれより新しい glibc / libstdc++
# でしか読み込めない。古い環境で作ったものは新しい環境でも動くが、逆は
# 成立しない。
#
# v0.1.0 でこれを踏んだ。ubuntu-24.04（glibc 2.39）でビルドした .so が
# GLIBC_2.38 を要求し、それより古い環境で DllNotFoundException になった。
# ビルドは成功し、linkage 検証も通り、配布物も作れた。読み込めないことは
# Unity を実際に動かすまで誰も知らなかった。
#
# runner のイメージは GitHub の都合で上がっていく。**上がるたびに要求が
# 上がらないよう、ビルド環境をコンテナで固定する。** どのコンテナを使うかは
# tools/opencv-config.psd1 の Toolchains['linux-x64'].Container が正本で、
# その値は構成ハッシュに入る。
#
# ## この script が呼ばれる位置
#
# **checkout より前**である。actions/checkout は git が無いと REST API で
# アーカイブを落とす形に落ち、.git の無いツリーになる。すると `git ls-files`
# を使うテストが「追跡ファイルが 0 件」で通ってしまう——検査が黙って
# 無力化される、このリポジトリが繰り返している形である。
#
# root で走る前提（コンテナ内なので sudo は無い）。

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> apt update"
apt-get update -qq

echo "==> base toolchain"
apt-get install -y -qq --no-install-recommends \
    build-essential \
    ninja-build \
    git \
    curl \
    wget \
    ca-certificates \
    gnupg \
    unzip \
    zip \
    python3

# cmake は **Ubuntu の apt では古すぎる。** jammy が配るのは 3.22.1 で、
# このリポジトリの CMakePresets.json は 3.25 以上を要る
# （README の Requirements にも 3.25+ と書いてある）。
#
# 実測: 3.22.1 のまま走らせると
#   CMake Error: Could not read presets: Unrecognized "version" field
# で止まる。preset の schema 版が読めないという意味である。
#
# Kitware の公式リポジトリから現行版を入れる。cmake はビルドの道具であって
# 成果物にリンクされないので、新しくても glibc の要求は上がらない——
# コンテナを使う目的（古い環境で動く .so を作る）と矛盾しない。
echo "==> cmake from Kitware"
source /etc/os-release
wget -qO- https://apt.kitware.com/keys/kitware-archive-latest.asc \
    | gpg --dearmor -o /usr/share/keyrings/kitware-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ ${VERSION_CODENAME} main" \
    > /etc/apt/sources.list.d/kitware.list
apt-get update -qq
apt-get install -y -qq --no-install-recommends cmake

# PowerShell 7 と .NET 8 SDK は Microsoft のリポジトリから入れる。
# dev.ps1 / opencv.ps1 が pwsh で、L3 が .NET 8 を要る。
echo "==> Microsoft repository"
source /etc/os-release
wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" \
     -O /tmp/packages-microsoft-prod.deb
dpkg -i /tmp/packages-microsoft-prod.deb
rm -f /tmp/packages-microsoft-prod.deb
apt-get update -qq

echo "==> powershell + dotnet sdk"
apt-get install -y -qq --no-install-recommends powershell dotnet-sdk-8.0

# gh CLI は opencv.ps1 restore が artifact を落とすのに使う。
echo "==> gh cli"
# mkdir -p に -m を付けると、権限が最深のディレクトリにしか効かない
# （shellcheck SC2174）。作ってから明示的に設定する。
mkdir -p /etc/apt/keyrings
chmod 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
apt-get update -qq
apt-get install -y -qq --no-install-recommends gh

# checkout したファイルは runner の UID で、コンテナは root で走る。git は
# その食い違いを "detected dubious ownership" として拒否するので、この
# ワークスペースを信頼する設定を入れる。
#
# **黙って握りつぶすのではなく、必要な場所だけを許す。** git が拒否するのは
# 正しい振る舞いで、無効化するのはコンテナの中という限られた文脈だからである。
#
# 入れないと `gh` や `git ls-files` が落ちる。実測: opencv.ps1 restore が
# "failed to determine base repo: detected dubious ownership" で止まった。
echo "==> trust the workspace"
git config --global --add safe.directory "$(pwd)"

# 入ったことを確かめる。**足りないまま先に進めない。** ここで止めれば
# 「cmake が無いのでビルドが空振りした」を後段で読み解かずに済む。
echo "==> versions"
missing=0
for tool in git cmake ninja pwsh dotnet gh; do
    if command -v "$tool" > /dev/null 2>&1; then
        printf '    %-8s %s\n' "$tool" "$("$tool" --version 2>&1 | head -1)"
    else
        printf '    %-8s MISSING\n' "$tool"
        missing=1
    fi
done

# glibc の版も出しておく。成果物がどこまで遡れるかを決めるのはこれである。
printf '    %-8s %s\n' 'glibc' "$(ldd --version | head -1)"

# cmake の版が足りているか。**入っただけでは足りない**——古い cmake は
# preset を読めずに落ちる。ここで見れば、後段の分かりにくいエラーを
# 読み解かずに済む。
required_cmake=3.25
have_cmake=$(cmake --version | head -1 | grep -oE '[0-9]+[.][0-9]+' | head -1)
if [ "$(printf '%s\n%s\n' "$required_cmake" "$have_cmake" | sort -V | head -1)" != "$required_cmake" ]; then
    echo "cmake $have_cmake is older than the required $required_cmake" >&2
    exit 1
fi

if [ "$missing" -ne 0 ]; then
    echo "required tools are missing; refusing to continue" >&2
    exit 1
fi
