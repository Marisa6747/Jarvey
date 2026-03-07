# Jarvey

<p align="center">
  <img src="docs/assets/jarvey-logo-black.png" alt="Jarvey logo" width="180" />
</p>

<p align="center">
  <strong>Voice-first macOS desktop agent.</strong><br/>
  Talk to your computer. Jarvey listens, plans, and acts.
</p>

<p align="center">
  <a href="https://getjarvey.com">Website</a> &middot;
  <a href="../../releases/latest">Download</a> &middot;
  <a href="https://novyn.ai">Novyn Labs</a> &middot;
  <a href="mailto:jarvey@novyn.ai">Support</a>
</p>

---

> **Warning:** Jarvey is a computer-use agent (CUA). It can click, type, approve dialogs, move or delete data, and interact with third-party applications on your behalf. CUAs are inherently risky. Only use Jarvey on systems and accounts you control. By using this project you accept those risks; the maintainers assume no responsibility or liability for loss, damage, misuse, data exposure, account actions, or other consequences.

## What is Jarvey?

Jarvey is a native macOS desktop agent that you control with your voice. It combines a Swift overlay app, a local Node sidecar, OpenAI Realtime for voice, and GPT-5.4 for planning and tool use -- all running on your machine. Press a hotkey, speak, and Jarvey carries out tasks across your desktop: opening apps, filling forms, navigating UIs, managing files, and more.

Built by [Novyn Labs](https://novyn.ai).

## Features

- **Voice-first interaction** -- global `Option+Space` hotkey activates a native SwiftUI/AppKit overlay; speak naturally to give instructions
- **Real-time voice** -- hidden `WKWebView` runtime connects to OpenAI Realtime for low-latency audio streaming
- **Intelligent planning** -- GPT-5.4 supervisor coordinates GUI and workbench specialists to break down and execute multi-step tasks
- **Native computer control** -- built-in bridge for screenshots, mouse clicks, keyboard input, scrolling, and drag operations
- **Durable memory** -- local SQLite-backed memory store with policy gating and approval support, so Jarvey remembers context across sessions
- **Permission-aware** -- native handling for Microphone, Screen Recording, and Accessibility permissions with guided onboarding

## Download

Grab the latest packaged build from [GitHub Releases](../../releases/latest).

- The release is a self-contained macOS zip archive: `Jarvey-<version>-macos-<arch>.zip`
- Public builds are ad-hoc signed, not notarized. On first launch macOS may require **Open Anyway** in System Settings, or right-click then **Open**.

## Requirements

| Requirement | Details |
|---|---|
| **OS** | macOS 14 (Sonoma) or newer |
| **API key** | OpenAI API key |
| **Permissions** | Microphone, Screen Recording, Accessibility |

For building from source you also need:

- Node.js 20 or 22
- Swift 6 / Xcode Command Line Tools

## Getting Started

### 1. Install from a release

Download and unzip the [latest release](../../releases/latest), then open `Jarvey.app`. On first launch the onboarding flow will walk you through granting permissions and entering your API key.

### 2. Build from source

```bash
git clone <repo-url> && cd jarvey-desktop
npm install
npm run dev
```

`npm run dev` builds the sidecar, builds the voice runtime, packages `dist-native/Jarvey.app`, and launches it.

You can also run each step individually:

```bash
npm run build:sidecar   # compile the Node sidecar
npm run build:voice     # compile the browser voice runtime
npm run build:native    # compile Swift + package Jarvey.app
npm run launch:native   # launch the packaged app
```

### 3. Configure your API key

You can enter your key directly in the app, or set it via environment variable:

```bash
cp .env.example .env
# edit .env and add your OpenAI API key
```

See [.env.example](.env.example) for all available options.

## Architecture

```
Option+Space (global hotkey)
  |
  v
JarveyNative  (Swift overlay app)
  |-- Overlay panel + status-bar item
  |-- Onboarding + permission coordinator
  |-- Hidden WKWebView voice runtime  -->  OpenAI Realtime (audio)
  |-- Screen capture controller
  |
  v
Local Sidecar  (Node, http://127.0.0.1:4818)
  |-- Agent runtime (GPT-5.4 supervisor + specialists)
  |-- Approval hub
  |-- Durable memory (SQLite)
  |-- Settings persistence
  |
  v
Native Input Bridge  (http://127.0.0.1:4819)
  |-- Mouse clicks, drags, scrolling
  |-- Keyboard input + key synthesis
  |-- Screenshot capture
```

Both local servers bind to `127.0.0.1` only and are never exposed to the network.

## Project Layout

```
Sources/JarveyNative/       Swift app: overlay UI, permissions, voice host, input server
src/main/backend/           Agent orchestration, approvals, memory, computer bridge
src/sidecar/                Local HTTP sidecar
src/voice/                  Hidden browser voice runtime
src/shared/                 Shared types, schemas, and defaults
src/renderer/               Renderer components and utilities
Tests/JarveyNativeTests/    Swift tests for parsers, keyboard, and permissions
scripts/                    Build, packaging, and release scripts
.github/workflows/          CI and release workflows
```

## Configuration

Jarvey stores all local state under `~/Library/Application Support/Jarvey/`:

| Path | Contents |
|---|---|
| `config/settings.json` | User settings and API key |
| `logs/` | Runtime logs |
| `memory/` | Durable memory records |

When launched from a packaged `.app`, Jarvey defaults shell and patch operations to your home directory. When launched via `npm run launch:native`, it uses the project root.

## Building a Release

To produce the distributable archive used for GitHub Releases:

```bash
npm run build:release
```

This outputs:

- `dist-native/Jarvey.app`
- `dist-native/Jarvey-<version>-macos-<arch>.zip`
- `dist-native/Jarvey-<version>-macos-<arch>.zip.sha256`

The app bundle includes the sidecar, voice runtime, and a vendored Node runtime, so no source checkout is needed to run it.

### GitHub Release Flow

1. Push the repository to GitHub.
2. Tag a version: `git tag v0.1.0 && git push --tags`
3. The [release workflow](.github/workflows/release.yml) builds the macOS archive and publishes it to [GitHub Releases](../../releases/latest).

## Validation

Run the full local validation suite:

```bash
npm run ci
```

This runs type-checking, Vitest unit tests, Swift tests, sidecar and voice builds, and the public-repo safety check.

Run just the public-release scan:

```bash
npm run check:public
```

## Privacy

**Sent to OpenAI:** User requests, transcript context, screenshots, and voice/audio data required for model interaction.

**Stored locally on disk:** Settings, runtime logs, and durable memory records.

Jarvey does not include analytics or third-party telemetry.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions and development workflow.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting guidelines.

## Code of Conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE)
