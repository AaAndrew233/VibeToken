# VibeToken

<p align="center">
  <img src="docs/assets/app-icon.png" width="128" alt="VibeToken app icon">
</p>

<p align="center">
  A local-first macOS menu bar app for tracking AI coding token usage, estimated cost, and relay account capacity.
</p>

<p align="center">
  <a href="README.zh-CN.md">简体中文</a>
  ·
  <a href="#install">Install</a>
  ·
  <a href="#privacy">Privacy</a>
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="MIT License" src="https://img.shields.io/badge/license-MIT-green">
</p>

VibeToken is built for developers who use AI coding tools throughout the day and want one quick, honest view of local usage without opening multiple dashboards.

> [!NOTE]
> This is an early preview. Codex Desktop and Codex CLI usage tracking are available now. Other coding tools are planned. The app is not yet distributed as an Apple-notarized package.

## Preview

<p align="center">
  <img src="docs/screenshots/menu-popover.png" width="500" alt="VibeToken menu bar popover showing token usage, estimated cost, trends, distributions, and relay capacity">
</p>

## Features

- Live local usage from Codex Desktop and Codex CLI sessions, with no simulated increments.
- Today, rolling 24-hour, 7-day, and 30-day totals and trends.
- Input, cache, output, reasoning, model, tool, and session breakdowns.
- Per-model API price estimates with pricing coverage shown explicitly.
- Duplicate emission and fork/subagent replay filtering.
- Optional read-only Sub2API pool monitoring for Codex 5-hour and 7-day windows.
- Native macOS menu bar UI in English and Simplified Chinese.

## Support

| Source | Status |
| --- | --- |
| Codex Desktop / CLI | Supported |
| Sub2API Codex account pool | Supported, optional |
| Claude Code | Planned |
| Gemini CLI / OpenCode | Planned |

VibeToken does not infer exact token usage from ChatGPT or Claude desktop conversations. Subscription usage and API-priced cost are different things, so estimated cost is always labeled as an estimate.

## Install

Requirements: macOS 14+, Xcode 16 or Swift 6 command-line tools, and existing Codex session data in `~/.codex/sessions`.

```bash
git clone https://github.com/giraffegzy-bot/VibeToken.git
cd VibeToken
swift test
./scripts/build-app.sh
open "dist/VibeToken.app"
```

The build script creates an ad-hoc signed app at `dist/VibeToken.app`. It is suitable for local use, but it is not equivalent to a Developer ID signed and notarized release.

## Usage

1. Open VibeToken and click its menu bar item.
2. Choose Today, 24H, 7D, or 30D.
3. Select live, 5-minute, 30-minute, or manual refresh.
4. Use the language control to switch between English and Simplified Chinese.

For optional Sub2API monitoring, open Relay Capacity settings and sign in with an administrator account. VibeToken only reads account and Codex window data. It does not reset, edit, or delete relay accounts.

## Accuracy

Token totals come from structured local usage fields. Cost is estimated from known model prices:

```text
estimated cost = input * input price
               + cache write * input price
               + cache read * cache price
               + (output + reasoning) * output price
```

Unknown models remain unpriced instead of receiving a guessed fallback price. Historical usage is currently recalculated with the price catalog bundled in the installed app.

For Sub2API, every eligible physical account contributes `100%` total capacity. Actual available capacity uses the smaller remaining value of its 5-hour and 7-day windows. Explicit runtime rate limits and exhausted windows take priority over stale snapshot timestamps. Shadow accounts are excluded.

## Privacy

- Conversation content is never read or stored.
- Codex JSONL files are read-only.
- Usage indexes stay in the local application support directory.
- Tokens, passwords, cookies, account addresses, and response bodies are excluded from logs.
- Sub2API credentials are stored in local files with restricted permissions, not in macOS Keychain. This is less protected than Keychain against other processes running as the same macOS user.

## Development

```bash
swift build
swift test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) before changing a data source, usage formula, persistence model, or security boundary.

## License

[MIT](LICENSE)
