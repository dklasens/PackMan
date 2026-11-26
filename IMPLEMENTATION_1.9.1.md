# PackMan Windows 1.9.1 implementation

**Windows point release candidate — 26 November 2026.** Based on Windows 1.9.0 at `8439703`; the macOS stream and WSL2 work are unchanged.

Release version clarification: the original candidate was developed as 1.9.1. GitHub already had a published 1.9.1 release and a Mac-only 1.10 release, so the final Windows update uses 1.9.2. The repository was fast-forwarded to retain the Mac release history; a regression test also covers Windows update discovery when the repository's latest release is Mac-only.

## Implemented

All correctness findings and the runtime optimisation opportunities in [WINDOWS_REVIEW_1.9.1.md](WINDOWS_REVIEW_1.9.1.md) were addressed:

- Current-row and current-context checks for installation and verification; invalidated details and a single reusable Activity window.
- Recognised empty/partial/error scan contracts and stricter package records; source freshness, retry and elapsed-time fixes.
- Versioned repository-aware ignore rules with legacy matching retained; readable rule labels, and explicit missing-prerequisite versus configuration-error install handling.
- Batched history persistence, awaited recovery checkpoints, incremental history UI updates, bounded diagnostic-only process capture, buffered output delivery and coalesced visible log scrolling. Long diagnostic lines are redacted with the linear-time regex engine.
- Tool cache timestamp, file metadata and PATH fingerprint invalidation; pipx capability cache keyed to executable, version and prefix; no duplicate full scan for an ordinary cached-context network failure.
- Search, visible/total counts, bulk selection notifications, and separate visible/all selection commands.
- Source-specific version comparison, environment-aware legacy pipx checks, and conservative public NuGet feed checks. Successful update checks clear stale banners.

## Performance evidence

A local synthetic disk-write benchmark simulated 100 successful attempts with 4 KiB command logs and prepopulated history. Both paths used the same atomic history store and redaction implementation after the redaction optimisation. The serial path reproduced the old four writes per package; the batched path retained the two per-package recovery checkpoints and combined the queued and final records into two batch writes.

| Existing history records | Serial saves | Batched saves | Serial elapsed | Batched elapsed |
| --- | ---: | ---: | ---: | ---: |
| 100 | 400 | 202 | 1,927 ms | 865 ms |
| 500 | 400 | 202 | 4,508 ms | 2,084 ms |

Both benchmarks verified equivalent final history-record identities/order. These are illustrative local measurements, not a live package download or a UI latency benchmark. Permanent tests assert the reduction in saves, preservation of interrupted records and the absence of full history-collection resets without imposing flaky timing thresholds.

## Validation

The implementation adds regression coverage for the seven original failures, plus search, stale executable overrides, cache invalidation, version ordering, feed handling, bounded capture, history persistence and long diagnostic lines.

- .NET SDK 10.0.404: Release solution build succeeded; the application and UI test projects compile without warnings.
- Windows unit/integration tests: **204 passed, 0 failed, 0 skipped** (Release).
- Published-executable WPF UI tests: **8 passed, 0 failed, 0 skipped**, including search filtering without altering checked updates and opening package details in the reusable Activity window.
- Published executable file version: **1.9.1.0**. Local candidate ZIP contains both `PackMan.exe` and the backwards-compatible standalone filename; both entries match the published executable's SHA-256. Standalone and ZIP checksum files were generated.
- Local candidate artifacts: `windows/dist/1.9.1/PackMan-Windows-x64.exe` and `windows/dist/1.9.1/PackMan-Windows-x64.zip`. They are build outputs, not committed or published release assets.
- Final Windows 1.9.2 build after synchronising main: **205 unit/integration tests passed**, zero build warnings/errors, and the published executable reports file version **1.9.2.0**. GitHub Actions is responsible for the final release packages and hosted UI tests.

The test project still uses the cached Microsoft.NET.Test.Sdk 17.12.0. A newer SDK was evaluated, but the environment could not connect to NuGet to restore and test it; the tested dependency is intentionally retained for this candidate rather than introducing an unverified restore dependency.

Before tagging/publishing, perform normal manual smoke tests with real third-party package managers, actual UAC approval/decline and the packaged self-update in both user-writable and protected install locations. Automated tests use synthetic package managers and do not install apps on the development workstation.
