# Changelog

## 1.9.2 — 2026-11-26

### Windows

- Reject stale package actions and invalidate scan results when source configuration changes.
- Distinguish unsuccessful and malformed scans from recognised clean results; scope new ignores to repository identity.
- Separate missing package managers from tools with configuration problems.
- Add search, visible/total selection counts, and visible-only selection commands.
- Batch atomic history writes, preserve recovery checkpoints, and reduce log and selection overhead.
- Expire cached tools and refresh capabilities following executable/version changes; improve package version comparison and configured-feed checks.
- Discover Windows-compatible GitHub releases independently of the Mac release stream.

macOS remains at v1.10. WSL2 is not included in this release.

[Release notes and downloads](https://github.com/dklasens/PackMan/releases/tag/v1.9.2)

## 1.10 — 2026-10-28

### macOS

- Keep history installs and verification bound to their recorded manager executable and runtime search paths. Preserve compatibility with older history entries that recorded only the executable path.
- Enforce installation eligibility centrally, including ambiguous-identity protection for History retries.
- Recheck manager capabilities before every package and before verification, including npm upgrades from 11 to 12 within one batch.
- Explain ignored, manual, skipped, and ambiguous-only scan results without claiming that all packages are current.
- Consolidate cache cleanup in `CacheInspector`; test the production cleanup path, NuGet global-package opt-in, output, and failure handling.
- Add Xcode 26.6 alongside 16.4 in macOS CI and treat Swift warnings as errors. Remove the obsolete test with an unsafe concurrent capture.
- Publish only platforms whose declared versions match the release tag. This is a Mac-only release; Windows remains at 1.9.1.

[Release notes and downloads](https://github.com/dklasens/PackMan/releases/tag/v1.10)

## 1.9.1 — 2026-09-05

### macOS

- Add package details, explicit install/retry and verification actions, manual App Store handoff, and on-demand package links.
- Persist 500 update attempts with actual observed versions, interruption recovery, bounded output and previewable redacted diagnostics.
- Preview configured caches and refresh before cleanup confirmation; share Homebrew cleanup and require opt-in for NuGet global packages.
- Add source discovery/setup and environment descriptions, source/status filtering, visible/total selection counts, window/table preferences and optional self-updating cask checks.
- Read installed inventory for verification; report missing, ambiguous and incomparable versions, malformed output and partial coverage accurately.
- Preserve pipx environment/Homebrew tap identity, pins and skipped counts. Separate scan warnings, ignored updates and search visibility from install outcomes.
- Share Homebrew scan inventory, refresh tool capabilities, and bound process output. Cancel process groups and wait for cleanup when quitting.
- Validate and stage recoverable self-updates, retain a backup during replacement, and record durable recovery/relaunch results.
- Polish text alignment, Sources rows, status badges, dialog sizing, cache icons and primary actions.

### Windows

- Include the latest Windows 1.9 implementation, rebuilt as 1.9.1 for consistent release/updater version metadata. No functional changes.

[Release notes and downloads](https://github.com/dklasens/PackMan/releases/tag/v1.9.1)

## 1.9 — 2026-09-05

- Windows: add package details/recovery, persistent update history, diagnostic export and selective cache previews.
- Windows: improve verification, Chocolatey reboot handling, WinGet identity/unknown-version handling, ignored counts, cancellation and standalone self-update reliability.
- macOS: rebuild the existing app as universal version 1.9 without the new Windows features.

[Full release notes](.github/release-notes/v1.9.md)
