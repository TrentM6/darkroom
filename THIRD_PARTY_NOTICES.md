# Third-party notices

Baseline Darkroom's own code is under the MIT License (see `LICENSE`). It includes, or works with, the
following third-party material. This file ships inside the app (`Contents/Resources/THIRD_PARTY_NOTICES.md`).

## Included in the app and this repository

### Lucide icons (ISC; some icons MIT, from Feather)

The interface icons in `photolab/Sources/PhotoLabCore/Resources/studio/js/icons.js` are drawn from, or based
on, [Lucide](https://lucide.dev).

```
ISC License

Copyright (c) 2026 Lucide Icons and Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

Lucide icons derived from the Feather project are also under the MIT License:

```
The MIT License (MIT)

Copyright (c) 2013-present Cole Bemis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Geist and Geist Mono (SIL Open Font License 1.1)

Copyright (c) 2023 Vercel, in collaboration with basement.studio. The full licence is in
`photolab/Sources/PhotoLabCore/Resources/studio/fonts/Geist-OFL.txt`, next to the font files.

## Not included: downloaded from the original source

These are never part of this repository or of the app download. The installer (`install.sh`) fetches them from
their publishers, on the user's own Mac.

### RawTherapee 5.11 (GPL-3.0)

The rendering engine. Baseline Darkroom runs RawTherapee's `rawtherapee-cli` as a separate program; it does not
link to it or include it. The installer downloads the official build, signed by the RawTherapee developers, from
[rawtherapee.com](https://rawtherapee.com) into `/Applications`. Source code:
[github.com/Beep6581/RawTherapee](https://github.com/Beep6581/RawTherapee).

### RawTherapee Film Simulation Collection (CC BY-SA 4.0)

The film LUTs, by Pat David, Pavlov Dmitry and Michael Ezra, downloaded by the installer from
[rawtherapee.com](https://rawtherapee.com/shared/HaldCLUT.zip). Licence:
[creativecommons.org/licenses/by-sa/4.0](https://creativecommons.org/licenses/by-sa/4.0/).

Film stock names (Kodachrome, Portra, Velvia and so on) identify the stock each LUT approximates. They are
trademarks of their owners; Baseline Darkroom is not affiliated with or endorsed by them.

## Not included: private builds only

### Satoshi (ITF Free Font License)

The maintainer's own build uses Satoshi for body text. Its licence does not allow redistributing the font files,
so they are not in this repository or the app download; those builds use Geist instead. To use Satoshi in your
own build, download it from [fontshare.com](https://www.fontshare.com/fonts/satoshi) and put
`Satoshi-Variable.woff2` in `photolab/Sources/PhotoLabCore/Resources/studio/fonts/` (it is git-ignored).
