Plan
Phase 1 — App Store source reliability (P0)
1. Switch update command to mas update --force <id> (deterministic; no silent no-ops).
2. Probe: parse mas version; < 5.0.0 → unavailable with "run brew upgrade mas" recovery.
3. Pre-flight before privileged execution: mas executable must be owned by root or the current user and not group/world-writable; refuse otherwise.
4. Scan: parse both tabular and JSON-lines mas outdated output; surface mas stderr warnings (Spotlight indexing notices) as source issues; raise timeout 120→180s.
5. Map known mas failures (not signed in, different Apple Account/ABM app) to actionable messages.
6. Verification: brief post-update delay before re-scan; treat residual "still outdated" as verification-issue with retry guidance (Spotlight lag) rather than hard failure.
7. Tests: JSON-lines + column-aligned tabular parsing, version gate, --force args, ownership check, stderr surfacing.
Phase 2 — Security hardening (P1)
1. Write/repair settings.json at 0600.
2. Clean stale PackMan-AppStore-* session dirs at launch.
3. Document the privileged-execution model and settings-file threat model in README.
Phase 3 — Optimisations (P1)
1. Batch npm verification into one npm list -g --json call.
2. Raise pipx/dotnet registry lookup concurrency to 8.
Phase 4 — UI/UX polish (P2)
1. Footer shows durable summary (counts + last scan time) instead of duplicating the banner.
2. Sources sheet: per-source requirement hints (Apple Account, mas 5+), last-scan times, too-old-mas state.
3. ⌘, opens Sources; clarify the all-ignored empty state.
Phase 5 — Production prep (P2)
1. README: mas 7 requirement, App Store limitations (Spotlight, Apple Account, ABM unsupported), Sonoma jq note.
2. Version bump for release; verify make-app.sh + codesign + packaged-app launch.