# Changelog

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
