# Third-party notices

This file documents the third-party components bundled inside the OpenCV
5.0.0 build that this package links against — **not** this repository's own
source, which is Apache-2.0 (see [LICENSE](LICENSE)).

## Scope of this document

- OpenCV version: **5.0.0**
- Build configuration hash: **配置ごとに変わるのでここには書かない。**
  現在の値は次で取れる:

      pwsh -c "Import-Module ./tools/OpenCvConfig.psm1; Get-OpenCvConfigHash -Config (Get-OpenCvConfig)"

  以下このハッシュを `<hash>` と書く。値を本文に埋め込むと、構成を変えるたびに
  この文書が黙って古くなる（M3 で実際に起きた: Platform をハッシュに含めた結果、
  19 箇所の参照が一斉に死んだ）。ハッシュの導出は `tools/OpenCvConfig.psm1`。
- 対象 platform: **配置ごとに変わる。** 下記のパスは platform で異なる:

  | | ライブラリ | ライセンス |
  | --- | --- | --- |
  | Windows | `x64/vc17/staticlib/*.lib` | `etc/licenses/` |
  | macOS / Linux / iOS / Web | `lib/*.a` | `share/licenses/opencv5/` |
  | Android | `sdk/native/staticlibs/arm64-v8a/*.a` | `sdk/etc/licenses/` |
- Modules built for this configuration (`tools/opencv-config.psd1`):
  `core`, `imgproc`, `imgcodecs`, `objdetect`, `features`, `calib`, `dnn`, plus
  `flann`, `geometry` and `stereo`, pulled in transitively
  (`tools/verify-opencv-artifact.ps1` `$AcceptedTransitiveModules`).
- **Universe considered**: every file under
  `third_party/opencv/<hash>/ のライセンスディレクトリ（上表）` in the restored artifact
  (`./tools/opencv.ps1 restore`) — counts **as of this hash** (they were last
  updated 2026-09-08, when `dnn` added `protobuf-LICENSE` and
  `protobuf-README.md` to every platform): **15 on Windows and Linux, 14 on
  macOS, 13 on iOS, 16 on Android, 13 on Web.** These are no longer a flat
  "desktop and iOS" bucket — that grouping was already an approximation
  before this count, and listing each platform actually downloaded and
  counted (not restored-then-guessed) surfaced two differences unrelated to
  `dnn`: **macOS and iOS both lack `clapack-lapack_LICENSE`** (Windows and
  Linux have it; whatever backs linear algebra on Apple Silicon here isn't
  bundled CLAPACK), and **iOS additionally lacks `dlpack-LICENSE`**, which
  every other platform — including Android and Web — has. Neither of these
  is a `dnn` effect (both were true of the pre-`dnn` trees too, as far as
  this document's authors can tell from what's on hand); they simply hadn't
  been individually counted before. Android's baseline is **cpufeatures-LICENSE
  and cpufeatures-README.md** (both from the NDK) on top of the Windows/Linux
  set, minus the same missing `clapack-lapack_LICENSE`. **Web has two fewer than
  Windows/Linux for an unrelated, already-documented reason**: it is built with
  `WITH_PNG=OFF`, so `libpng-LICENSE` and `libpng-README` are absent — Unity's own
  WebGL support ships libpng, and bundling OpenCV's copy makes the player fail to
  link on duplicate symbols. This is the
  set OpenCV's own install step attributes as third-party, and it is now the
  allowlist `tools/verify-opencv-artifact.ps1`'s `$InertLicenseFiles`
  enforces: a new file appearing there that isn't in that list fails the
  build, so the set can't silently grow without this document being revisited.
- **What "not listed" means**: a component from that universe is *not*
  reproduced below only if this document says so explicitly, in the
  "present but not linked" section near the end. Anything else missing from
  both sections is an omission, not a considered exclusion — file an issue.
