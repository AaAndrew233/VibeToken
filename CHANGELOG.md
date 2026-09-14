# Changelog

## [0.1.8] - 2026-09-14

### Fixed

- Added a confirmed manual refresh path that updates Sub2API OAuth credentials and current plan expiration dates before running the existing verified quota refresh.
- Kept startup, wake, polling, and scheduled quota refreshes read-only; partial credential refreshes now report the verified success count instead of publishing a false success.

## [0.1.7] - 2026-09-11

### Fixed

- Kept the Settings window above the menu bar popover and persisted Dock visibility and launch-at-login preferences across app restarts.

## [0.1.6] - 2026-09-05

### Changed

- Added official GPT-6 Astra and current GPT-5.6 pricing, including distinct cache-write rates, short/long context pricing at the 272K input-token boundary, and Standard, Flex, Batch, Fast, and Priority tiers.

## [0.1.5] - 2026-09-04

### Changed

- Reduced background filesystem work in live refresh mode by using file events for immediate updates, extending the fallback scan to 60 seconds, coalescing burst writes, and caching source discovery and watch targets.
- Account quota rows now show the 5-hour and 7-day reset times below their remaining balances regardless of balance or whether a reset timestamp has passed.

## [0.1.4] - 2026-08-24

### Changed

- Removed redundant internal account IDs from named relay account rows while retaining a fallback identifier for unnamed accounts.
- Aligned the relay availability count and plan summary with schedulable accounts, excluding runtime-unavailable accounts without changing quota-capacity weighting.

## [0.1.3] - 2026-08-21

### Changed

- Removed the duplicate Dock and startup controls from the menu bar popover; these options now live only in the dedicated Settings window.
- Kept the menu bar popover visible when opening or using the Settings window.
- Updated English and Simplified Chinese documentation and visual QA records.

## [0.1.2] - 2026-08-20

### Added

- Added a dedicated Settings window for Dock icon visibility and launch at login.
- Added available and unavailable account tabs with counts in the Sub2API capacity view.
- Added plan expiration display, account-specific recovery times, and explicit rate-limited or unavailable labels.

### Changed

- Restored language, time range, refresh mode, and relay capacity controls to their existing menu and relay locations.
- Updated English and Simplified Chinese documentation and visual QA records.

## [0.1.1] - 2026-08-20

### Added

- Account quota lists now prioritize valid Pro accounts, then earlier recovery times within each plan, followed by valid Plus accounts.
- Invalid, stale, unobserved, and unavailable accounts are placed at the bottom of the quota list.
- Account quota rows keep the 5-hour and 7-day values together and show account-specific recovery times only for rate-limited accounts.

### Changed

- The same stable sorting rule is used by the live Sub2API account list and the visual test fixture.
- English and Simplified Chinese documentation now describe quota ordering and recovery-time display behavior.

## [0.1.0] - 2026-08-19

- Initial public preview release.
