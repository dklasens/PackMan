# PackMan

A desktop app that scans for outdated software across multiple package managers and updates them from one place.

PackMan has two native streams sharing one repo:

- **`windows/`** — PackMan for Windows, built with WPF on .NET 8
- **`macos/`** — SwiftUI (native macOS app)

## What it does

Pick which sources to include, hit **Scan**, select the packages you want, and click **Update Selected**. Progress and command output are shown in a built-in log.

### macOS sources

- **Homebrew** (formulae)
- **Homebrew Casks** (GUI apps)
- **Mac App Store** (via [mas](https://github.com/mas-cli/mas))
- **npm** (global packages)
- **pip** (Python packages)
- **pipx** (Python CLI tools, checked against PyPI)

### Windows sources

- **winget** (Windows Package Manager)
- **Chocolatey**
- **Scoop**
- **npm** (global packages)
- **pip** (Python packages)
- **pipx** (isolated Python CLI tools)
- **.NET Tools** (dotnet global tools, checked against nuget.org)

## Download

### macOS

Grab `PackMan-macOS.zip` from the [Releases](https://github.com/dklasens/PackMan/releases) page and unzip it. Requires macOS 14+ and supports Apple Silicon and Intel Macs.

The app is ad-hoc signed and cannot be notarized because this project does not use a paid Apple Developer account. macOS will therefore warn that Apple cannot check it for malicious software. After attempting to open it, go to **System Settings → Privacy & Security**, scroll to Security, choose **Open Anyway**, and confirm. Apple documents this override in [Safely open apps on your Mac](https://support.apple.com/102445). Only override Gatekeeper when you trust the downloaded release; the accompanying `.sha256` file can be checked with `shasum -a 256 -c PackMan-macOS.zip.sha256`.

> Homebrew is the only required dependency. For the full experience: `brew install mas pipx`.

### Windows

Grab the latest `PackMan-Windows-x64.zip` from the [Releases](https://github.com/dklasens/PackMan/releases) page. Extract it, then run `PackMan.exe`. The app is self-contained, so no installer or .NET runtime is required.

> Requires Windows 10/11 (x64). PackMan starts normally and requests administrator approval when an update needs it: Chocolatey upgrades always run elevated, and other sources can be retried with elevation from the context menu. Updates you hide with **Ignore** can be managed in the Sources window. Optional sources can be installed separately: [Chocolatey](https://chocolatey.org/install), [Scoop](https://scoop.sh/), Node.js/npm, Python/pip, pipx, and the [.NET SDK](https://dotnet.microsoft.com/download).

## Building from source

### macOS

Requirements: macOS 14+ and full Xcode 16.4 or newer. Command Line Tools alone cannot create the complete app bundle.

```
cd macos/PackMan
swift test                 # unit and integration tests
xcodebuild test -project PackMan.xcodeproj -scheme PackMan -destination 'platform=macOS'
./make-app.sh              # creates the app, release zip, and SHA-256 checksum
```

`make-app.sh` builds a universal Release app, applies an ad-hoc signature, verifies the bundle, and writes `dist/PackMan.app`, `dist/PackMan-macOS.zip`, and `dist/PackMan-macOS.zip.sha256`. Override release metadata with `PACKMAN_VERSION=1.2.3` and `PACKMAN_BUILD_NUMBER=123`.

Pushing a tag such as `v1.2.3` runs the macOS test suite and publishes those packaged files to a GitHub Release. The workflow needs only the repository-provided `GITHUB_TOKEN`; it does not require signing certificates, Apple credentials, or repository secrets.

### Windows

Requirements: .NET 8 SDK (Windows).

```
cd windows
dotnet restore PackMan.sln
dotnet build PackMan.sln
dotnet test PackMan.sln
dotnet publish src/PackMan/PackMan.csproj /p:PublishProfile=FolderProfile
```

The published single-file exe lands in `windows/src/PackMan/bin/Publish/`. Existing source selections are migrated once from `%APPDATA%\UpdateManager` to `%APPDATA%\PackMan`.

## Tech

- **macOS**: SwiftUI, Swift concurrency, SwiftPM. Scans run concurrently; `brew outdated --json=v2` and PyPI's JSON API keep parsing robust.
- **Windows**: WPF on .NET 8, [WPF UI](https://wpfui.lepo.co/) (Fluent/Mica design), CommunityToolkit.Mvvm. Scans run concurrently with per-source health, cancellation, partial-result handling, and post-update verification.