- **How each of those files was classified** (reproduce below vs. not
  linked): a plain-text search (`grep -a -o`) for a symbol-mangling
  substring specific to that component's own C++ namespace or function
  names — not a generic word — across every `.lib` under
  `third_party/opencv/<hash>/ のライブラリディレクトリ（上表）`. A generic word is
  not enough: `cv::getBuildInformation()`'s own summary text is compiled
  into `opencv_core500.lib` as a string literal and contains lines like
  `Flatbuffers: builtin/3rdparty (25.9.23)`, so grepping for the bare word
  "flatbuffer" finds that summary text even when no FlatBuffers *code* is
  linked into any module built here. The commands below use identifiers
  that only exist if the component's own code was compiled in (C++ name
  mangling embeds namespaces and function names as literal ASCII, so this
  needs no special tooling — despite these `.lib` files using MSVC's
  "bigobj" object format, plain byte-level `grep` still finds them).

If the config hash above changes (a new OpenCV build, or `Modules` in
`tools/opencv-config.psd1` changes), re-run the searches below against the
new artifact and re-derive both this file and the allowlist in
`tools/verify-opencv-artifact.ps1` — do not assume the set of bundled
libraries, what's linked into them, or their license text is unchanged.

---

## zlib

License: zlib License (`third_party/opencv/<hash>/ のライセンスディレクトリ（上表）zlib-LICENSE`)

Linked into: `zlib.lib` (its own static library alongside the `opencv_*.lib`
module libraries — the one component here that doesn't need a symbol-table
search, since it ships as a separately named file).

```
Copyright notice:

 (C) 1995-2026 Jean-loup Gailly and Mark Adler

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.

  Jean-loup Gailly        Mark Adler
  jloup@gzip.org          madler@alumni.caltech.edu
```

---

## libpng

License: PNG Reference Library License version 2, with the version 1 terms
carried forward for pre-1.6.36 contributions
(`third_party/opencv/<hash>/ のライセンスディレクトリ（上表）libpng-LICENSE`)

Linked into: `libpng.lib` (its own static library). The artifact also
carries `etc/licenses/libpng-README`, libpng's own project README — it is
not license text (it points back to the same `LICENSE` file) and is not
reproduced here.

