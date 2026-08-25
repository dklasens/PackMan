using System.ComponentModel;
using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PackMan.Services;

public sealed record AppUpdateInfo(string Version, string DownloadUrl, string ChecksumUrl, string ReleaseUrl);

public interface IAppUpdateService
{
    Task<AppUpdateInfo?> CheckAsync(bool force = false, CancellationToken cancellationToken = default);
    Task ApplyAsync(AppUpdateInfo update, IProgress<string>? progress, CancellationToken cancellationToken);
}

public sealed class AppUpdateService(HttpClient httpClient, ISettingsService settings) : IAppUpdateService
{
    internal static readonly Uri LatestReleaseUri = new("https://api.github.com/repos/dklasens/PackMan/releases/latest");
    internal const string ZipAssetName = "PackMan-Windows-x64.zip";
    internal const string ChecksumAssetName = ZipAssetName + ".sha256";
    private static readonly TimeSpan CheckThrottle = TimeSpan.FromHours(24);
    private static readonly TimeSpan DownloadTimeout = TimeSpan.FromMinutes(10);

    internal static Version CurrentVersion { get; } =
        typeof(AppUpdateService).Assembly.GetName().Version ?? new Version(0, 0);

    public async Task<AppUpdateInfo?> CheckAsync(bool force = false, CancellationToken cancellationToken = default)
    {
        if (!force && settings.GetLastAppUpdateCheck() is { } lastCheck
            && DateTimeOffset.UtcNow - lastCheck < CheckThrottle)
            return Validate(settings.GetAvailableAppUpdate(), settings.GetSkippedAppUpdateVersion(), force);

        var release = await FetchLatestReleaseAsync(cancellationToken);
        settings.SetLastAppUpdateCheck(DateTimeOffset.UtcNow);
        var newer = IsNewer(release) ? release : null;
        settings.SetAvailableAppUpdate(newer);
        return Validate(newer, settings.GetSkippedAppUpdateVersion(), force);
    }

    private static bool IsNewer(AppUpdateInfo? candidate) =>
        candidate is not null
        && Version.TryParse(candidate.Version, out var version)
        && version > CurrentVersion;

    private static AppUpdateInfo? Validate(AppUpdateInfo? candidate, string? skippedVersion, bool force)
    {
        if (!IsNewer(candidate)) return null;
        if (!force && string.Equals(skippedVersion, candidate!.Version, StringComparison.OrdinalIgnoreCase)) return null;
        return candidate;
    }

