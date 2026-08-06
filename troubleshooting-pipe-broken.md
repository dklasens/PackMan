# Investigation: "Pipe is broken" on elevated (Chocolatey) updates — v1.4

Status as of 2026-08-06. Root causes identified and fixed for v1.5; the patched helper has passed
real-UAC validation and a real six-item Chocolatey update batch completed without pipe errors. All
Chocolatey updates in the installed v1.4 build failed with
`Update failed — Pipe is broken.` Non-elevated sources (npm, pip) worked. The user reported 3 UAC
prompts for 4 choco packages.

## Root causes and v1.5 fixes

1. Windows Application events show that all four elevated helpers crashed in
   `NamedPipeClientStream.ValidateRemotePipeUser()` with `UnauthorizedAccessException: Could not
   connect to the pipe because it was not owned by the current user.` On Windows, client-side
   `PipeOptions.CurrentUserOnly` verifies both account and elevation level. PackMan intentionally
   connects an elevated client to a non-elevated server, so that validation always rejects the
   connection. Removed `CurrentUserOnly` from the helper client only; the server retains its
   same-user access restriction and the protocol retains its random pipe name and token.
2. `StreamWriter.AutoFlush = true` blocks immediately on this machine because it performs a
   synchronous pipe flush. Replaced `StreamWriter` messages with newline-delimited UTF-8 bytes sent
   directly with `PipeStream.WriteAsync`; focused probes confirmed raw async reads and writes finish.
3. Reworked the helper to keep exactly one `ReadLineAsync` pending throughout the session. This
   removes the overlapping-read crash after the first completed command.
4. Added a regression test that executes two commands through one helper connection. The focused
   test passes, as do all Windows tests (36 unit/integration tests and 5 UI tests). A separate probe launched the
   patched, published `PackMan.exe` through real UAC, executed two safe commands through one helper
   process, and received both results before the helper exited cleanly with code 0.

## Problems being addressed

1. **All Chocolatey (elevated) updates fail with "Pipe is broken"** — the elevated helper's pipe
   connection drops mid-run, so every choco package errors out a few seconds in.
2. **One UAC prompt per package, not per batch** — because each helper session dies, the broker
   starts a fresh elevated helper (new UAC prompt) for the next package. Item 1 from the v1.4 plan
   ("one UAC prompt per source") is therefore not yet delivered in practice.
3. **pip dependency conflicts (fixed locally):** the follow-up run showed pip returning success
   after installing `pyarrow 25.0.0`, `starlette 1.4.1`, and `websockets 17.0.1`, even though all
   three violate installed Streamlit 1.61.1 constraints. PackMan's target-version verification then
   marked them updated. Before each pip update, PackMan now discovers installed packages that depend
   on the target and pins their current versions in the same pip transaction. Pip can therefore
   reject incompatible targets during resolution, before changing packages.
4. **Secondary broker bug (fixed locally):** the helper's active-phase loop breaks
   out with a `ReadLineAsync` still pending, then the idle phase issues another read on the same
   `StreamReader` → `InvalidOperationException` ("stream is currently in use") → helper dies after
   the first successful run. Must be restructured to a single read loop regardless.
5. **Environmental anomaly narrowed and avoided locally:** `StreamWriter.AutoFlush = true` blocks
   while direct `PipeStream.WriteAsync` calls complete. The broker no longer constructs pipe
   `StreamWriter` instances or calls pipe flush methods.
6. **Diagnostics gap:** a crashing elevated helper previously left no trace. Added (unreleased):
   helper try/catch → `%TEMP%\PackMan\helper-error.log`, plus an `UnhandledException` hook on the
   helper path.
7. **Second-machine source detection and update UX (fixed locally):**
   - npm's Windows `ENOENT` for an absent, empty global prefix is now verified with `npm prefix -g`
     and reported as zero updates instead of a failed scan.
   - .NET Tools now probes `dotnet --list-sdks`; a runtime-only install gets a concise "SDK required"
     source issue instead of the verbose `dotnet --version` failure.
   - WinGet's `0x8A15010C` installer-cancelled result is now a per-package Cancelled state. The batch
     continues with remaining packages and the run is summarized as a warning.
   - Administrator-required failures expose the existing elevated retry and now add an explicit
     "Retry as administrator" log hint.