```
COPYRIGHT NOTICE, DISCLAIMER, and LICENSE
=========================================

PNG Reference Library License version 2
---------------------------------------

 * Copyright (c) 1995-2026 The PNG Reference Library Authors.
 * Copyright (c) 2018-2026 Cosmin Truta.
 * Copyright (c) 2000-2002, 2004, 2006-2018 Glenn Randers-Pehrson.
 * Copyright (c) 1996-1997 Andreas Dilger.
 * Copyright (c) 1995-1996 Guy Eric Schalnat, Group 42, Inc.

The software is supplied "as is", without warranty of any kind,
express or implied, including, without limitation, the warranties
of merchantability, fitness for a particular purpose, title, and
non-infringement.  In no event shall the Copyright owners, or
anyone distributing the software, be liable for any damages or
other liability, whether in contract, tort or otherwise, arising
from, out of, or in connection with the software, or the use or
other dealings in the software, even if advised of the possibility
of such damage.

Permission is hereby granted to use, copy, modify, and distribute
this software, or portions hereof, for any purpose, without fee,
subject to the following restrictions:

 1. The origin of this software must not be misrepresented; you
    must not claim that you wrote the original software.  If you
    use this software in a product, an acknowledgment in the product
    documentation would be appreciated, but is not required.

 2. Altered source versions must be plainly marked as such, and must
    not be misrepresented as being the original software.

 3. This Copyright notice may not be removed or altered from any
    source or altered source distribution.


PNG Reference Library License version 1 (for libpng 0.5 through 1.6.35)
-----------------------------------------------------------------------

libpng versions 1.0.7, July 1, 2000, through 1.6.35, July 15, 2018 are
Copyright (c) 2000-2002, 2004, 2006-2018 Glenn Randers-Pehrson, are
derived from libpng-1.0.6, and are distributed according to the same
disclaimer and license as libpng-1.0.6 with the following individuals
added to the list of Contributing Authors:

    Simon-Pierre Cadieux
    Eric S. Raymond
    Mans Rullgard
    Cosmin Truta
    Gilles Vollant
    James Yu
    Mandar Sahastrabuddhe
    Google Inc.
    Vadim Barkov

and with the following additions to the disclaimer:

    There is no warranty against interference with your enjoyment of
    the library or against infringement.  There is no warranty that our
    efforts or the library will fulfill any of your particular purposes
    or needs.  This library is provided with all faults, and the entire
    risk of satisfactory quality, performance, accuracy, and effort is
    with the user.

Some files in the "contrib" directory and some configure-generated
files that are distributed with libpng have other copyright owners, and
are released under other open source licenses.

libpng versions 0.97, January 1998, through 1.0.6, March 20, 2000, are
Copyright (c) 1998-2000 Glenn Randers-Pehrson, are derived from
libpng-0.96, and are distributed according to the same disclaimer and
license as libpng-0.96, with the following individuals added to the
list of Contributing Authors:

    Tom Lane
    Glenn Randers-Pehrson
    Willem van Schaik

libpng versions 0.89, June 1996, through 0.96, May 1997, are
Copyright (c) 1996-1997 Andreas Dilger, are derived from libpng-0.88,
and are distributed according to the same disclaimer and license as
libpng-0.88, with the following individuals added to the list of
Contributing Authors:

    John Bowler
    Kevin Bracey
    Sam Bushell
    Magnus Holmgren
    Greg Roelofs
    Tom Tanner

Some files in the "scripts" directory have other copyright owners,
but are released under this license.

libpng versions 0.5, May 1995, through 0.88, January 1996, are
Copyright (c) 1995-1996 Guy Eric Schalnat, Group 42, Inc.

For the purposes of this copyright and license, "Contributing Authors"
is defined as the following set of individuals:

    Andreas Dilger
    Dave Martindale
    Guy Eric Schalnat
    Paul Schmidt
    Tim Wegner

The PNG Reference Library is supplied "AS IS".  The Contributing
Authors and Group 42, Inc. disclaim all warranties, expressed or
implied, including, without limitation, the warranties of
merchantability and of fitness for any purpose.  The Contributing
Authors and Group 42, Inc. assume no liability for direct, indirect,
incidental, special, exemplary, or consequential damages, which may
result from the use of the PNG Reference Library, even if advised of
the possibility of such damage.

Permission is hereby granted to use, copy, modify, and distribute this
source code, or portions hereof, for any purpose, without fee, subject
to the following restrictions:

 1. The origin of this source code must not be misrepresented.

 2. Altered versions must be plainly marked as such and must not
    be misrepresented as being the original source.

 3. This Copyright notice may not be removed or altered from any
    source or altered source distribution.

The Contributing Authors and Group 42, Inc. specifically permit,
without fee, and encourage the use of this source code as a component
to supporting the PNG file format in commercial products.  If you use
this source code in a product, acknowledgment is not required but would
be appreciated.
```

---

## libjpeg-turbo

License: dual — the IJG License (for the libjpeg API) and the Modified
(3-clause) BSD License (for the TurboJPEG API and build system)
(`third_party/opencv/<hash>/ のライセンスディレクトリ（上表）libjpeg-turbo-LICENSE.md`)

Linked into: `libjpeg-turbo.lib` (its own static library). The artifact also
carries `etc/licenses/libjpeg-turbo-README.md`, the upstream project
README — not license text itself (it points to `LICENSE.md`, reproduced
below) and not reproduced separately. `libjpeg-turbo-README.ijg` **is**
license text (the IJG License in full) and is reproduced further down in
this section.

