using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using PackMan.Services;

namespace PackMan.Tests;

public sealed class AppUpdateTests
{
    private const string NewerVersion = "99.0.0";
    private const string DownloadUrl = "https://release.test/PackMan-Windows-x64.zip";
    private const string ChecksumUrl = "https://release.test/PackMan-Windows-x64.zip.sha256";
    private const string ReleaseUrl = "https://github.com/dklasens/PackMan/releases/tag/v99.0.0";

    [Fact]
    public async Task NewerReleaseIsDetectedWithWindowsAssets()
    {
        var settings = new MemorySettings();
        var service = new AppUpdateService(ApiClient(ReleaseJson(NewerVersion)), settings);

        var update = await service.CheckAsync(force: true);

        Assert.NotNull(update);
        Assert.Equal(NewerVersion, update!.Version);
        Assert.Equal(DownloadUrl, update.DownloadUrl);
        Assert.Equal(ChecksumUrl, update.ChecksumUrl);
        Assert.Equal(ReleaseUrl, update.ReleaseUrl);
        Assert.NotNull(settings.GetLastAppUpdateCheck());
        Assert.Equal(update, settings.GetAvailableAppUpdate());
    }

    [Fact]
    public async Task OlderReleaseReturnsNullAndClearsPersistedUpdate()
    {
        var settings = new MemorySettings
        {
            AvailableAppUpdate = new AppUpdateInfo(NewerVersion, DownloadUrl, ChecksumUrl, ReleaseUrl),
        };
        var service = new AppUpdateService(ApiClient(ReleaseJson("0.0.1")), settings);

        Assert.Null(await service.CheckAsync(force: true));
        Assert.Null(settings.GetAvailableAppUpdate());
    }

    [Fact]
    public async Task PrereleasesAndDraftsAreIgnored()
    {
        var prerelease = new AppUpdateService(ApiClient(ReleaseJson(NewerVersion, prerelease: true)), new MemorySettings());
        var draft = new AppUpdateService(ApiClient(ReleaseJson(NewerVersion, draft: true)), new MemorySettings());
        Assert.Null(await prerelease.CheckAsync(force: true));
        Assert.Null(await draft.CheckAsync(force: true));
    }

    [Fact]
    public async Task MissingWindowsAssetReturnsNull()
    {
        var json = ReleaseJson(NewerVersion, includeWindowsAssets: false);
        var service = new AppUpdateService(ApiClient(json), new MemorySettings());
        Assert.Null(await service.CheckAsync(force: true));
    }

    [Fact]
    public async Task NoReleasesAtAllReturnsNull()
    {
        var client = new HttpClient(new StubHttpHandler(_ =>
            new HttpResponseMessage(HttpStatusCode.NotFound) { Content = new StringContent("{}") }));
        var service = new AppUpdateService(client, new MemorySettings());
        Assert.Null(await service.CheckAsync(force: true));
    }

    [Fact]
    public async Task ThrottledCheckUsesPersistedUpdateWithoutNetwork()
    {
        var settings = new MemorySettings
        {
            LastAppUpdateCheck = DateTimeOffset.UtcNow,
            AvailableAppUpdate = new AppUpdateInfo(NewerVersion, DownloadUrl, ChecksumUrl, ReleaseUrl),
        };
        var client = new HttpClient(new StubHttpHandler(_ =>
            throw new InvalidOperationException("No network call is expected while throttled.")));
        var service = new AppUpdateService(client, settings);

        var update = await service.CheckAsync(force: false);

        Assert.Equal(NewerVersion, update!.Version);
    }

    [Fact]
    public async Task SkippedVersionIsHiddenUntilForced()
    {
        var settings = new MemorySettings
        {
            LastAppUpdateCheck = DateTimeOffset.UtcNow,
            AvailableAppUpdate = new AppUpdateInfo(NewerVersion, DownloadUrl, ChecksumUrl, ReleaseUrl),
            SkippedAppUpdateVersion = NewerVersion,
        };
        var service = new AppUpdateService(ApiClient(ReleaseJson(NewerVersion)), settings);

        Assert.Null(await service.CheckAsync(force: false));
        Assert.Equal(NewerVersion, (await service.CheckAsync(force: true))!.Version);
    }

