# PackMan macOS v1.10

Scope: four reliability fixes and two maintenance changes. Windows source and version metadata are unchanged.

## Recovery and environment identity

New history entries retain the complete `ToolContext` as an optional Codable field. Existing entries still decode and use their recorded `toolPath`. Diagnostic exports redact the new executable and search-path fields as well as the existing history fields.

Before an install or verification, PackMan probes the current manager and compares its standardized executable path and ordered runtime search paths against the requested environment. Versions and discovery origins may change. Symlinks are deliberately not collapsed: different Python virtual environments can point at the same interpreter binary. Legacy history without search paths can match by executable path alone.

A matching package in the current table cannot replace a historical attempt from a different environment. A mismatch stops the action and asks the user to select the original executable in Sources and scan again. This protects explicit executable/runtime selection; it does not snapshot package-manager configuration files or the contents of an environment at a path.

## Eligibility and fresh capabilities

The shared operation entry point rejects ambiguous identities, and installations additionally require an actionable automatic package. Manual App Store updates retain their external handoff and verification-only action.

Every package operation obtains a fresh manager context. Verification rechecks that context before reading inventory. Updating npm itself therefore changes the capabilities used for the next package without silently switching to another installation. Existing cancellation and durable-attempt recording remain in the operation path.

## Scan presentation

`noAutomaticUpdates` distinguishes nonautomatic results from a clean empty scan. The summary explains ignored updates, manual updates, source-policy exclusions, and ambiguous identities. Automatic counts remain independent of search visibility. Source issues take precedence over the nonautomatic summary, and successful updates do not erase skipped-source coverage.

## Cache maintenance

`CacheInspector` is the sole cleanup executor. The per-source `clearCache` protocol requirement, implementations, fallback cleanup, and synchronous size helpers were removed. Replacement tests exercise the actual preview/clear path, streaming output, the previewed executable, unsupported sources, failure handling, shared Homebrew cleanup, and the NuGet global-package opt-in. Removing the old App Store cleanup test also removes its unsafely captured array.

## CI and release

- macOS CI runs on macOS 15 / Xcode 16.4 and macOS 26 / Xcode 26.6. Swift compiler warnings fail both SwiftPM and Xcode tests.
- The output-limit regression uses larger lines to test the 16 MB byte limit without imposing a millions-of-lines throughput requirement on shared runners. The original tiny-line fixture also timed out on the pre-v1.10 main branch in hosted CI.
- Release packaging retains the Xcode 16.4 baseline and universal arm64/x86_64 output.
- Release platform selection compares the normalized tag version with `project.yml` and the Windows project version. A `v1.10` tag selects macOS only. Explicit workflow dispatch rejects mismatched platform versions.
- The release workflow produces the ZIP, DMG, and SHA-256 checksums through `make-app.sh`, which verifies bundle metadata, architectures, and ad-hoc signatures.

## Validation

Regression coverage includes ambiguous history retries, recovery across different Python executables and runtime paths, legacy history compatibility, diagnostic redaction, npm capability changes in one batch, ignored/manual/skipped summaries, source-error precedence, and production cache cleanup. UI coverage includes the ignored-only and skipped-only empty states.

Local validation on Xcode 27.0:

- SwiftPM: 145 passed, one optional live App Store integration test skipped, zero compiler warnings with `-warnings-as-errors`.
- Xcode: all 145 non-live unit tests passed; all 13 UI tests passed after making diagnostic screenshot attachments opt-in with `PACKMAN_UI_SCREENSHOTS=1`. The initial UI run had five screenshot-only teardown failures; behavioral assertions passed.
- `make-app.sh`: universal Release app, ZIP, and DMG built successfully; bundle version/build, both architectures, and ad-hoc signature checks passed.
- Workflow YAML parsed successfully. Release selection was exercised for `v1.10`, normalized `v1.10.0`, and rejected mismatched Windows/both/nonexistent versions.

The tagged GitHub Actions run is the authoritative record of hosted CI, packaged checksums, and publication.