```
libjpeg-turbo Licenses
======================

libjpeg-turbo is covered by two compatible BSD-style open source licenses:

- The IJG (Independent JPEG Group) License, which is listed in
  README.ijg (reproduced below in this file, under "IJG License").

  This license applies to the libjpeg API library and associated programs,
  including any code inherited from libjpeg and any modifications to that
  code.  Note that the libjpeg-turbo SIMD source code bears the
  zlib License (https://opensource.org/licenses/Zlib), but in the context of
  the overall libjpeg API library, the terms of the zlib License are subsumed
  by the terms of the IJG License.

- The Modified (3-clause) BSD License, which is listed below

  This license applies to the TurboJPEG API library and associated programs, as
  well as the build system.  Note that the TurboJPEG API library wraps the
  libjpeg API library, so in the context of the overall TurboJPEG API library,
  both the terms of the IJG License and the terms of the Modified (3-clause)
  BSD License apply.


Complying with the libjpeg-turbo Licenses
==========================================

This section provides a roll-up of the libjpeg-turbo licensing terms, to the
best of our understanding.  This is not a license in and of itself.  It is
intended solely for clarification.

1.  If you are distributing a modified version of the libjpeg-turbo source,
    then:

    1.  You cannot alter or remove any existing copyright or license notices
        from the source.

        Origin: Clause 1 of the IJG License / Clause 1 of the Modified BSD
        License / Clauses 1 and 3 of the zlib License

    2.  You must add your own copyright notice to the header of each source
        file you modified, so others can tell that you modified that file.

        Origin: Clause 1 of the IJG License / Clause 2 of the zlib License

    3.  You must include the IJG README file, and you must not alter any of the
        copyright or license text in that file.

        Origin: Clause 1 of the IJG License

2.  If you are distributing only libjpeg-turbo binaries without the source, or
    if you are distributing an application that statically links with
    libjpeg-turbo, then:

    1.  Your product documentation must include a message stating:

        This software is based in part on the work of the Independent JPEG
        Group.

        Origin: Clause 2 of the IJG license

    2.  If your binary distribution includes or uses the TurboJPEG API, then
        your product documentation must include the text of the Modified BSD
        License (see below.)

        Origin: Clause 2 of the Modified BSD License

3.  You cannot use the name of the IJG or The libjpeg-turbo Project or the
    contributors thereof in advertising, publicity, etc.

    Origin: IJG License / Clause 3 of the Modified BSD License

4.  The IJG and The libjpeg-turbo Project do not warrant libjpeg-turbo to be
    free of defects, nor do we accept any liability for undesirable
    consequences resulting from your use of the software.

    Origin: IJG License / Modified BSD License / zlib License


The Modified (3-clause) BSD License
====================================

Copyright (C)2009-2024 D. R. Commander.  All Rights Reserved.
Copyright (C)2015 Viktor Szathmary.  All Rights Reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.
- Neither the name of the libjpeg-turbo Project nor the names of its
  contributors may be used to endorse or promote products derived from this
  software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS",
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

IJG License (reproduced from
`third_party/opencv/<hash>/ のライセンスディレクトリ（上表）libjpeg-turbo-README.ijg`,
LEGAL ISSUES section — the full README is retained verbatim per the
condition above, minus the sections not relevant to licensing):

```
LEGAL ISSUES
============

In plain English:

1. We don't promise that this software works.  (But if you find any bugs,
   please let us know!)
2. You can use this software for whatever you want.  You don't have to pay us.
3. You may not pretend that you wrote this software.  If you use it in a
   program, you must acknowledge somewhere in your documentation that
   you've used the IJG code.

In legalese:

The authors make NO WARRANTY or representation, either express or implied,
with respect to this software, its quality, accuracy, merchantability, or
fitness for a particular purpose.  This software is provided "AS IS", and you,
its user, assume the entire risk as to its quality and accuracy.

This software is copyright (C) 1991-2020, Thomas G. Lane, Guido Vollbeding.
All Rights Reserved except as specified below.

Permission is hereby granted to use, copy, modify, and distribute this
software (or portions thereof) for any purpose, without fee, subject to these
conditions:
(1) If any part of the source code for this software is distributed, then this
README file must be included, with this copyright and no-warranty notice
unaltered; and any additions, deletions, or changes to the original files
must be clearly indicated in accompanying documentation.
(2) If only executable code is distributed, then the accompanying
documentation must state that "this software is based in part on the work of
the Independent JPEG Group".
(3) Permission for use of this software is granted only if the user accepts
full responsibility for any undesirable consequences; the authors accept
NO LIABILITY for damages of any kind.

These conditions apply to any software derived from or based on the IJG code,
not just to the unmodified library.  If you use our work, you ought to
acknowledge us.

Permission is NOT granted for the use of any IJG author's name or company name
in advertising or publicity relating to this software or products derived from
it.  This software may be referred to only as "the Independent JPEG Group's
software".

