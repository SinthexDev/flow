# Sinthex Flow

Dictation for the macOS menu bar. Speech stays on the device. An optional correction step can use your own OpenAI key.

The name shown in the app comes from `CFBundleDisplayName`. The interface text follows that name.

**Author: Sinthex**

**Version 1.28.2** · [Changelog](https://sinthex.de/flow/changelog.html?lang=en) · [changelog.md](https://sinthex.de/flow/changelog.md)

Project page: <https://sinthex.de/flow/>  
Installer: <https://sinthex.de/flow/Sinthex-Flow-1.28.2.pkg>  
Source: <https://github.com/SinthexDev/flow>

![Home](docs/screenshots/main-home.png)

## 1.28.2 — October 21, 2026

- **Improvement** — Choosing the speech engine now uses the full width: four cards with a speed indicator, and below them the strengths of the selected engine.

## 1.28.1 — October 21, 2026

- **Bugfix** — While correcting, the menu bar now shows sparkles instead of the dotted circle. Recognition and translation have their own symbols.

## 1.28.0 — October 21, 2026

- **New** — Two more local speech engines: Parakeet (fast for German and EU) and Qwen3-ASR (more languages, still on device). Settings show speed, languages, and size for each engine.

The full history is on the [changelog](https://sinthex.de/flow/changelog.html?lang=en).

## What Sinthex Flow does

- Record with the Fn key. Double-tap for hands-free speech. Esc cancels.
- Recognition runs locally on Apple Silicon (Whisper, Whistle, Parakeet, or Qwen3-ASR). That audio does not leave the Mac.
- Optional correction with your own OpenAI key. The key stays in the Keychain, not in a config file and not in this repository. Settings can point at another OpenAI-compatible address, including a local model. The key stays optional and in the Keychain.
- The correction model is chosen from the key. Sinthex Flow suggests the latest fast model. You can pin another one.
- Style follows the frontmost app, for example coding in an editor and email in Mail. Each app can have its own style.
- The text is inserted into the active field.
- Command mode: select text, hold Fn, and say what to do. “Translate this into English”, “Summarize this in one sentence”, “Make this friendlier”, “Turn this into a bullet list”. Sinthex Flow replaces the selection with the result. The Commands tab shows nine examples.

Sinthex Flow is a menu-bar app for macOS 14 or newer, on Apple Silicon.

The interface follows the first system language. The official languages of Europe ship as `Languages/<code>.json`, plus regional official languages such as Catalan, Basque, Irish, and Romansh. The keys live in `en.json`. If a language is missing, German stays German and every other language uses English. A file in `~/Library/Application Support/Sinthex Flow/Languages` adds or overrides the same language and is read on the next launch. A missing key falls back to English.

## License

Sinthex Flow is released under the [MIT License](LICENSE).

Copyright (c) 2026 Sinthex.

You may use, modify, and distribute Sinthex Flow, including in your own products. The copyright notice and the license text must stay intact. There is no warranty. The full text is in [LICENSE](LICENSE).

Sinthex Flow builds on other open-source projects, chiefly mlx-whisper, MLX, mlx-vlm, and the Whisper model weights from OpenAI. Their licenses apply as well and are printed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Privacy

API keys, certificates, PKCS#12 files, and dictations do not belong in this repository. The OpenAI key stays in the macOS Keychain (`de.sinthex.flow` / `openai-api-key`). Configuration and history stay on the Mac under `~/Library/Application Support/Sinthex Flow/` and are excluded from Git.

The update check sends two values to the update address: the installed version and a SHA-256 hash of the salted hardware UUID. That hash counts Macs. It carries no computer name, no user name, and no dictated text. The code is in `Sources/Flow/UpdateCheck.swift`.

## Build

Requirements: macOS 14, Apple Silicon, Xcode command-line tools, [uv](https://docs.astral.sh/uv/), and Python 3.12.

```bash
./scripts/install.sh
```

The script creates a virtual environment at `~/Library/Application Support/Sinthex Flow/.venv`, installs the engine, downloads the Whisper weights, and builds `Sinthex Flow.app`.

The local code-signing identity stays stable across updates, so microphone and accessibility permission are not requested again each time. The password for the local certificate stays outside the repository, in `~/Library/Application Support/Sinthex Flow/signing/password` or in the `FLOW_SIGNING_PASSWORD` environment variable.

The engine on its own:

```bash
uv pip install --python ~/Library/Application\ Support/Sinthex\ Flow/.venv/bin/python ./engine
```

It listens on `127.0.0.1:17321`.

## Updates

Sinthex Flow reads its update address from `Sources/Flow/UpdateCheck.swift` and downloads the package named in `latest.json`. Where the site is uploaded is set in `scripts/publish_site.sh` (`REMOTE`, `BASE`). A fork puts its own host in those two places.
