# PackMan macOS Review

Reviewed: 2026-08-02

Scope: the native SwiftUI app under `macos/PackMan`, including the supplied launch and scanning screenshots.

## Summary

The app has a clear core workflow and a suitably compact native structure, but several state-model issues can give users inaccurate results. The most important fixes are:

1. Do not report "System is Up to Date" when any enabled source failed or was unavailable.
2. Make the npm version shown in the table match the version that will actually be installed.
3. Surface pipx lookup failures instead of treating them as "no update."
4. Stream per-source scan progress and support cancellation.
5. Replace the two independent selection systems with one consistent model.

The screenshots also confirm a visible toolbar layout jump when scanning begins, an overly sparse launch state, and too much space dedicated to an empty log.

## Functional Issues

### P1: Failed scans can be reported as up to date

**Evidence**

- `AppViewModel.scan()` records unavailable and failed sources only in the log.
- It then sets `hasScanned = true` and chooses the final status solely from `packages.isEmpty`.
- `ContentView` interprets an empty package list after any scan as "System is Up to Date."

Relevant code:

- `macos/PackMan/Sources/PackMan/ViewModels/AppViewModel.swift:99`
- `macos/PackMan/Sources/PackMan/Views/ContentView.swift:58`

**Impact**

A missing tool, command failure, parsing error, or network problem can produce a false all-clear. A partial scan can also omit failures from the primary status while still showing updates found by other sources.

**Recommended change**

- Keep a result for every enabled source: scanning, succeeded, unavailable, failed, and cancelled.
- Only show "System is Up to Date" when every enabled and available source completed successfully and returned no updates.
- Show "Scan Completed with Issues" when results are partial.
- Put failed source names and concise recovery actions in the main UI, not only in the log.

**Acceptance criteria**

- All successful and empty sources: show up to date.
- Any source failure plus no updates: show a warning state, not up to date.
- Any source failure plus some updates: show the updates and a persistent partial-results warning.
- All sources unavailable: explain that no sources could be scanned.

### P1: npm displays a different target from the version it installs

**Evidence**

- The scan maps `availableVersion` from `wanted` before `latest`.
- The update command always installs `packageID@latest`.
- After success, the view model sets `currentVersion` to the displayed `availableVersion`, not the version confirmed by npm.

Relevant code:

- `macos/PackMan/Sources/PackMan/PackageSources/NpmSource.swift:32`
- `macos/PackMan/Sources/PackMan/PackageSources/NpmSource.swift:49`
- `macos/PackMan/Sources/PackMan/ViewModels/AppViewModel.swift:177`

