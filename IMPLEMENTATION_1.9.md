PackMan Windows 1.9 implementation scope

User clarified improvement numbering against WINDOWS_REVIEW_1.9.md: 2 package details/recovery, 3 persistent history/run summaries/diagnostic export, 5 per-source cache cleanup and space previews. Fix 8 covers the lifecycle and elevated-relaunch risks described after the seven numbered fixes. Background scans, search, and onboarding are outside this implementation.

- [x] Fix 1: compile/tag/version consistency and packaged-version check. Windows version is 1.9.0; the release workflow supplies the tag at compilation and checks the published EXE.
- [x] Fix 2: canonical archive entry independent of installed EXE filename. ZIP, standalone, and renamed executable staging have regression coverage.
- [x] Fix 3: fail visibly on unrecognized scan output; truthful installed-version verification. Each Windows source reads installed inventory. An observed older version remains actionable; inconclusive verification never invents the target version.
- [x] Fix 4: source-specific success/reboot outcomes. Chocolatey codes 2, 3010, and 1641 have explicit handling; reboot state survives verification and appears in history and summaries.
- [x] Fix 5: scan warnings separate from previous verification failures. WinGet IDs resolve from structured inventory only on a unique match; unresolved IDs cannot execute. Display-name warnings do not skip installation.
- [x] Fix 6: ignored/detected/actionable counts and accurate coverage wording, including immediately after ignoring the last visible update.
- [x] Fix 7: explicit, persisted unknown-version policy and retained WinGet repository identity through discovery, execution, and verification.
- [x] Fix 8: cancellation includes pipe completion; closing waits for operation cleanup; an elevated updater never falls back to a direct elevated launch. Failed normal-user relaunch leaves a manual restart notice and log.
- [x] Improvement 2: details, per-package output, safe package/publisher/release links, explicit update/verification/interactive recovery. Native metadata links are available for WinGet and npm where supplied by those sources.
- [x] Improvement 3: atomic persistent history (latest 500 entries), actual versions and verification evidence, mixed-run counts, retries, and redacted export. Queued attempts are saved before starting; interrupted commands are identified on reload. Verification-only success is recorded as Verified, not Updated.
- [x] Improvement 5: per-source selection, scope/location/size preview, and per-source cleanup results. Cleanup refreshes estimates before confirmation; shared or inaccessible caches are explained, and NuGet global-package removal is explicit.

Validation performed on Windows, 5 September 2026:

- Release solution build and publish succeeded. Published EXE FileVersion is 1.9.0.0 and ProductVersion is 1.9.0.
- All 168 unit/integration tests passed (125 original baseline tests plus expanded regression coverage).
- All 7 UI automation tests passed against the published executable, including package details, verification-only recovery, history selection, and cache-size preview. WPF content renders were inspected for layout; they use a solid background because desktop Mica capture is unavailable in this environment.
- README documents the new controls, history location, unknown-version policy, and cache scope.
- Git whitespace validation passed.

Validation limits: native manager behavior is exercised with command-output fixtures; this run did not install or remove real packages, invoke real UAC approval, or replace a released application. Actual protected-folder self-update and token behavior still warrant release smoke testing on a Windows test machine. NuGet vulnerability lookup was unavailable due to network access, producing NU1900 warnings; compilation itself had no errors.

Build note: original checkout generated files had access errors during review. Implementation validation used a temporary copy of all current Windows worktree files, including new and modified files, excluding bin/obj. The test executable is at `%TEMP%\PackMan-implementation-19\published\PackMan.exe`.
