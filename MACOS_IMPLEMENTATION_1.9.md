**Mac 1.9 feature implementation — shipping version 1.9.1, build 3**

Stages A–D from [the accepted review](MACOS_REVIEW_1.9.md) are implemented. The version is 1.9.1 because the existing release already included a Mac app labelled 1.9; both that rebuild and 1.8.2 must see this as a newer update. `macos/PackMan/project.yml` supplies release metadata to Xcode and `make-app.sh`; UI and diagnostics read the built bundle. An unbundled development executable identifies itself as Development.

- [x] A: strict parsing, installed verification, warning/count separation, cancellation/Quit and recoverable self-update.
- [x] B: package details, separate recovery actions, manual App Store workflow, persistent history and diagnostic preview/export.
- [x] C: configured cache previews/selection, shared Homebrew inventory and fresh tool capabilities.
- [x] D: source discovery/setup, environment descriptions, source/status filters, visible/total selection counts, window/table preferences, optional cask policy and accessibility.
- [x] Local validation: SwiftPM and native Xcode tests, UI checks, disposable self-update helper tests, universal packaging, signature/checksum checks and GUI-launch source discovery.

**What changed**

Verification reads installed inventory independently of outdated/catalog results. Missing packages, ambiguous identities, unrecognised output and incomparable versions remain explicit uncertainties. Confirmed versions come from inventory, including a newer installed version when comparable. Python names are normalised; pipx environment identity and Homebrew tap/type identity survive scan, update, verification and history. Pins/skips are respected and counted. Legacy pipx reports its limited public-PyPI coverage. Scan warnings do not masquerade as failed install attempts; search and ignores cannot turn hidden updates into an all-clear.

Details show identity, manager/runtime paths, observed/requested versions, warnings, evidence, package links and bounded attempt output. Update/retry runs the manager; Verify again only checks installed state. App Store rows are manual and excluded from automatic selection, with App Store/Terminal handoff and subsequent verification. Source/status/search filters affect visibility; automatic update actions operate on checked visible rows. Counts distinguish visible selections, total selections, automatic/manual work, ignores and manager skips.

History saves the queue before commands begin, then records each attempt with its run/attempt identity, actual observed version, outcome and evidence. It retains 500 attempts and 64 KiB of recent output per attempt in `~/Library/Application Support/PackMan/update-history.json`. Interrupted/running and queued work recover as interrupted/not started. Save failures prevent unrecorded execution; unreadable history is preserved before replacement. Files use private permissions. Export redacts every string field plus the live log and shows a reviewable JSON preview before saving; this does not promise complete anonymisation of arbitrary output.

Cache cleanup discovers manager-configured paths and refreshes previews before confirmation. Measurements avoid overlapping-path double counts, skip nested symlinks, remain cancellable and identify inaccessible paths as partial. Homebrew shares preview/cleanup between formulae and casks and explains dry-run removals separately from its cache footprint. App Store cleanup is unavailable. pipx cleanup is capability-gated without retrying a different destructive command on generic failure. NuGet HTTP/temp/plugin caches are separate from explicit global-package removal. Results retain failures across shared sources.

Homebrew formula/cask scans share one outdated snapshot per installation and scan. Refresh/capability state is keyed by tool context; persisted contexts expire and fingerprint the executable/runtime. Operation boundaries reprobe tools and mutations invalidate contexts. pipx help probes are reused until identity/version changes or their five-minute freshness limit expires. Verification batches local inventory per source, removing repeat registry requests. No scan speed-up percentage is claimed.

First-run source setup can discover managers and explicitly apply the detected choices. Existing choices migrate intact; rechecking alone does not change them. Sources describe the selected environment and support optional self-updating casks. Window geometry and table column preferences persist.

Subprocesses start in their own process group. Cancellation/timeout terminates the group, escalates to SIGKILL, and bounds completion even when inherited pipes remain open. Raw output is capped at 16 MiB; live output has a bounded queue and reports omissions. Quit offers Keep Working or Cancel and Quit, waiting for operation cleanup before exit.