For global packages, npm documents that `wanted` is normally the currently installed version. See [npm outdated](https://docs.npmjs.com/cli-commands/npm-outdated/).

**Impact**

The table can show identical Current and Available values while the update installs a newer release. Afterward, the row can continue displaying an incorrect current version.

**Recommended change**

- Use `latest` as the available version when the action is `npm install -g package@latest`.
- Alternatively, install the exact version displayed in `availableVersion`.
- After an update, rescan npm or query the installed version instead of assuming success means the target was installed.

### P1: pipx lookup failures are treated as no update

**Evidence**

`latestPyPIVersion` returns `nil` for URL construction errors, request failures, non-200 responses, timeouts, and decoding failures. `checkForUpdate` treats every `nil` as an up-to-date package.

Relevant code:

- `macos/PackMan/Sources/PackMan/PackageSources/PipxSource.swift:74`

Current pipx releases provide outdated and JSON-oriented list functionality. See [pipx manage installed apps](https://pipx.pypa.io/latest/how-to/manage-installed-apps.html).

**Impact**

An offline Mac or a PyPI outage can produce a successful zero-update result and contribute to the false up-to-date state.

**Recommended change**

- Prefer structured pipx outdated output when supported.
- Retain a compatibility fallback for older pipx versions if needed.
- Return a typed success, no-update, or failure result for each lookup.
- If some package lookups fail, report the source as partial rather than successful.

### P1: Long operations have weak progress and no cancellation

**Evidence**

- Scan outcomes are collected for the entire task group before any per-source result is logged.
- Homebrew can spend up to 300 seconds refreshing before a scan that can take another 300 seconds.
- Updates can run for 600 to 900 seconds per package and are processed sequentially.
- Button actions create untracked tasks.
- `ProcessRunner` has timeout handling but no task-cancellation handler.
- Only stdout is streamed; many command-line tools write progress to stderr.

Relevant code:

- `macos/PackMan/Sources/PackMan/ViewModels/AppViewModel.swift:77`
- `macos/PackMan/Sources/PackMan/PackageSources/BrewSource.swift:29`
- `macos/PackMan/Sources/PackMan/Services/ProcessRunner.swift:27`
- `macos/PackMan/Sources/PackMan/Services/ProcessRunner.swift:149`

**Impact**

The app can appear frozen for several minutes. Users cannot stop a slow scan, a prompt that cannot be answered from the GUI, or an update they started accidentally.

**Recommended change**

- Publish each source result as soon as it completes.
- Track the active task in the view model.
- Change Scan to Cancel while work is active, without inserting or removing toolbar items.
- Propagate cancellation to `ProcessRunner` and terminate the child process tree.
- Stream both stdout and stderr with source and stream context.
- Show the active source or package and completed/total progress.

### P2: Table selection and update selection are unrelated

**Evidence**

- `Table` writes native row selection into `selection`.
- Checkboxes write `PackageUpdate.isSelected`.
- `updateSelected()` reads only `isSelected`.
- The native `selection` set is otherwise unused.

Relevant code:

- `macos/PackMan/Sources/PackMan/Views/ContentView.swift:5`
- `macos/PackMan/Sources/PackMan/ViewModels/AppViewModel.swift:123`

**Impact**

Clicking rows, shift-selecting, or using native selection conventions does not select those packages for updating. The visual highlight and actual action target can disagree.

**Recommended change**

Choose one model:

- Prefer checkbox selection for this workflow and remove native table selection, or
- Use native multi-row selection as the action selection and remove per-row checkboxes.

If checkboxes remain, add a labelled select-all checkbox in the column header and show the selected count in the primary action.

### P2: Successful updates remain actionable and counted as available

**Evidence**

After success, the package remains in `packages`, stays selected, and is still included in the footer count. Update Selected remains enabled whenever the app is not busy.

Relevant code:

- `macos/PackMan/Sources/PackMan/ViewModels/AppViewModel.swift:166`
- `macos/PackMan/Sources/PackMan/Views/ContentView.swift:84`
- `macos/PackMan/Sources/PackMan/Views/ContentView.swift:106`

**Impact**

Users can immediately run the same update again, and the footer continues claiming that completed packages are updates.

**Recommended change**

- Disable the action when no pending or failed package is selected.
- Remove successful rows after a short confirmation, or move them into a completed section.
- Rescan the affected source after updates to confirm installed state.
- Support retrying failed packages without rerunning successful ones.

### P2: Package-manager discovery misses common macOS installations

**Evidence**

- The fixed search path covers Homebrew and system directories.
- A GUI-launched app normally receives a minimal inherited `PATH`.
- Common nvm, asdf, mise, pyenv, and `~/.local/bin` locations are not covered.
- pip availability checks for `python3`, not whether that interpreter has the pip module.

Relevant code:

- `macos/PackMan/Sources/PackMan/Services/ProcessRunner.swift:25`
- `macos/PackMan/Sources/PackMan/PackageSources/PipSource.swift:12`

**Impact**

Installed tools can appear unavailable, while the pip source can appear available and then fail during scanning. With multiple Python installations, the app may also update a different interpreter than the user expects.

**Recommended change**

- Probe the actual command needed by each source, such as `python -m pip --version`.
- Support common user-level tool locations or explicit executable paths in settings.
- Show the resolved executable or interpreter in the Sources UI.
- Use the existing `sourceDetail` concept to preserve environment/path context.

### P2: Multiple windows can run conflicting operations

**Evidence**

The app uses `WindowGroup`, and every `ContentView` creates its own `AppViewModel` and `isBusy` state.

Relevant code:

- `macos/PackMan/Sources/PackMan/PackManApp.swift:6`
- `macos/PackMan/Sources/PackMan/Views/ContentView.swift:5`

**Impact**

Multiple windows can start concurrent scans or updates. Source settings can also become visually inconsistent between windows because each window owns separate option objects.

**Recommended change**

- Use a single `Window` scene for this utility, or
- Share one application-level operation coordinator and settings model across windows.

### P3: Source settings can change during an active scan

The Selection menu is disabled while busy, but the Sources menu is not. A toggle changed during scanning only affects a future scan because the current scan uses a snapshot.

Relevant code:

- `macos/PackMan/Sources/PackMan/Views/ContentView.swift:125`

Disable source changes while busy or explicitly indicate that they apply to the next scan.

### P3: Sort order becomes stale when row values change

Sorting is reapplied only when the sort descriptors change. Status and current version mutate during updates, but the table is not resorted afterward. Version columns also use lexical string ordering, which is not semantic version ordering.

Relevant code:

- `macos/PackMan/Sources/PackMan/Views/ContentView.swift:55`
- `macos/PackMan/Sources/PackMan/ViewModels/AppViewModel.swift:162`

Reapply sorting after mutations that affect the active sort key, and consider a natural/version-aware comparator for version columns.

### P3: Command log ordering and deduplication can be inaccurate

Output callbacks enqueue separate main-actor tasks. The command can finish and log `[OK]` before queued output lines are displayed. `lastOutputLine` is also global, so identical consecutive lines from different packages can be suppressed.

Relevant code:

- `macos/PackMan/Sources/PackMan/ViewModels/AppViewModel.swift:166`
- `macos/PackMan/Sources/PackMan/ViewModels/AppViewModel.swift:197`

Use an ordered async stream or actor-backed logger, and scope duplicate suppression by command/package.

### P3: Swift 6 emits a capture warning

The output callback's nested `[weak self]` differs from the outer closure's implicit strong capture. This is currently a warning in Swift 5 language mode but should be cleaned up before adopting Swift 6 mode.

Relevant code:

- `macos/PackMan/Sources/PackMan/ViewModels/AppViewModel.swift:172`

Make the outer closure's capture intent explicit and keep main-actor delivery ordered.

## UI and UX Polish

### Stabilize the toolbar during scans

The supplied scanning screenshot shows the title and neighboring controls shifting when the progress indicator appears. This is caused by conditionally adding a toolbar item.

Relevant code:

- `macos/PackMan/Sources/PackMan/Views/ContentView.swift:118`

Recommended design:

- Keep the toolbar structure and control dimensions constant in every state.
- Replace the Scan icon in place with a progress indicator, or reserve a fixed progress slot.
- Turn Scan into Cancel while active.
- Avoid a separate spinner capsule between the primary controls and title.

### Make the primary action unambiguous

In the launch screenshot, Update Selected is rendered as an icon-only blue circular control. It reads more like Download than a package upgrade command.

Recommended design:

- Display `Update Selected` or `Update 4` with title and icon.
- Consider `arrow.up.circle` for upgrade rather than a downward download arrow.
- Disable it before a scan, when there are no updates, and when nothing actionable is selected.
- Keep `Command-U` and expose the same command in the application menu.

### Replace the empty striped table with a real empty state

The launch screenshot shows an empty table's alternating row backgrounds behind `ContentUnavailableView`. The unused rows dominate the interface and reduce the clarity of the empty-state message.

Recommended design:

- Before the first scan, show a clean unframed empty state instead of constructing the table.
- Include one primary Scan action.
- After a confirmed successful empty scan, show the up-to-date state with last scan time.
- For a failed or partial scan, show a warning state with Retry and source details.

### Improve scan progress

Recommended design:

- Show a compact list of enabled sources with waiting, scanning, complete, unavailable, and failed states.
- Update each source as soon as it completes.
- Display elapsed time for slow sources and the current Homebrew refresh phase.
- Keep already discovered updates visible while slower sources continue.

### Make the log secondary and controllable

The fixed-height empty log consumes a large portion of the launch window.

Recommended design:

- Collapse the log before activity.
- Auto-open it for updates, failures, or when the user requests details.
- Make it resizable with a split view or disclosure section.
- Add familiar Copy and Clear icon buttons with tooltips.
- Preserve text selection and automatic scrolling, but stop auto-scroll when the user scrolls upward.

### Improve the Sources control

The current menu shows enabled toggles but no health or environment context.

Recommended design:

- Show enabled state, availability, resolved executable, last result, and concise errors.
- Distinguish "disabled" from "not installed" and "failed."
- Provide appropriate recovery actions, such as opening installation instructions.
- Use the product's conventional capitalization, including `npm` rather than `NPM`.

### Refine the table workflow

Recommended design:

- Use one selection model.
- Add a labelled select-all checkbox to the first column header if checkbox selection remains.
- Keep checkbox and status columns at stable widths.
- Give long versions and package names truncation tooltips.
- Provide Retry Update and Copy Package ID context actions where applicable.
- Show failure detail without requiring users to discover a hover-only tooltip.
- Do not allow already successful rows to remain selected for another update.

### Improve the footer/status strip

The current status duplicates the empty-state instruction and uses mechanical text such as `0 update(s)`.

Recommended design:

- Use correct singular/plural localization.
- Show `4 selected of 12`, last scan time, and a partial-scan warning when relevant.
- Keep transient operation status separate from the durable result summary.
- Make error indicators actionable so they open source details or the log.

### Accessibility and keyboard behavior

Relevant code:

- `macos/PackMan/Sources/PackMan/Views/ContentView.swift:13`

Recommended changes:

- Give every checkbox an accessibility label such as `Select ripgrep for update`.
- Give status icons useful accessibility values rather than relying on color.
- Verify full keyboard traversal, table navigation, context menus, Scan, Cancel, and Update Selected.
- Ensure Command-A affects the actual update selection or is deliberately removed from the table.
- Test increased contrast, reduced motion, light mode, dark mode, and larger accessibility text sizes.

### Window behavior

Recommended design:

- Prefer a single window for this utility.
- Verify the minimum width with the longest source, version, status, and toolbar labels.
- Preserve sensible column widths when resizing.
- Avoid dynamically inserting controls that alter title or toolbar geometry.

## Release and Distribution

### Ad-hoc signing creates a poor first-run experience

The release script applies an ad-hoc hardened-runtime signature, and the README instructs users to right-click and choose Open.

Relevant code:

- `macos/PackMan/make-app.sh:18`
- `README.md:32`

For public distribution:

- Sign with a Developer ID Application certificate.
- Notarize and staple the application or distribution image.
- Consider a DMG with a standard Applications shortcut.
- Add a repeatable release/CI workflow and verify bundle metadata before publishing.

### Build prerequisites need clarification

On the review machine, a full-source direct typecheck succeeded, but `swift build` failed with the standalone Swift 6.4/macOS 27 Command Line Tools because the installed toolchain did not include/load `SwiftUIMacros`. Full Xcode was not installed.

Relevant documentation:

- `README.md:44`

Recommended change:

- State that full Xcode is the supported build prerequisite unless standalone Command Line Tools are verified in CI.
- Add a preflight check to `make-app.sh` with a clear error when the active developer directory is unsuitable.
- Build the release on a pinned, documented Xcode version.

## Test Coverage Gaps

`Package.swift` defines no test target. Add focused coverage before restructuring the UI:

- Fixture tests for Homebrew, mas, npm, pip, and pipx output parsing.
- npm tests where `current`, `wanted`, and `latest` differ.
- pipx tests for HTTP failure, timeout, malformed JSON, partial success, and current versions.
- View-model tests for full success, partial failure, all unavailable, cancellation, retry, and update completion.
- ProcessRunner tests for stdout, stderr, timeout, cancellation, partial final lines, and exit codes.
- Tool-resolution tests using controlled environment variables and executable fixtures.
- Settings load/save and corrupt-file behavior.
- UI tests for toolbar stability, empty states, selection semantics, disabled actions, and accessibility labels.

## Suggested Implementation Order

1. Introduce explicit per-source scan state and eliminate false up-to-date results.
2. Correct npm target handling and pipx failure propagation.
3. Add task ownership, cancellation, ordered output streaming, and progressive source results.
4. Unify selection and correct successful-update lifecycle behavior.
5. Rework the toolbar, empty state, source status, log disclosure, and footer.
6. Improve tool discovery and expose resolved environment details.
7. Add parser, view-model, process, and UI tests.
8. Pin the Xcode release toolchain, sign, and notarize the distributed app.

## Xcode Verification Checklist

- [ ] `swift build` completes with the selected supported Xcode toolchain.
- [ ] `./make-app.sh` creates `dist/PackMan.app`.
- [ ] The app passes `codesign --verify --deep --strict`.
- [ ] Launch and scan are checked in light and dark mode.
- [ ] Toolbar controls do not move when scanning starts or ends.
- [ ] A successful empty scan shows up to date.
- [ ] A failed or partial scan never shows up to date.
- [ ] Each package source is tested with updates and with its tool missing.
- [ ] npm displays and installs the same target version.
- [ ] pipx reports offline and partial-failure states.
- [ ] Cancel stops scans and child processes promptly.
- [ ] Successful packages cannot be updated again without a new scan.
- [ ] VoiceOver identifies checkboxes, statuses, menus, and primary actions.
- [ ] The app is tested at minimum/default window sizes and on a smaller display.
- [ ] A signed/notarized release is tested on a clean Mac user account.