## Symptoms (user test, 09:54–09:55)

- Scan works across all 7 sources (incl. new .NET Tools source).
- Ignore feature works (2 winget updates hidden).
- Update run: npm `@openai/codex` OK; pip `streamlit` OK; `starlette` failed (problem 3).
- All 4 Chocolatey packages failed `Pipe is broken` ~2–5 s each, with a UAC prompt per package
  (problems 1–2).

## Facts established locally

1. **The real elevated helpers did crash.** Windows Application events at 09:55:14, :17, :20, and
   :22 record the same unhandled client ownership/elevation validation exception—one for each of the
   four Chocolatey attempts. The earlier direct launch did not reproduce this because it launched
   the helper non-elevated.
2. The ownership-validation crash explains both user-visible symptoms: the server observes a
   connection before the client rejects and closes it, so the controller's first write reports
   `Pipe is broken`; each later package then launches another helper and triggers another UAC prompt.
3. **The apparent write anomaly was `AutoFlush`, not raw async I/O.** Focused probes confirmed raw
   async writes complete in duplex-default, explicitly buffered duplex, and one-way pipe setups.
   The broker-specific probe stopped exactly when enabling `StreamWriter.AutoFlush`.
4. **JSON round-trip of the broker DTO is fine** (including `TimeSpan` timeout) — ruled out.
5. **WPF startup ruled out:** `App.xaml` has no `StartupUri`, `ShutdownMode="OnMainWindowClose"`,
   and the helper path skips host/window creation.
6. The v1.3 one-shot broker used the same incompatible client option, so the first-run fault predates
   v1.4. The overlapping-read/session-reuse fault was introduced by v1.4.

## Ruled out

- TimeSpan/JSON serialization of `ProcessInvocation` (round-trip verified OK).
- WPF host/window startup and single-file extraction.
- UAC decline handling, pipe name validation, token mismatch.
- Runtime regression (same behavior on .NET 8 and .NET 10).
- Third-party AV/EDR interference (only Windows Defender present).

## Open questions

1. Confirm that the successful real Chocolatey batch used one UAC approval for the whole source
   session; the transport and command path both completed without pipe errors.
2. The current Python environment must be restored to Streamlit-compatible versions before testing
   the new guard: `pyarrow<25,>=7.0`, `starlette<1.4.0,>=0.46.0`, and
   `websockets<17,>=12.0.0`. This is separate from the broker failure.

## Diagnostics included in v1.5

- `ElevationBroker.RunHelperAsync` wrapped in try/catch → logs exception to
  `%TEMP%\PackMan\helper-error.log`.
- `AppDomain.CurrentDomain.UnhandledException` hook on the helper path → same log file.

## Next steps

1. Confirm a single UAC approval served the successful multi-package Chocolatey batch.
2. Restore the Python environment, then confirm the patched app blocks those same three proposed
   upgrades with `ResolutionImpossible` and leaves the compatible versions installed.
3. Keep the helper error log through the next release validation; remove or rotate it later if the
   broker is stable.
4. Validate the second-machine fixes: npm should report zero updates, .NET Tools should explain that
   no SDK is installed, a cancelled WinGet installer should not stop later packages, and Claude can
   be retried with the administrator action. Bitwarden's `0x8A150006` remains a package/installer
   failure rather than an app transport failure.

## Key files

- `windows/src/PackMan/Services/ElevationBroker.cs` — broker + helper (diagnostics added)
- `windows/src/PackMan/Services/ProcessRunner.cs` — elevated routing, already-elevated bypass
- `windows/src/PackMan/App.xaml.cs` — helper entry point + crash hook
- Candidate build: `windows/dist/windows-next/PackMan.exe`