We specifically permit and encourage the use of this software as the basis of
commercial products, provided that all warranty or liability claims are
assumed by the product vendor.
```

**Attribution required for this project's binary distribution** (per clause
2.1 above, since we ship libjpeg-turbo as a compiled binary, not source):

> This software is based in part on the work of the Independent JPEG Group.

---

## libclapack (CLAPACK)

License: BSD-3-Clause (University of Tennessee et al.)
(`third_party/opencv/<hash>/ のライセンスディレクトリ（上表）clapack-lapack_LICENSE`)

Linked into: `libclapack.lib` (its own static library, used by `core`'s
linear-algebra routines).

```
Copyright (c) 1992-2017 The University of Tennessee and The University
                        of Tennessee Research Foundation.  All rights
                        reserved.
Copyright (c) 2000-2017 The University of California Berkeley. All
                        rights reserved.
Copyright (c) 2006-2017 The University of Colorado Denver.  All rights
                        reserved.

$COPYRIGHT$

Additional copyrights may follow

$HEADER$

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

- Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer listed
  in this license in the documentation and/or other materials
  provided with the distribution.

- Neither the name of the copyright holders nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

The copyright holders provide no reassurances that the source code
provided does not infringe any patent, copyright, or any other
intellectual property rights of third parties.  The copyright holders
disclaim any liability to any recipient for claims brought against
recipient by any third party for infringement of that parties
intellectual property rights.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

---

## Berkeley SoftFloat

License: BSD-3-Clause (The Regents of the University of California)
(`third_party/opencv/<hash>/ のライセンスディレクトリ（上表）SoftFloat-COPYING.txt`)

Linked into: compiled directly into `opencv_core500.lib`,
`opencv_geometry500.lib`, and `opencv_imgproc500.lib` — not a separate
`.lib`, which is why it wasn't in the old "confirmed by `.lib` filename"
check. OpenCV vendors SoftFloat's algorithms as `cv::softfloat` /
`cv::softdouble` (`modules/core/src/softfloat.cpp`) for reproducible,
platform-independent IEEE 754 arithmetic.

Confirmed by (run from `third_party/opencv/<hash>/ のライブラリディレクトリ（上表）`):

```
grep -a -o "softfloat@cv@@\|softdouble@cv@@" opencv_core500.lib opencv_geometry500.lib opencv_imgproc500.lib
```

```
Copyright notice for Berkeley SoftFloat Release 3c:

John R. Hauser
2017 February 10

The following applies to the whole of SoftFloat Release 3c as well as to
each source file individually.

Copyright 2011, 2012, 2013, 2014, 2015, 2016, 2017 The Regents of the
University of California.  All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

 1. Redistributions of source code must retain the above copyright notice,
    this list of conditions, and the following disclaimer.

 2. Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions, and the following disclaimer in the
    documentation and/or other materials provided with the distribution.

 3. Neither the name of the University nor the names of its contributors
    may be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS "AS IS", AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, ARE
DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

---

## MSCR chi_table (Per-Erik Forssen)

License: custom BSD-style terms
(`third_party/opencv/<hash>/ のライセンスディレクトリ（上表）mscr-chi_table_LICENSE.txt`)

Linked into: `opencv_features500.lib`. This is a chi-squared lookup table
from Per-Erik Forssen's Maximally Stable Colour Regions (MSCR) paper, used
by OpenCV's MSER implementation (`modules/features/src/mser.cpp`). The
table itself is optimized away as inline constant data by the compiler (no
symbol named `chi_table` survives), so it can't be confirmed by name
directly; the surrounding MSCR machinery that only exists to use that table
does survive as named symbols, which is what's searched for below.

Confirmed by (run from `third_party/opencv/<hash>/ のライブラリディレクトリ（上表）`):

```
grep -a -o "MSCRNode\|MSCREdge\|preprocessMSER" opencv_features500.lib
```

```
                          License Agreement
                          For chi_table.h

Copyright (C) 2007 Per-Erik Forssen, all rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

  * Redistribution's of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.

  * Redistribution's in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.

  * The name of the copyright holders may not be used to endorse or promote products
    derived from this software without specific prior written permission.