    [Fact]
    public async Task ApplyStagesVerifiedExecutableAndLaunchesHelper()
    {
        var (client, payload) = BuildReleaseClient();
        var service = new AppUpdateService(client, new MemorySettings());
        (int Pid, string Staged, string Target, string Root, bool Elevated)? launch = null;
        service.LaunchApplyHelper = (pid, staged, target, root, elevated) =>
        {
            launch = (pid, staged, target, root, elevated);
            return true;
        };

        await service.ApplyAsync(new AppUpdateInfo(NewerVersion, DownloadUrl, ChecksumUrl, ReleaseUrl),
            null, CancellationToken.None);

        Assert.NotNull(launch);
        var started = launch!.Value;
        Assert.Equal(Environment.ProcessId, started.Pid);
        Assert.Equal(Environment.ProcessPath, started.Target);
        Assert.True(File.Exists(started.Staged));
        Assert.Equal(payload, File.ReadAllBytes(started.Staged));
        var stagingRoot = Path.Combine(Path.GetTempPath(), "PackMan", "update");
        Assert.True(Directory.Exists(stagingRoot));
        Directory.Delete(stagingRoot, recursive: true);
    }

    [Fact]
    public async Task ChecksumMismatchRejectsUpdate()
    {
        var (zipBytes, _) = BuildZipWithExecutable();
        var client = new HttpClient(new StubHttpHandler(uri => uri.AbsoluteUri == DownloadUrl
            ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(zipBytes) }
            : new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent($"{new string('0', 64)}  PackMan-Windows-x64.zip"),
            }));
        var service = new AppUpdateService(client, new MemorySettings());
        service.LaunchApplyHelper = (_, _, _, _, _) => true;

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            service.ApplyAsync(new AppUpdateInfo(NewerVersion, DownloadUrl, ChecksumUrl, ReleaseUrl), null, CancellationToken.None));
        Assert.Contains("checksum", ex.Message, StringComparison.OrdinalIgnoreCase);
        var stagingRoot = Path.Combine(Path.GetTempPath(), "PackMan", "update");
        if (Directory.Exists(stagingRoot)) Directory.Delete(stagingRoot, recursive: true);
    }

    [Fact]
    public async Task DeclinedElevationDuringApplyThrows()
    {
        var (client, _) = BuildReleaseClient();
        var service = new AppUpdateService(client, new MemorySettings());
        service.LaunchApplyHelper = (_, _, _, _, _) => false;

        await Assert.ThrowsAsync<ElevationDeclinedException>(() =>
            service.ApplyAsync(new AppUpdateInfo(NewerVersion, DownloadUrl, ChecksumUrl, ReleaseUrl), null, CancellationToken.None));
        var stagingRoot = Path.Combine(Path.GetTempPath(), "PackMan", "update");
        if (Directory.Exists(stagingRoot)) Directory.Delete(stagingRoot, recursive: true);
    }

    [Fact]
    public void ApplyModeArgumentShapeIsVerified()
    {
        Assert.True(UpdateApplier.IsApplyMode(["--apply-update", "4242", "staged", "target", "root"]));
        Assert.False(UpdateApplier.IsApplyMode(["--apply-update", "not-a-pid", "staged", "target", "root"]));
        Assert.False(UpdateApplier.IsApplyMode(["--apply-update", "4242", "staged", "target"]));
        Assert.False(UpdateApplier.IsApplyMode(["--apply-update", "4242", " ", "target", "root"]));
        Assert.False(UpdateApplier.IsApplyMode(["--elevated-helper", "pipe"]));
    }

    [Fact]
    public async Task InvalidApplyArgumentsExitWithoutAction()
    {
        Assert.Equal(2, await UpdateApplier.RunAsync(["--apply-update"]));
    }

    [Fact]
    public async Task ApplyReplacesTargetAndRelaunches()
    {
        var stagingRoot = Path.Combine(Path.GetTempPath(), "PackMan", $"test-{Guid.NewGuid():N}");
        var installRoot = Path.Combine(Path.GetTempPath(), "PackMan", $"test-install-{Guid.NewGuid():N}");
        var staged = Path.Combine(stagingRoot, "staged", "PackMan.exe");
        var target = Path.Combine(installRoot, "PackMan.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(staged)!);
        Directory.CreateDirectory(installRoot);
        File.WriteAllText(staged, "new-bits");
        File.WriteAllText(target, "old-bits");
        var relaunched = new List<string>();
        UpdateApplier.RelaunchOverride = relaunched.Add;
        var parentId = LaunchAlreadyExitedProcess();
        try
        {
            var ok = await UpdateApplier.RunCoreAsync(parentId, staged, target, stagingRoot, target);
            Assert.True(ok);
            Assert.Equal("new-bits", File.ReadAllText(target));
            Assert.Equal([target], relaunched);
            Assert.False(Directory.Exists(stagingRoot));
        }
        finally
        {
            UpdateApplier.RelaunchOverride = null;
            if (Directory.Exists(installRoot)) Directory.Delete(installRoot, recursive: true);
        }
    }

    [Fact]
    public async Task ApplyRefusesTargetsOtherThanItself()
    {
        var stagingRoot = Path.Combine(Path.GetTempPath(), "PackMan", $"test-{Guid.NewGuid():N}");
        var staged = Path.Combine(stagingRoot, "staged", "PackMan.exe");
        var target = Path.Combine(stagingRoot, "PackMan.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(staged)!);
        File.WriteAllText(staged, "new-bits");
        var parentId = LaunchAlreadyExitedProcess();
        try
        {
            var ok = await UpdateApplier.RunCoreAsync(parentId, staged, target, stagingRoot,
                Path.Combine(stagingRoot, "somewhere-else.exe"));
            Assert.False(ok);
            Assert.False(File.Exists(target));
        }
        finally { if (Directory.Exists(stagingRoot)) Directory.Delete(stagingRoot, recursive: true); }
    }

    [Fact]
    public async Task ApplyRefusesStagedFilesOutsideTheStagingRoot()
    {
        var stagingRoot = Path.Combine(Path.GetTempPath(), "PackMan", $"test-{Guid.NewGuid():N}");
        var outside = Path.Combine(Path.GetTempPath(), $"stray-{Guid.NewGuid():N}.exe");
        var target = Path.Combine(stagingRoot, "PackMan.exe");
        File.WriteAllText(outside, "stray");
        var parentId = LaunchAlreadyExitedProcess();
        try
        {
            var ok = await UpdateApplier.RunCoreAsync(parentId, outside, target, stagingRoot, target);
            Assert.False(ok);
        }
        finally { File.Delete(outside); }
    }

    private static int LaunchAlreadyExitedProcess()
    {
        using var process = Process.Start(new ProcessStartInfo("cmd.exe", "/c exit"));
        process!.WaitForExit();
        return process.Id;
    }

    private static HttpClient ApiClient(string releaseJson) => new(new StubHttpHandler(uri =>
        new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(releaseJson, Encoding.UTF8) }));

    private static string ReleaseJson(string tag, bool draft = false, bool prerelease = false,
        bool includeWindowsAssets = true)
    {
        var assets = includeWindowsAssets
            ? $$"""
              { "name": "PackMan-Windows-x64.zip", "browser_download_url": "{{DownloadUrl}}" },
              { "name": "PackMan-Windows-x64.zip.sha256", "browser_download_url": "{{ChecksumUrl}}" },
            """
            : string.Empty;
        return $$"""
            {
              "tag_name": "v{{tag}}",
              "html_url": "{{ReleaseUrl}}",
              "draft": {{(draft ? "true" : "false")}},
              "prerelease": {{(prerelease ? "true" : "false")}},
              "assets": [
                {{assets}}{ "name": "PackMan-macOS.zip", "browser_download_url": "https://release.test/mac.zip" }
              ]
            }
            """;
    }

    private static (byte[] ZipBytes, byte[] Payload) BuildZipWithExecutable()
    {
        var payload = Encoding.UTF8.GetBytes($"packman-bits-{Guid.NewGuid():N}");
        using var zipStream = new MemoryStream();
        using (var archive = new ZipArchive(zipStream, ZipArchiveMode.Create, leaveOpen: true))
        {
            var entry = archive.CreateEntry(Path.GetFileName(Environment.ProcessPath ?? "PackMan.exe"));
            using var entryStream = entry.Open();
            entryStream.Write(payload);
        }
        return (zipStream.ToArray(), payload);
    }

    private static (HttpClient Client, byte[] Payload) BuildReleaseClient()
    {
        var (zipBytes, payload) = BuildZipWithExecutable();
        var hash = Convert.ToHexStringLower(SHA256.HashData(zipBytes));
        var client = new HttpClient(new StubHttpHandler(uri => uri.AbsoluteUri == DownloadUrl
            ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(zipBytes) }
            : new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent($"{hash}  PackMan-Windows-x64.zip"),
            }));
        return (client, payload);
    }
}