Self-update checks the offered version, bundle identifier, executable, host architecture, checksum and code signature before launching a helper. The helper stages beside the target, requires parent exit, keeps a backup during replacement and restores it on swap failure. A durable result log is stored in `~/Library/Application Support/PackMan/self-update.log`; failed relaunch leaves manual restart instructions.

**Validation evidence — 5 September 2026**

Host: Apple Silicon, macOS 26.6.2 (25G83), Xcode 26.6. Deployment target remains macOS 14.0.

| Check | Result / evidence |
| --- | --- |
| SwiftPM suite | 136 tests: 135 passed, one optional live mas test skipped. `/tmp/packman19-final-swiftpm.log` |
| Native Xcode app tests | 136 tests: 135 passed, one skipped. `/tmp/PackMan19ReleaseChecks.xcresult` |
| Native UI suite | 11 passed, including partial results, selection, details/verification/history, diagnostics, cache presentation, keyboard shortcuts, and both Quit choices. Final appearance rerun: `/tmp/PackMan19AppearanceChecks.xcresult`. |
| Actual production helper | Disposable signed bundles upgraded from both 1.8.2 and 1.9.0, including renamed paths/spaces. Parent timeout, invalid signature, injected swap failure/rollback, invalid identity and failed relaunch covered. No installed app was replaced. |
| Process lifecycle | Prelaunch cancellation, parent/child cancellation, inherited pipes after parent exit, TERM-ignoring child and output-limit termination covered. |
| Cache/history/capability regressions | Configured/shared/inaccessible paths; NuGet opt-in; confirmation rejection; shared cleanup failure; corrupt history; private permissions; queue-save rejection; bounded storage; redaction; executable changes; shared subprocess counts; pipx capability reuse covered. |
| Universal package | `make-app.sh` produced app, ZIP, DMG and SHA-256 files. Both arm64/x86_64 verified, version 1.9.1/build 3, bundle ID `com.packman.PackMan`, minimum macOS 14.0. Ad-hoc signature passed strict/deep verification. Archive checksums and `hdiutil verify` passed. `/tmp/packman19-package.log` |
| GUI launch | Packaged app launched through Launch Services, showed v1.9.1 and rechecked sources. Found Homebrew 6.0.21, mas 7.0.0, npm 12.0.2, pip 26.0.1 and pipx 1.17.2; .NET remained disabled/unavailable. Existing source choices were retained. |
| Source hygiene | `git diff --check` and shell syntax check passed. Production universal build has no Swift compiler warnings; Xcode reports only its standard unused AppIntents metadata notice. |

Tests use synthetic managers and disposable bundles. No real packages were installed/removed, no real caches were purged, and nothing has been published or tagged. Local artifacts are under `macos/PackMan/dist/`. README and `.github/release-notes/v1.9.1.md` describe the new Mac workflows.

**Remaining checks before public distribution**

The local evidence does not establish runtime compatibility on macOS 14/15 or physical Intel hardware; the deployment target and universal architectures were verified here. Run those environment checks before publication. Live Apple Account/App Store handoff and verification, real manager upgrades, and end-to-end release-download/self-replacement also need release-environment smoke tests. The actual helper transaction is covered locally with disposable apps, including both prior versions, but the installed user app was deliberately not replaced. The app remains ad-hoc signed, as before; no notarisation is claimed.

uv, scheduling/notifications, Brewfile export, manager installation, broad install/uninstall browsing and automatic package rollback remain outside this accepted core release, as specified in the review.

**UI polish follow-up**

Aligned table cells and details fields, replaced disabled-looking status buttons with readable badges, simplified Sources into full-width rows, standardised dialog sizes/insets, clarified primary actions and cache icons, and aligned cache sizes with source names. NuGet options appear only when .NET is selected. The existing 11 UI tests passed; light/dark screenshots were inspected in `/tmp/PackMan19PolishUI.xcresult`. Universal app/ZIP/DMG rebuilt with these changes (`/tmp/packman19-polish-package-final.log`).