This software is provided by the copyright holders and contributors "as is" and
any express or implied warranties, including, but not limited to, the implied
warranties of merchantability and fitness for a particular purpose are disclaimed.
In no event shall the Intel Corporation or contributors be liable for any direct,
indirect, incidental, special, exemplary, or consequential damages
(including, but not limited to, procurement of substitute goods or services;
loss of use, data, or profits; or business interruption) however caused
and on any theory of liability, whether in contract, strict liability,
or tort (including negligence or otherwise) arising in any way out of
the use of this software, even if advised of the possibility of such damage.
```

---

## annoylib

License: Apache License 2.0 (Spotify AB)
(`third_party/opencv/<hash>/ のライセンスディレクトリ（上表）annoylib-LICENSE`)

Linked into: `opencv_features500.lib`, under OpenCV's own `cvannoy`
namespace (`ANNIndexImpl` and related types) — an approximate nearest
neighbor index used by the descriptor matching machinery in `features`.

Confirmed by (run from `third_party/opencv/<hash>/ のライブラリディレクトリ（上表）`):

```
grep -a -o "cvannoy\|ANNIndexImpl" opencv_features500.lib
```

```
Copyright (c) 2013 Spotify AB

Licensed under the Apache License, Version 2.0 (the "License"); you may not
use this file except in compliance with the License. You may obtain a copy of
the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations under
the License.
```

---

## Rubik font

License: SIL Open Font License, Version 1.1 (The Rubik Project Authors)
(`third_party/opencv/<hash>/ のライセンスディレクトリ（上表）fonts-Rubik_OFL.txt`)

Linked into: `opencv_imgproc500.lib`, as OpenCV's "Built-in Unicode font"
(`cv::getBuildInformation()` reports `Built-in Unicode font: YES` for this
configuration) — the font used by drawing functions (e.g. `cv::putText`)
that render non-Latin text without a system font. This is a **different
license family from the rest of this document**: unlike the BSD/zlib/
Apache-style permissive licenses above, the SIL OFL requires that this
notice (or the license text) accompany any redistribution that bundles the
font, and forbids selling the font by itself.

Confirmed by (run from `third_party/opencv/<hash>/ のライブラリディレクトリ（上表）`):

```
grep -a -o "Rubik[A-Za-z0-9_.-]*" opencv_imgproc500.lib
```

which finds the embedded font file names `Rubik.ttf` and `Rubik-Italic.ttf`
directly.

```
Copyright 2015 The Rubik Project Authors (https://github.com/googlefonts/rubik),

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
http://scripts.sil.org/OFL


-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```

---

## cpufeatures (Android NDK)

License: BSD 3-Clause (`third_party/opencv/<hash>/ のライセンスディレクトリ（上表）cpufeatures-LICENSE`)

Linked into: `libcpufeatures.a` (its own static library alongside the
`libopencv_*.a`), **Android builds only**. It does not appear in the
Windows, macOS, Linux or iOS trees.

This is the Android NDK's runtime CPU feature detection library
(`sources/android/cpufeatures`), which OpenCV links on Android to choose
NEON / dot-product paths at run time. Copyright and license verified against
the NDK source on 2026-08-30:
<https://android.googlesource.com/platform/ndk/+/master/sources/android/cpufeatures/cpu-features.c>

OpenCV's Android install also ships `cpufeatures-README.md` in the same
licenses directory. It is the library's usage documentation, not a separate
licence — both files are covered by the BSD-3-Clause text below.

**BSD-3-Clause requires the copyright notice and disclaimer to be
reproduced in binary redistributions**, which is what the text below does.

```
Copyright (C) 2010 The Android Open Source Project
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
 * Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in
   the documentation and/or other materials provided with the
   distribution.
 * Neither the name of The Android Open Source Project nor the names
   of its contributors may be used to endorse or promote products derived
   from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS
OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

---

## protobuf

License: BSD 3-Clause (`third_party/opencv/<hash>/ のライセンスディレクトリ（上表）protobuf-LICENSE`)

Linked into: its own static library alongside the `opencv_*` module
libraries — `libprotobuf.lib` on Windows, `liblibprotobuf.a` on the other
five platforms. **The doubled `lib` prefix is not a typo and not this
repository's naming**: upstream protobuf's own CMake target is itself named
`libprotobuf`, so the platform's usual `lib` prefix is added on top of that
on Unix (confirmed against every platform's build log, run `34212296352`,
2026-09-08).

**This library is new as of `dnn` being added to `Modules`.** It was not
present, and not linked, in any earlier configuration. OpenCV's ONNX
importer (part of `dnn`) parses models that are serialized with protobuf,
so — unlike the optional codecs this document lists elsewhere — protobuf
is not something this package chose to enable for convenience: without it,
`dnn` does not compile at all (`tools/opencv-config.psd1` used to carry
`WITH_PROTOBUF=OFF` under its "value this project doesn't need" rationale;
that premise stopped holding the moment `dnn` was added, and the comment at
that line explains why rather than silently disappearing). The copy bundled
here is the version OpenCV vendors and builds from source — 3.19.1 — not
whatever protobuf a build machine happens to have installed
(`-DBUILD_PROTOBUF=ON`, for the same reproducibility reason `BUILD_ZLIB` /
`BUILD_PNG` / `BUILD_JPEG` are already `ON` above).

OpenCV's install also ships `protobuf-README.md` in the same licenses
directory. Like `cpufeatures-README.md` above, it is minimal
project/version metadata (name, upstream URL, bundled version number), not
a separate licence — both files are covered by the BSD-3-Clause text below.
Verified against OpenCV's own vendored copy at the `5.0.0` tag
(<https://github.com/opencv/opencv/blob/5.0.0/3rdparty/protobuf/LICENSE>),
which is byte-for-byte the same text upstream protobuf ships at its
`v3.19.1` tag.

**BSD-3-Clause requires the copyright notice and disclaimer to be
reproduced in binary redistributions**, which is what the text below does.

```
Copyright 2008 Google Inc.  All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
    * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Code generated by the Protocol Buffer compiler is owned by the owner
of the input file used when generating it.  This code is not
standalone and requires a support library to be linked with it.  This
support library is itself covered by the above license.
```

---

## flatbuffers

License: Apache License 2.0
(`third_party/opencv/<hash>/ のライセンスディレクトリ（上表）flatbuffers-LICENSE.txt`)

Linked into: `opencv_dnn500.lib` (Windows) / the platform-equivalent
`opencv_dnn` static library — the reading side of `dnn`'s TFLite importer
(`opencv_tflite` namespace: `Model`, `SubGraph`, `Operator`, `Tensor` and
friends), which walks a `.tflite` file through
`flatbuffers::Table`, `flatbuffers::VerifierTemplate`, `flatbuffers::Vector`,
`flatbuffers::String`, `flatbuffers::GetRoot` / `GetMutableRoot`,
`flatbuffers::ReadScalar` / `EndianScalar`, and related reader-side
machinery. **`FlatBufferBuilder` (the writer side) was searched for and not
found** — consistent with an importer that only ever reads models, never
serializes them.

**This library was previously listed below as "present but not linked."
That was correct when last checked, and stopped being correct the moment
`dnn` entered `Modules` (2026-09-08) — TFLite import is part of `dnn`.**
Confirmed by actually restoring a build that has `dnn` (run `34215362804`,
`./tools/opencv.ps1 restore`) and searching its `opencv_dnn500.lib`, not by
inference from compiler flags.

**Confirmed on two platforms, deliberately chosen for two different
name-mangling schemes** — Windows/MSVC (above) and Linux/Itanium
(`lib/libopencv_dnn.a` from the same run `34215362804`: `flatbuffers` → 164
matches, `dlpack` → 0 matches, and 0 matches for `dlpack` across every `.a`
in that tree). That second data point matters more than a second platform
would on its own, because the methodology defect described below is
specific to which mangling scheme a toolchain uses — confirming the same
classification under both schemes is what makes it trustworthy, not merely
having checked twice. **The remaining four platforms (macOS, iOS, Android,
Web) were not individually inspected.** They are inferred from building the
same `Modules` list from the same OpenCV source tree, not from grepping
their own `.a` files — record that as inference, not as a third data point.

**A methodology correction, recorded so the next search doesn't repeat it:**
the two earlier "zero matches" results for this component used patterns
containing `::`, e.g. `flatbuffers::`, mirroring how the identifier reads in
source. **That pattern cannot match on Windows.** MSVC's name-mangling
scheme (`?Verify@ConcatEmbeddingsOptions@opencv_tflite@@...`) does not
preserve `::` as literal text the way Itanium mangling (used by GCC/Clang on
the other five platforms) tends to keep readable substrings — it uses `@` as
a namespace separator instead. Searching for the **bare identifier**
(`flatbuffers`, no punctuation) is what actually finds it:

```
grep -a -o -i "flatbuffers" opencv_dnn500.lib | wc -l
```

returns several hundred matches, all of them decorated `opencv_tflite`
member-function names of the shape shown above — not the single
`cv::getBuildInformation()` summary-string hit this document previously
noted in `opencv_core500.lib` (that hit is still there, and is still just
build-info text, not code). **This does not retroactively make the earlier
"zero matches" wrong for what they actually tested** — the tree they ran
against had no `dnn`, so there was no flatbuffers-using code to find
regardless of pattern. It does mean the `::`-containing pattern shape is
unreliable on Windows going forward and bare identifiers should be
preferred, especially for any future search on `.lib` (not `.a`) files.

**Apache License 2.0 requires a copy of the license to accompany
redistribution**, which is what the text below does — the same text OpenCV
itself vendors at `3rdparty/flatbuffers/LICENSE.txt` (verified against the
`5.0.0` tag,
<https://github.com/opencv/opencv/blob/5.0.0/3rdparty/flatbuffers/LICENSE.txt>).

```

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

---

## Present in `etc/licenses/` but not linked into this build

One file remains here — **not two.** `flatbuffers` used to be listed
alongside `dlpack` in this section; it moved up to its own reproduced
section above once `dnn` (which actually uses it, via the TFLite importer)
entered `Modules` and a real build could be searched. See that section for
the full story, including a methodology correction that applies to this
section too.

- **dlpack** (Apache License 2.0) —
  `third_party/opencv/<hash>/ のライセンスディレクトリ（上表）dlpack-LICENSE`. Searched
  the restored `dnn`-enabled tree (run `34215362804`) for the bare
  identifiers `DLTensor`, `DLDevice`, `DLDataType`,
  `DLManagedTensor`, `dlpack` (case-insensitive, no `::` — see the
  methodology note above) across every `.lib` in
  `x64/vc17/staticlib/`; zero matches, all patterns, all files. Confirmed a
  second time on the Linux artifact from the same run (`dlpack`, zero
  matches across every `.a` in that tree) — same two-mangling-scheme
  reasoning as the `flatbuffers` entry above. The other four platforms were
  not individually inspected; they are inferred from the same `Modules`
  list and source tree.

**Both components were attributed to OpenCV modules (`dnn`, `gapi`) that
were not in this configuration's `Modules` list. That premise is now false
for `dnn`** (added 2026-09-08) **and still true for `gapi`**, which remains
outside `Modules` and outside this build entirely. dlpack staying unlinked
despite `dnn` now being built is consistent with it being a header-only
type-definition library (`DLManagedTensor` et al. are C structs, not
functions) — nothing in this build's compiled sources instantiates them in
a way that leaves a distinct symbol behind, unlike flatbuffers' `Table` /
`Vector` reader templates, which do generate real code. Its license text is
kept here for completeness — so the inventory is fully accounted for — but
is not reproduced, because nothing of it ships.

If a future `Modules` list adds `gapi`, or if `dlpack` starts matching in a
later search (a genuinely different call site could reference the structs
in a way that survives into object code), re-run the search above and move
it up.

---

## OpenCV itself

OpenCV 5.0.0 is Apache License 2.0. See
`third_party/opencv/<hash>/LICENSE` in the restored artifact for the
full text; it is not reproduced here since it is the same license as this
repository's own code.
