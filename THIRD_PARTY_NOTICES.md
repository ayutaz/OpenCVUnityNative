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
  | macOS / Linux / iOS | `lib/*.a` | `share/licenses/opencv5/` |
  | Android | `sdk/native/staticlibs/arm64-v8a/*.a` | `sdk/etc/licenses/` |
- Modules built for this configuration (`tools/opencv-config.psd1`):
  `core`, `imgproc`, `imgcodecs`, `objdetect`, `features`, plus `flann` and
  `geometry`, pulled in transitively (`tools/verify-opencv-artifact.ps1`
  `$AcceptedTransitiveModules`).
- **Universe considered**: every file under
  `third_party/opencv/<hash>/ のライセンスディレクトリ（上表）` in the restored artifact
  (`./tools/opencv.ps1 restore`) — **13 files** on the desktop and iOS configurations, **15 on Android**
  (`cpufeatures-LICENSE` and `cpufeatures-README.md`, both from the NDK) as of
  this hash. This is the
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

## Present in `etc/licenses/` but not linked into this build

Two of those files are license texts for components that OpenCV's build
system attributes generally, but a symbol-table search of every `.lib`
under the platform's library directory (see the table above) for identifiers
specific to each found nothing.
Both belong to OpenCV modules (`dnn`, `gapi`) that are **not** in this
configuration's `Modules` list (`tools/opencv-config.psd1`), so their code
was never compiled into anything this package ships. Their license text is
listed here for completeness — so the inventory is fully
accounted for — but is not reproduced, because nothing of theirs ships.

- **dlpack** (Apache License 2.0) —
  `third_party/opencv/<hash>/ のライセンスディレクトリ（上表）dlpack-LICENSE`. Searched
  for `DLManagedTensor`, `DLPackVersioned`, `dlpack` (case-insensitive)
  across every `.lib`; zero matches.
- **flatbuffers** (Apache License 2.0) —
  `third_party/opencv/<hash>/ のライセンスディレクトリ（上表）flatbuffers-LICENSE.txt`.
  Searched for `flatbuffers::`, `FlatBufferBuilder`, `flatbuffers_`; zero
  matches. (`opencv_core500.lib` does contain the bare word "Flatbuffers"
  once, but only inside the embedded `cv::getBuildInformation()` summary
  string — see the note in "Scope of this document" above about why that
  doesn't count as linked code.)

If a future `Modules` list adds `dnn` or `gapi`, re-run these searches —
they will very likely start matching, and these two need to move up into
the reproduced sections above.

---

## OpenCV itself

OpenCV 5.0.0 is Apache License 2.0. See
`third_party/opencv/<hash>/LICENSE` in the restored artifact for the
full text; it is not reproduced here since it is the same license as this
repository's own code.
