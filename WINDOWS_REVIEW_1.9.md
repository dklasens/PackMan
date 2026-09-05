**PackMan for Windows: review and proposed 1.9 scope**

Reviewed 5 September 2026 against local commit `bba1b5e`. The requested baseline is 1.8.3; this checkout's Windows project declares 1.8.2 and its local tags end at v1.8.2. Findings describe this checkout, not an independently inspected 1.8.3 release binary.

**Recommendation: focus 1.9 on trustworthy results, clear recovery, and easier selection.** The WPF app already has concurrent scans, partial results, source health, executable overrides, selective elevation, ignore rules, source installation, cache cleanup, and self-update. Search, package details, and persistent history would substantially improve everyday use without requiring more package managers.

**Evidence and limits**

All 125 existing Windows unit/integration tests passed on Windows 11 with .NET SDK 10.0.400. Generated-file access errors prevented building directly in the checkout; a temporary copy of the tracked Windows files built and tested successfully.

Seven additional regression checks ran only in that temporary copy. All seven failed their desired-behavior assertions, demonstrating gaps below. A separate publish experiment reproduced incorrect version metadata. No real package installations, UAC flows, released-binary self-updates, or interactive visual/accessibility tests were performed. Application code was not changed.

**Fix before shipping 1.9**

1. **High: release version is supplied after compilation.** The workflow builds without the tag version, then publishes with `--no-build /p:Version=$version`. Reproducing that pattern with `Version=1.9.0` produced an EXE reporting file version `1.8.2.0` and product version `1.8.2`. The updater compares the assembly version, so a mismatched release can keep offering itself. Supply the version at compilation and assert that the packaged EXE and running app match the release tag. See `.github/workflows/release.yml:73`, `:79`, and `windows/src/PackMan/PackMan.csproj:12`. This follows the documented behavior of [`dotnet publish --no-build`](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-publish).

2. **High: standalone EXE filename breaks self-update.** The release provides `PackMan-Windows-x64.exe`, but the update ZIP contains `PackMan.exe`. `Services/AppUpdateService.cs:98` searches the archive using the running executable's filename. The advertised standalone download therefore hits the missing-file check unless renamed. This is established by code inspection. Resolve the canonical archive entry independently of the destination name, preserving the target-path restriction. Test ZIP, standalone, and user-renamed executables.

3. **High: unrecognized scan output can mean clean scan and successful verification.** `Services/WingetSource.cs:83` returns zero rows and zero rejected rows when no table separator is recognized. `Services/DotnetSource.cs:145` also silently returns an empty result when its English header is not recognized. `Services/PackageSourceBase.cs:60` treats absence from the outdated list as successful verification and reports the requested version as installed. Three regression checks reproduced these behaviors. Distinguish recognized empty results from unrecognized/incomplete results. Retain unverified packages; verify installed identity/version when supported, and disclose weaker evidence otherwise. Add localized, truncated, malformed, and genuinely empty fixtures.

4. **High: Chocolatey success outcomes are reported as failures.** Scan and upgrade use `ExitCode == 0` as their success rule. With enhanced exit codes enabled, outdated packages produce code 2; upgrade code 3010 means success requiring reboot. Both reproduced as exceptions. Interpret outcomes per command/source and preserve reboot status separately from failure and verification. Cover 2, 3010, 1641, and genuine errors. See `Services/ChocoSource.cs:28` and `:159`, plus Chocolatey's [outdated](https://docs.chocolatey.org/en-us/choco/commands/outdated/) and [upgrade](https://docs.chocolatey.org/en-us/choco/commands/upgrade/) documentation.

5. **Medium: scan warnings bypass the first installation attempt.** `MainViewModel.ReplacePackages` maps every package status message to `Failed/Verification`; WinGet uses such a message for truncated rows. `RunUpdatesAsync` then verifies without installing. A warning-bearing fixture reproduced zero install calls. Separate scan warnings from prior update failures. Resolve truncated identifiers before enabling an update; a truncated display name alone should not bypass installation. Test first installation and verification-only retry separately.

6. **Medium: ignored updates can produce “System is up to date.”** `DeriveScanSummary` counts only visible updates. Hiding the sole outdated package and scanning reproduced `UpToDate`. Retain detected, ignored, and actionable counts. Say “No actionable updates; 1 ignored” or “Selected sources are up to date.” The latter also accurately describes the app's coverage.

