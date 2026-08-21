# Changelog

## [Unreleased]

### Changed

- Removed redundant internal account IDs from named relay account rows while retaining a fallback identifier for unnamed accounts.

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
