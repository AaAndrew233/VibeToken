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
> This is an early preview. Twenty-two AI coding sources are supported now. The app is not yet distributed as an Apple-notarized package.

## Preview

<p align="center">
  <img src="docs/screenshots/menu-popover.png" width="500" alt="VibeToken menu bar popover showing token usage, estimated cost, trends, distributions, and relay capacity">
</p>

## Features

- Automatic usage collection from 22 AI coding sources, with no simulated increments.
- Today, rolling 24-hour, 7-day, and 30-day totals and trends.
- Input, cache, output, reasoning, model, tool, and session breakdowns.
- Versioned OpenAI, Anthropic, and Google API price estimates with pricing coverage shown explicitly.
- Duplicate emission and fork/subagent replay filtering.
- Optional read-only Sub2API pool monitoring with per-account remaining quota and explicit rate-limited or unavailable states for Codex 5-hour and 7-day windows.
- Native macOS menu bar and Dock entry points in English and Simplified Chinese.

## Support

| Source | Status |
| --- | --- |
| Codex Desktop / CLI | Supported: live and archived sessions, including local profiles |
| Claude Code + Claude Desktop Code/Cowork | Supported: project logs, profiles, and Cowork session roots |
| Gemini CLI | Supported: current JSONL, legacy JSON, and nested subagent sessions |
| OpenCode | Supported: read-only SQLite with legacy JSON fallback |
| GitHub Copilot CLI | Supported: exact shutdown model metrics |
| Cursor | Supported: official account usage export, refreshed at most every 5 minutes |
| Cline | Supported: standalone and VS Code-family task logs with migrated-copy deduplication |
| Roo Code | Supported: VS Code-family task logs, including current and legacy indexes |
| Kiro CLI | Supported: native session logs; Token totals are explicitly estimated from observed text |
| Grok Build TUI / CLI | Supported: exact per-turn usage and per-model splits |
| DimAgent | Supported: read-only usage ledger with fork replay deduplication |
| OpenClaw | Supported: agent sessions, named profiles, and legacy data roots |
| pi | Supported: exact assistant-message usage, including cache reads and writes |
| Qwen Code | Supported: Gemini-style usage metadata with exclusive cache and reasoning categories |
| Kimi Code | Supported: current agent wires and legacy Kimi session stores |
| MiMoCode | Supported: read-only SQLite; imported external sessions are excluded |
| Amp | Supported: usage ledger with message-level fallback |
| Droid | Supported: exact cumulative totals; time distribution is derived from observed growth |
| Hermes | Supported: default and named-profile SQLite stores |
| Trae CLI | Supported: trace-level model usage with span deduplication |
| Antigravity | Supported: current offline protobuf databases and legacy local language-server fallback |
| ZCode | Supported: read-only message usage database |
| Sub2API Codex account pool | Supported, optional |

VibeToken does not infer exact token usage from ChatGPT or Claude desktop conversations. Subscription usage and API-priced cost are different things, so estimated cost is always labeled as an estimate.

## Install

Requirements: macOS 14+ and Xcode 16 or Swift 6 command-line tools. On launch, VibeToken automatically discovers every supported source. There is no source setup, folder picker, or manual scan step. Missing tools are skipped without blocking the sources that are available.

```bash
git clone https://github.com/giraffegzy-bot/VibeToken.git
cd VibeToken
swift test
./scripts/build-app.sh
open "dist/VibeToken.app"
```

The build script creates an ad-hoc signed app at `dist/VibeToken.app` and embeds Sparkle. The public EdDSA update key and the stable GitHub Pages appcast URL are stored in `Info.plist`. The appcast is published from `Distribution/Sparkle/appcast.xml`; it remains empty until a Developer ID signed, notarized, and Sparkle-signed release is ready. The local build is suitable for development, but it is not equivalent to a public release.

The Sparkle feed uses HTTPS. Never commit the Sparkle private key; only its public EdDSA key is embedded in the app. A production update still requires a Developer ID signed and notarized archive and a Sparkle-signed update entry in the appcast.

### Sharing

- For source distribution, share the GitHub repository. Do not archive the entire development folder: `.git`, `.build`, `dist`, local notes, and editor files are not part of the source release.
- For a temporary binary handoff, compress only `dist/VibeToken.app`. Because the current build is ad-hoc signed and not notarized, another Mac may show a Gatekeeper warning.
- A public end-user release should use Developer ID signing, Apple notarization, and a versioned archive or DMG.

## Usage

