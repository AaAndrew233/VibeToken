# Changelog

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
