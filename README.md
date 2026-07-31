# PackMan

A Windows desktop app that scans for outdated software across multiple package managers and updates them from one place.

## What it does

PackMan checks for available updates across these sources:

- **winget** (Windows Package Manager)
- **Chocolatey**
- **npm** (global packages)
- **pip** (Python packages)

Pick which sources to include, hit **Scan**, select the packages you want, and click **Update Selected**. Progress and command output are shown in a built-in log.

## Download

Grab the latest `UpdateManager.exe` from the [Releases](../../releases) page. It's a single self-contained file — no installer or .NET runtime required. Just download and run.

> Requires Windows 10/11 (x64). Updating system-level packages may prompt for administrator approval.

## Building from source

Requirements: .NET 8 SDK (Windows).

```
dotnet build PackageManager.sln
dotnet publish src/UpdateManager/UpdateManager.csproj /p:PublishProfile=FolderProfile
```

The published single-file exe lands in `src/UpdateManager/bin/Publish/`.

## Tech

WPF on .NET 8, [WPF UI](https://wpfui.lepo.co/) (Fluent/Mica design), CommunityToolkit.Mvvm.
