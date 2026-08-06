# Contributing to VibeToken

Bug fixes, focused documentation improvements, and tests are welcome. Please open an issue before implementing a new data source or changing usage formulas, persistence, or security behavior.

Never commit real session logs, service URLs, email addresses, passwords, tokens, cookies, or other personal data.

## Local development

Requirements: macOS 14+ and Xcode 16 or Swift 6 command-line tools.

```bash
git clone https://github.com/giraffegzy-bot/VibeToken.git
cd VibeToken
swift test
swift run VibeToken
```

Build the app bundle with:

```bash
./scripts/build-app.sh
open "dist/VibeToken.app"
```

## Pull requests

1. Keep each pull request focused and avoid unrelated refactors.
2. Cover new behavior and important failure or boundary cases with tests.
3. Document input fields, formulas, deduplication, and unknown-data handling for usage changes.
4. Add timeouts and bounded pagination or concurrency for external services.
5. Verify English and Simplified Chinese UI at the `500x720` menu size.
6. Update both README files when public behavior changes.
7. Run `swift test` before submitting.

## Project principles

- Real telemetry only. Never present simulated growth as live usage.
- Local-first processing and read-only access to source logs.
- Unknown models remain unpriced instead of receiving a guessed fallback.
- Derived data belongs in the local database, not in source logs.
- Destructive or external write operations require explicit user confirmation.