7. **Medium: WinGet discovery and execution policies differ.** Scans always include unknown installed versions; update commands omit `--include-unknown`. The parsed repository name is discarded and updates omit `--source`. These are code-inspection findings; actual installers were not exercised. Make unknown-version handling an explicit user choice carried into execution and verification. Preserve repository identity to disambiguate updates. Microsoft documents both options in [WinGet upgrade](https://learn.microsoft.com/en-us/windows/package-manager/winget/upgrade).

Service paths above are relative to `windows/src/PackMan`; view-model methods are in `windows/src/PackMan/ViewModels/MainViewModel.cs`.

**The most useful visible improvements**

Effort indicates relative implementation size including verification, not a delivery estimate.

| Rank | Improvement | Concrete 1.9 behavior | Effort |
| --- | --- | --- | --- |
| 1 | **Search and filters** | Search name and ID; filter by source, selection, and failure/cancellation. Add Ctrl+F and F5. Show visible and total selections, with an explicit “Select visible” action. Windows currently has sorting but no search; macOS already has search. | Small–medium |
| 2 | **Package details and recovery** | A details pane exposes full ID, repository, installed/target versions, tool path, warnings, failure reason, and the relevant log. Distinguish “Retry update” from “Verify again”; offer interactive installation where supported. Add publisher/release links when available. Current failure detail is primarily a tooltip and shared log. | Medium |
| 3 | **Persistent history and run summary** | Retain package, before/after version, time, outcome, reboot state, and diagnostics. Show “8 updated, 1 failed, 2 not started” for mixed runs. Export redacted diagnostics. Today successful rows disappear and only the latest 1,000 log entries remain in memory. | Medium |
| 4 | **Source onboarding** | Detect installed managers and let users enable that set. Distinguish an optional missing manager from a broken installation. Preserve existing choices and explain which Python/npm environment is managed. All sources currently default to enabled, making ordinary missing developer tools appear as source issues. | Small–medium |
| 5 | **Precise cache cleanup** | Select sources individually, preview scope and reclaimable space where measurable, and report per-source results. Make NuGet global-package cleanup explicit because it affects later restores. | Medium |
| 6 | **Optional background scans** | Scan on launch, optional tray mode, scheduled checks, and notifications that open the results. Make startup/tray behavior configurable and prevent overlapping operations. This depends on sound history and lifecycle handling. | Medium–large |

For a focused 1.9, commit to correctness fixes and ranks 1–3. Add onboarding if capacity allows. Treat cache metrics and background scanning as stretch scope; background scanning is the best follow-up candidate if it threatens the core work.

**Engineering work supporting the release**

The main view model owns scanning, source installation, cache cleanup, self-update, package updates, verification, logging, and selection. Extract an update coordinator and history store as the features need them. Model package identity, scan warning, install outcome, verification evidence, and reboot requirement separately.

Review lifecycle behavior before adding a tray or scheduler. `ProcessRunner.cs:94–95` cancels the process-exit wait, but its subsequent stdout/stderr completion wait has no cancellation or timeout. A descendant holding an inherited pipe handle could prevent completion. `MainWindow.xaml.cs` requests cancellation on close without awaiting the operation. These are code-inspection risks requiring bounded process/close tests, rather than reproduced user failures.

Also address the elevated self-update relaunch fallback: `AppUpdateService.cs:348` directly starts PackMan when Explorer relaunch fails, potentially retaining the helper's elevated token. If normal-user relaunch cannot be established, provide a manual restart path and a durable update result. Test the fallback and validate actual token behavior in a Windows integration environment.

Further coverage should address version semantics and package ownership. Legacy pipx compares PyPI versions for inequality, while .NET tools use a limited `System.Version` comparison: test prereleases, locally newer versions, and configured/private feeds. Multiple managers may describe the same installed application. Surface possible ownership conflicts and revalidate a queued update after another manager changes the app; do not merge records solely by display name.

Keep Windows polish bounded: remember window size and column widths, add accessible names to package checkboxes, inspect keyboard/context-menu behavior, and verify 125–200% scaling and high contrast. These need a real UI pass; this review inspected XAML and existing automation tests only.

**Release acceptance criteria**

| Area | Evidence required |
| --- | --- |
| Detection | Empty results differ from missing tools, ignored updates, and failures. Malformed/localized output cannot silently verify updates. |
| Updating | Mixed success, failure, cancellation, and reboot runs have accurate totals and recovery actions. Scan warnings never impersonate completed installs. |
| Self-update | Tag, EXE metadata, and displayed version agree. ZIP, standalone, renamed, writable-folder, and protected-folder flows work, including declined UAC and swap failure. Relaunch uses normal user privileges. |
| Selection | Filtering and selection counts are clear; keyboard use and scaled layouts pass manual verification. |
| Diagnostics | History survives restart, records actual verification evidence, and exports redact sensitive output. |

Keep broad install/uninstall browsing, automatic rollback promises, additional package backends, and Windows OS/driver updating outside the proposed 1.9 scope. ARM64 and a self-contained distribution are separate packaging decisions: the current artifact targets x64 and requires the .NET Desktop Runtime. Either change needs release-asset selection and self-update coverage.

**Reproduction record**

The seven temporary checks asserted: unknown WinGet output raises an issue; unknown WinGet output cannot verify an update; Chocolatey code 2 retains outdated results; Chocolatey 3010 is not an install failure; an all-ignored scan does not report `UpToDate`; an unrecognized .NET table raises an issue; and a warning-bearing row does not bypass first installation. All seven exposed the behaviors above. They were not added to the production suite.

The version experiment built the unmodified Windows project in Debug, then ran `dotnet publish --configuration Debug --no-build --no-restore /p:Version=1.9.0` into a temporary directory and inspected EXE metadata. This isolates the same build/publish mismatch as the Release workflow; it does not inspect a downloaded release artifact.
