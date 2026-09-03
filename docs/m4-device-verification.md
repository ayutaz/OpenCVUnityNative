# M4 実機検証の手順

**この文書は、CI では閉じられない完了条件を人が実行するためのものである。**

閉じられない理由: GitHub ホストの runner に端末は繋がっておらず、iOS は Apple の
署名も要る。**「実機で確認した」と書けるのは、実際に端末で走らせた人だけである。**

roadmap の M4 完了条件のうち、次の 2 件がこれに当たる。

- iOS の `__Internal` static link と linker stripping 後も P/Invoke が解決すること
- lifecycle（background / foreground）と memory pressure

**この 2 件は、CI では原理的に閉じない。** 実機が要る。

**2026-09-01 に「実機検証をスキップする」と決めた。** その結果 `v0.3.0` は
下書きのまま止まり、**2026-09-03 に「モバイルを実機未検証と明記して配る」方針へ
変わった**（roadmap の「配布 その 5 — v0.3.0」）。**つまりこの手順書は、
配る前提条件ではなくなった** —— 配ったあとで誰かが実施して、動くかどうかを
確かめるためのものである。

**`v0.3.0` の下書きを公開してはならない。** M5 が main に入る前に作ったもので、
生成物が 1 つも入っていない。配るときは tag を打ち直す（roadmap の「配布 その 5」）。

**ここを実施して問題が見つかったら、その版を直した新しい版を出す**（一度配った
ものは黙って差し替えない。v0.1.1 がその形だった）。

**CI が代わりに見ているのは「ビルドできること」までである。** v0.1.0 が踏んだ
「ビルドできた ≠ 動く」の距離が、モバイルではさらに開く —— 実機でしか起きない
失敗（署名、stripping、メモリ警告）が層として増えるからである。

---

## 1. iOS 実機の smoke test

### 前提

- Apple Developer アカウント（署名のため）
- iOS 15.0 以降の実機（`package.json` の下限に合わせている）
- macOS + Xcode

### 手順

1. iOS 向けの native をビルドする

   ```sh
   ./tools/opencv.ps1 restore -Platform ios-arm64
   ./tools/dev.ps1 build -Platform ios-arm64
   ```

   `Packages/com.ayutaz.opencv-unity-native/Runtime/Plugins/iOS/libopencv_unity_native.a`
   ができる。**`.dylib` ができていたら止まること** —— iOS はアプリの外から
   共有ライブラリを読み込めない。

2. `tests/UnityProject` を iOS 向けに Build する。
   **Scripting Backend は IL2CPP、Managed Stripping Level は High。**
   既定のままだと stripping が弱く、**この検証の主目的が消える。**

3. 出た Xcode プロジェクトを開き、署名して実機へ流す。

### 確かめること

| | 何を見るか | 落ちたときに何が分かるか |
| --- | --- | --- |
| **a** | `ocvu_get_abi_version()` が 1 を返す | P/Invoke が `__Internal` で解決している。落ちたら静的リンクか `DllImport` の名前が違う |
| **b** | `CvOps.CvtColor` が動く | OpenCV が実際にリンクされている。(a) だけ通って (b) が落ちるなら、ABI の入口はあるが OpenCV 本体が引かれていない |
| **c** | **Managed Stripping Level = High でも (a)(b) が通る** | `link.xml` が効いている。**ここでしか分からない** —— Editor でも Mono でも stripping は掛からない |

### 記録すること

- Unity の版、Xcode の版、端末の機種と iOS の版
- 上の 3 つそれぞれの結果
- **落ちたなら、落ちた場所とスタックトレース**

---

## 2. lifecycle と memory pressure

### 手順

1. 上の smoke test が通ったビルドを使う。

2. **background / foreground**

   `CvMat` を 1 つ作って保持したまま、アプリを Home に送り、30 秒待って戻す。
   戻った後に `CopyTo` が成功すること。

3. **memory pressure**

   Xcode の Debug > Simulate Memory Warning を送る。保持していた `CvMat` が
   無効化されていないこと。

   **これは所有権契約の検証である。** `ocvu_mat_handle` は常に native が
   所有しており（`docs/abi-ownership-and-versioning.md` §1）、Unity の GC や
   メモリ警告では解放されない。**落ちたら、それは契約の反例である** ——
   その場合は §1 を見直すこと。

### 記録すること

- 各操作の後で ABI 呼び出しが成功したか
- 落ちたなら、どの操作の後か

---

## 3. Android 実機（16 KB page の端末）

**CI は `.so` の `p_align` を見るが、実際に 16 KB page の端末で読み込めるかは
見ていない。**

Pixel 8 以降 + Android 15 で確かめること。

```sh
adb logcat | grep -i "opencv_unity_native\|DllNotFound"
```

`DllNotFoundException` が出ないこと。

**なぜ `p_align` の検査だけでは足りないか**: `p_align` は「16 KB で
マップできる形になっている」ことを示すが、依存する他の `.so`（`libc++_shared`
など）が対応していない可能性を排除しない。このプラグインは
`ANDROID_STL=c++_static` で STL を静的に取り込んでいるので理屈の上では
閉じているが、**理屈で閉じていることと実機で動くことは別である** ——
それが v0.1.0 の教訓だった。

---

## 結果をどこに書くか

`docs/roadmap.md` の M4 判定表。**「満たした」と書けるのは、上の各項目に
実際の結果（版・機種・出力）が付いたときだけである。**

実行していない項目は **「満たすが未実証」** の欄に置く。
`.claude/skills/milestone-complete/SKILL.md` がその 3 欄を定めている。