1. Open VibeToken and click its menu bar item.
2. Choose Today, 24H, 7D, or 30D.
3. Select live, 5-minute, 30-minute, or manual refresh for local usage collection. A connected Sub2API pool checks account membership every 30 seconds and performs a verified quota refresh every 30 minutes.
4. Use the language control to switch between English and Simplified Chinese.

For optional Sub2API monitoring, open Relay Capacity settings and sign in with an administrator account. After the first sync, each detected `Plus` account uses `Plus` (1x), while every detected `Pro` account must be assigned `Pro 5x`, `Pro 10x`, or `Pro 20x` manually. An unconfigured Pro account does not receive a guessed default, and pool capacity remains unavailable until it is configured. App startup, Mac wake, a user-initiated refresh, a changed account pool, and the 30-minute schedule all request Sub2API's official usage probe with `force=true`. On released servers without the batch route, VibeToken falls back to the released per-account endpoint with `source=active&force=true` and at most six concurrent requests. It then reads the account list back until every active physical account has a newly persisted, valid 5-hour and 7-day snapshot, or an explicit unavailable or exhausted state. The pool total is published only after the entire set passes validation. A partial or unverifiable refresh hides the current total, reports the verified account count, and keeps only the timestamp of the last successful refresh. VibeToken does not reset, edit, or delete relay accounts.

## Accuracy

Token totals come from structured usage fields. Kiro CLI is the exception: its native session log has no Token counters, so VibeToken labels its text-based estimate accordingly. Cost is estimated from known model prices:

```text
estimated cost = input * input price
               + cache write * input price
               + cache read * cache price
               + (output + reasoning) * output price
```

Unknown models remain unpriced instead of receiving a guessed fallback price. Historical usage is currently recalculated with the price catalog bundled in the installed app.

The bundled catalog records its verification date, effective dates, and official OpenAI, Anthropic, and Google source URLs. A usage snapshot selects time-limited pricing from its latest event timestamp; for example, Claude Sonnet 5 switches from its introductory price on September 1, 2026. A range that crosses a price-change boundary therefore remains an aggregate estimate rather than an invoice-grade event-by-event calculation. OpenCode reuses the matching provider price when its model identifier is recognized.

Cache writes use the normal input price. The current estimator does not apply per-request long-context premiums or Gemini cache-storage time because aggregated local logs do not preserve those billing dimensions reliably. Subscription plans, free tiers, provider discounts, taxes, and tool-call charges are also excluded. Token usage is still counted when a model has no matching bundled price; the UI marks the cost as partial or unavailable instead of inventing a rate.

Pricing sources: [OpenAI](https://developers.openai.com/api/docs/pricing/), [Anthropic](https://platform.claude.com/docs/en/about-claude/pricing), and [Google Gemini](https://ai.google.dev/gemini-api/docs/pricing).

For Sub2API, physical account counts remain unweighted. The UI shows `available / total` for each plan, for example `Plus 7/8 · Pro 4/4`. Capacity is weighted as `Plus = 1`, `Pro 5x = 5`, `Pro 10x = 10`, and `Pro 20x = 20`, then normalized to `100%`. Each account contributes the smaller remaining value of its 5-hour and 7-day windows. Temporarily unavailable, explicitly rate-limited, exhausted, stale, or unobserved accounts remain in the total capacity denominator but contribute zero currently available capacity. Shadow accounts are excluded.

## Privacy

- Only structured usage, model, project, session, and timestamp fields are extracted. Conversation content is never stored or sent.
- Source JSON/JSONL files and SQLite databases are opened read-only.
- Cursor is the only usage source that requires a provider request: VibeToken reads the existing Cursor access token from `state.vscdb` in memory and sends it only to `https://cursor.com` to fetch the official usage CSV. The token and response body are not persisted or logged.
- Legacy Antigravity `.pb` history is decoded only through its already-running language server on `127.0.0.1`; its CSRF token is kept in memory and never logged. Current Antigravity `.db` history is read offline.
- Usage indexes stay in the local application support directory.
- Tokens, passwords, cookies, account addresses, and response bodies are excluded from logs.
- Sub2API credentials are stored in local files with restricted permissions, not in macOS Keychain. This is less protected than Keychain against other processes running as the same macOS user.

## Development

VibeToken is an independent Swift implementation. It has no runtime dependency on another usage collector: each adapter reads the supported tool's structured local data or documented account export directly.

```bash
swift build
swift test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) before changing a data source, usage formula, persistence model, or security boundary.

## License

[MIT](LICENSE)