    private async Task<AppUpdateInfo?> FetchLatestReleaseAsync(CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, LatestReleaseUri);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        request.Headers.TryAddWithoutValidation("User-Agent", "PackMan");
        using var response = await httpClient.SendAsync(request, cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound) return null;
        if (response.StatusCode != HttpStatusCode.OK)
            throw new HttpRequestException($"GitHub returned HTTP {(int)response.StatusCode} while checking for updates.");
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        var release = await JsonSerializer.DeserializeAsync<GitHubRelease>(stream, cancellationToken: cancellationToken);
        if (release is null || release.Draft || release.Prerelease) return null;
        var tag = release.TagName?.Trim().TrimStart('v', 'V');
        if (string.IsNullOrWhiteSpace(tag) || !Version.TryParse(tag, out var version)) return null;
        var assets = release.Assets ?? [];
        var download = assets.FirstOrDefault(a => string.Equals(a.Name, ZipAssetName, StringComparison.OrdinalIgnoreCase))?.BrowserDownloadUrl;
        var checksum = assets.FirstOrDefault(a => string.Equals(a.Name, ChecksumAssetName, StringComparison.OrdinalIgnoreCase))?.BrowserDownloadUrl;
        if (string.IsNullOrWhiteSpace(download) || string.IsNullOrWhiteSpace(checksum)
            || string.IsNullOrWhiteSpace(release.HtmlUrl)) return null;
        return new AppUpdateInfo(version.ToString(), download!, checksum!, release.HtmlUrl!);
    }

    public async Task ApplyAsync(AppUpdateInfo update, IProgress<string>? progress, CancellationToken cancellationToken)
    {
        var executable = Environment.ProcessPath
            ?? throw new InvalidOperationException("The PackMan executable path is unavailable.");
        var targetDirectory = Path.GetDirectoryName(Path.GetFullPath(executable))!;
        var stagingRoot = Path.Combine(Path.GetTempPath(), "PackMan", "update");
        try { if (Directory.Exists(stagingRoot)) Directory.Delete(stagingRoot, recursive: true); }
        catch (Exception ex) { throw new InvalidOperationException($"Could not prepare the update folder: {ex.Message}"); }
        Directory.CreateDirectory(stagingRoot);

        var zipPath = Path.Combine(stagingRoot, ZipAssetName);
        progress?.Report($"Downloading PackMan {update.Version}…");
        await DownloadFileAsync(update.DownloadUrl, zipPath, cancellationToken);

        progress?.Report("Verifying the download against the release checksum…");
        await VerifyChecksumAsync(update.ChecksumUrl, zipPath, cancellationToken);

        progress?.Report("Extracting the update…");
        var stagedDirectory = Path.Combine(stagingRoot, "staged");
        ZipFile.ExtractToDirectory(zipPath, stagedDirectory, true);
        var stagedExecutable = Path.Combine(stagedDirectory, Path.GetFileName(executable));
        if (!File.Exists(stagedExecutable))
            throw new InvalidOperationException($"The release archive does not contain {Path.GetFileName(executable)}.");

        var requiresElevation = !CanWriteToDirectory(targetDirectory);
        progress?.Report(requiresElevation
            ? "Windows will ask for administrator approval to finish the update."
            : "Closing PackMan to finish the update…");
        if (!LaunchApplyHelper(Environment.ProcessId, stagedExecutable, executable, stagingRoot, requiresElevation))
            throw new ElevationDeclinedException();
    }

    private async Task DownloadFileAsync(string url, string destination, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(DownloadTimeout);
        try
        {
            using var response = await httpClient.SendAsync(
                new HttpRequestMessage(HttpMethod.Get, url), HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            response.EnsureSuccessStatusCode();
            await using var content = await response.Content.ReadAsStreamAsync(timeout.Token);
            await using var file = File.Create(destination);
            await content.CopyToAsync(file, timeout.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException("The update download timed out.");
        }
    }

    private async Task VerifyChecksumAsync(string checksumUrl, string filePath, CancellationToken cancellationToken)
    {
        var text = await httpClient.GetStringAsync(checksumUrl, cancellationToken);
        var expected = text.Split([' ', '\t', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        if (expected is null || expected.Length != 64 || !expected.All(Uri.IsHexDigit))
            throw new InvalidOperationException("The release checksum file is malformed.");
        await using var stream = File.OpenRead(filePath);
        var actual = Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, cancellationToken));
        if (!string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The downloaded file does not match the release checksum; the update was aborted.");
    }

    private static bool CanWriteToDirectory(string directory)
    {
        var probe = Path.Combine(directory, $".packman-write-{Guid.NewGuid():N}");
        try
        {
            File.WriteAllText(probe, string.Empty);
            File.Delete(probe);
            return true;
        }
        catch { return false; }
    }

    internal Func<int, string, string, string, bool, bool> LaunchApplyHelper { get; set; } = DefaultLaunchApplyHelper;

    private static bool DefaultLaunchApplyHelper(int parentId, string stagedExecutable, string targetExecutable,
        string stagingRoot, bool elevated)
    {
        var executable = Environment.ProcessPath
            ?? throw new InvalidOperationException("The PackMan executable path is unavailable.");
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        if (elevated) start.Verb = "runas";
        start.ArgumentList.Add(UpdateApplier.ApplyArgument);
        start.ArgumentList.Add(parentId.ToString());
        start.ArgumentList.Add(stagedExecutable);
        start.ArgumentList.Add(targetExecutable);
        start.ArgumentList.Add(stagingRoot);
        try
        {
            using var helper = Process.Start(start)
                ?? throw new InvalidOperationException("Could not start the update helper.");
            return true;
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode is SourceSupport.ErrorCancelled)
        {
            return false;
        }
    }

    private sealed class GitHubRelease
    {
        [JsonPropertyName("tag_name")] public string? TagName { get; set; }
        [JsonPropertyName("html_url")] public string? HtmlUrl { get; set; }
        [JsonPropertyName("draft")] public bool Draft { get; set; }
        [JsonPropertyName("prerelease")] public bool Prerelease { get; set; }
        [JsonPropertyName("assets")] public List<GitHubAsset>? Assets { get; set; }
    }

    private sealed class GitHubAsset
    {
        [JsonPropertyName("name")] public string? Name { get; set; }
        [JsonPropertyName("browser_download_url")] public string? BrowserDownloadUrl { get; set; }
    }
}

public static class UpdateApplier
{
    internal const string ApplyArgument = "--apply-update";
    internal const string BackupSuffix = ".old";
    private static readonly TimeSpan ExitWait = TimeSpan.FromSeconds(120);
    private static readonly TimeSpan RelaunchWait = TimeSpan.FromSeconds(10);

    /// <summary>How long a swap step keeps retrying while the file is still held.</summary>
    internal static TimeSpan RetryWindow { get; set; } = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Removes the previous build left beside the executable by <see cref="ReplaceExecutableAsync"/>.
    /// Best effort: in a protected folder this only succeeds for the next elevated update helper,
    /// which clears it before swapping again.
    /// </summary>
    public static void CleanUpBackup()
    {
        if (Environment.ProcessPath is { } executable) TryDelete(executable + BackupSuffix);
    }

    internal static Action<string>? RelaunchOverride { get; set; }

    public static bool IsApplyMode(IReadOnlyList<string> args) =>
        args.Count == 5
        && args[0] == ApplyArgument
        && int.TryParse(args[1], out _)
        && !string.IsNullOrWhiteSpace(args[2])
        && !string.IsNullOrWhiteSpace(args[3])
        && !string.IsNullOrWhiteSpace(args[4]);

    public static async Task<int> RunAsync(IReadOnlyList<string> args)
    {
        if (!IsApplyMode(args)) return 2;
        try
        {
            return await RunCoreAsync(int.Parse(args[1]), args[2], args[3], args[4]) ? 0 : 1;
        }
        catch (Exception ex)
        {
            LogFailure(ex);
            return 1;
        }
    }

    internal static async Task<bool> RunCoreAsync(int parentId, string stagedExecutable, string targetExecutable,
        string stagingRoot, string? ownExecutablePath = null)
    {
        var own = ownExecutablePath ?? Environment.ProcessPath;
        if (own is null || !IsTrusted(stagedExecutable, targetExecutable, stagingRoot, own))
            return false;
        await WaitForExitAsync(parentId);
        if (!await ReplaceExecutableAsync(stagedExecutable, targetExecutable)) return false;
        try { Relaunch(targetExecutable); }
        catch (Exception ex) { LogFailure(ex); }
        TryDeleteDirectory(stagingRoot);
        return true;
    }

    private static bool IsTrusted(string stagedExecutable, string targetExecutable, string stagingRoot,
        string ownExecutablePath)
    {
        try
        {
            var tempRoot = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "PackMan"));
            var root = Path.GetFullPath(stagingRoot);
            var staged = Path.GetFullPath(stagedExecutable);
            var target = Path.GetFullPath(targetExecutable);
            var own = Path.GetFullPath(ownExecutablePath);
            return string.Equals(target, own, StringComparison.OrdinalIgnoreCase)
                && root.StartsWith(tempRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                && staged.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                && File.Exists(staged);
        }
        catch { return false; }
    }

    private static async Task WaitForExitAsync(int processId)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            using var waitLimit = new CancellationTokenSource(ExitWait);
            await process.WaitForExitAsync(waitLimit.Token);
        }
        catch (ArgumentException) { }
        catch (OperationCanceledException) { }
        await Task.Delay(250);
    }

    /// <summary>
    /// Swaps the new build in. The helper runs from the executable it is replacing - IsTrusted
    /// requires exactly that, so the target can only ever be PackMan's own path - which means
    /// Windows holds the target's image open and it can never be overwritten in place. Renaming
    /// a running image is allowed, so move it aside first and copy into the freed path. Any
    /// failure puts the backup back so the install is never left without an executable.
    /// </summary>
    private static async Task<bool> ReplaceExecutableAsync(string source, string destination)
    {
        var backup = destination + BackupSuffix;
        // A backup from the previous update is still held by that helper until it exits, so it
        // is cleared here - while this helper is elevated - rather than after the swap.
        TryDelete(backup);
        if (!await RetryAsync(() => File.Move(destination, backup, overwrite: true))) return false;
        if (await RetryAsync(() => File.Copy(source, destination, overwrite: true))) return true;
        try { File.Move(backup, destination, overwrite: true); }
        catch (Exception ex) { LogFailure(ex); }
        return false;
    }

    private static async Task<bool> RetryAsync(Action operation)
    {
        var deadline = DateTime.UtcNow + RetryWindow;
        while (true)
        {
            try
            {
                operation();
                return true;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                if (DateTime.UtcNow >= deadline)
                {
                    LogFailure(ex);
                    return false;
                }
                await Task.Delay(500);
            }
        }
    }

    internal static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { }
    }

    private static void Relaunch(string executable)
    {
        if (RelaunchOverride is { } relaunch)
        {
            relaunch(executable);
            return;
        }
        // Starting the app from an elevated helper would hand it the administrator token, so
        // PackMan - and every package manager it spawns - would stay elevated for the rest of
        // the session, which the app otherwise never does without asking. Going through Explorer
        // re-parents the launch to the shell, which runs at the user's own integrity level.
        // Explorer reports nothing back, so fall back to a direct start if nothing comes up.
        if (ProcessRunner.IsCurrentProcessElevated && TryRelaunchViaShell(executable)) return;
        Process.Start(new ProcessStartInfo(executable) { UseShellExecute = true });
    }

    private static bool TryRelaunchViaShell(string executable)
    {
        try
        {
            using var shell = Process.Start(new ProcessStartInfo("explorer.exe", $"\"{executable}\"")
            {
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            });
        }
        catch (Exception ex)
        {
            LogFailure(ex);
            return false;
        }
        return WaitForRelaunch(executable);
    }

    private static bool WaitForRelaunch(string executable)
    {
        var name = Path.GetFileNameWithoutExtension(executable);
        var self = Environment.ProcessId;
        var deadline = DateTime.UtcNow + RelaunchWait;
        while (DateTime.UtcNow < deadline)
        {
            foreach (var process in Process.GetProcessesByName(name))
            {
                using (process)
                {
                    if (process.Id != self) return true;
                }
            }
            Thread.Sleep(200);
        }
        return false;
    }

    private static void TryDeleteDirectory(string path)
    {
        try { Directory.Delete(path, recursive: true); } catch { }
    }

    internal static void LogFailure(Exception ex)
    {
        try
        {
            var directory = Path.Combine(Path.GetTempPath(), "PackMan");
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, "update-error.log");
            File.AppendAllText(path, $"[{DateTimeOffset.Now:O}] {ex}{Environment.NewLine}");
        }
        catch { }
    }
}
