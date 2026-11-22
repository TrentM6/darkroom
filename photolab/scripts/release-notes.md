## Install or update

Paste this into Terminal:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/TrentM6/darkroom/main/install.sh)"
```

**Don't download the zip below in a browser and open it.** Darkroom isn't signed with an Apple Developer ID, so macOS blocks a browser download ("can't be opened"). The command downloads the same app without that block, checks it against its SHA-256, and sets up RawTherapee and the film simulation library it needs. Running it again updates Darkroom; your library is never touched.

The zip and its `.sha256` are here for the installer. macOS 14 or later, Apple Silicon (Intel Macs build from source through the same command).
