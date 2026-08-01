# PackMan

A desktop app that scans for outdated software across multiple package managers and updates them from one place.

PackMan has two native streams sharing one repo:

- **`windows/`** — WPF on .NET 8 (the original Windows app)
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
- **npm** (global packages)
- **pip** (Python packages)

## Download

### macOS

Grab `PackMan-macOS.zip` from the [Releases](../../releases) page and unzip it. Requires macOS 14+ (Apple Silicon). The app is ad-hoc signed — on first launch, right-click → Open to bypass Gatekeeper.

> Homebrew is the only required dependency. For the full experience: `brew install mas pipx`.

### Windows

Grab the latest `UpdateManager.exe` from the [Releases](../../releases) page. It's a single self-contained file — no installer or .NET runtime required. Just download and run.

> Requires Windows 10/11 (x64). Updating system-level packages may prompt for administrator approval.

## Building from source

### macOS

Requirements: Xcode / Swift toolchain (macOS 14+).

```
cd macos/PackMan
swift build                # debug build
./make-app.sh              # release build, creates dist/PackMan.app
```

### Windows

Requirements: .NET 8 SDK (Windows).

```
cd windows
dotnet build PackageManager.sln
dotnet publish src/UpdateManager/UpdateManager.csproj /p:PublishProfile=FolderProfile
```

The published single-file exe lands in `windows/src/UpdateManager/bin/Publish/`.

## Tech

- **macOS**: SwiftUI, Swift concurrency, SwiftPM. Scans run concurrently; `brew outdated --json=v2` and PyPI's JSON API keep parsing robust.
- **Windows**: WPF on .NET 8, [WPF UI](https://wpfui.lepo.co/) (Fluent/Mica design), CommunityToolkit.Mvvm.
