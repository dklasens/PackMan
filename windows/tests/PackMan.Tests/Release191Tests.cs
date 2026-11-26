using System.Collections.Specialized;
using System.Net.Http;
using PackMan.Models;
using PackMan.Services;
using PackMan.ViewModels;

namespace PackMan.Tests;

public sealed class Release191Tests
{
    private static ToolContext Context(string path = "tool.exe", string version = "2") =>
        new(path, version, ToolResolutionOrigin.Custom, []);

    [Theory]
    [InlineData("Unexpected output")]
    [InlineData("")]
    [InlineData("Scoop bucket(s) out of date. Run 'scoop update' to get the latest changes.")]
    public void ScoopUnknownOrStaleStatusIsNotClean(string output) =>
        Assert.NotEmpty(ScoopStatusParser.Parse(output).Issues);

    [Fact]
    public void ScoopRecognizesActualCleanMessage()
    {
        var result = ScoopStatusParser.Parse("Scoop is up to date.\n\u001b[32mEverything is ok!\u001b[0m\n");
        Assert.Empty(result.Updates); Assert.Empty(result.Issues);
    }

    [Fact]
    public async Task NpmErrorOnlyOutputCannotMeanClean()
    {
        var runner = new StubRunner(); runner.Enqueue(new(1, "", "npm error registry unavailable"));
        await Assert.ThrowsAsync<SourceException>(() => new NpmSource(new StubResolver(), runner).ScanAsync(Context("npm.cmd")));
    }

    [Fact]
    public async Task NpmPreservesRecognizedUpdatesOnRegistryError()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(1, """{"example":{"current":"1","latest":"2"}}""", "npm error registry unavailable"));
        var report = await new NpmSource(new StubResolver(), runner).ScanAsync(Context("npm.cmd"));
        Assert.Single(report.Updates); Assert.NotEmpty(report.Issues);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("")]
    [InlineData("null")]
    [InlineData("{\"data\":{\"packages\":[null,{\"package\":\"example\",\"version\":\"1\"}]}}")]
    public async Task PipxUnknownSchemaCannotMeanClean(string json)
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "--outdated --output", "")); runner.Enqueue(new(0, json, ""));
        var report = await new PipxSource(new StubResolver(), runner).ScanAsync(Context("pipx.exe"));
        Assert.NotEmpty(report.Issues);
    }

    [Fact]
    public async Task PipxUsesEnvironmentIdentityAndReprobesChangedToolVersion()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "--outdated --output", ""));
        runner.Enqueue(new(0, """{"data":{"packages":[{"package":"ruff","environment":"ruff-alt","version":"1","latest_version":"2"}]}}""", ""));
        runner.Enqueue(new(0, "--outdated --output", ""));
        runner.Enqueue(new(0, """{"data":{"packages":[]}}""", ""));
        var source = new PipxSource(new StubResolver(), runner);
        var report = await source.ScanAsync(Context("pipx.exe", "1"));
        Assert.Equal("ruff-alt", Assert.Single(report.Updates).Id);
        Assert.Empty((await source.ScanAsync(Context("pipx.exe", "2"))).Issues);
        Assert.Equal(2, runner.Invocations.Count(invocation => invocation.Arguments.Contains("--help")));
    }

    [Fact]
    public async Task PipxLegacyChecksConfiguredEnvironmentAndSkipsPinnedOrCustomInstalls()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "list help", ""));
        runner.Enqueue(new(0, """
            {"venvs":{
              "ruff-alt":{"metadata":{"main_package":{"package":"ruff","package_version":"1.0","package_or_url":"ruff","pip_args":[]}}},
              "held":{"metadata":{"main_package":{"package":"held","package_version":"1","package_or_url":"held","pip_args":[],"pinned":true}}},
              "private":{"metadata":{"main_package":{"package":"private","package_version":"1","package_or_url":"private","pip_args":["--index-url","example.invalid"]}}}
            }}
            """, ""));
        runner.Enqueue(new(0, """[{"name":"ruff","version":"1.0","latest_version":"2.0"}]""", ""));
        var report = await new PipxSource(new StubResolver(), runner).ScanAsync(Context("pipx.exe"));
        Assert.Equal("ruff-alt", Assert.Single(report.Updates).Id);
        Assert.Single(report.Issues);
        Assert.Equal("ruff-alt", runner.Invocations.Last().Arguments[1]);
    }

    [Fact]
    public async Task DotnetDoesNotSubstitutePublicFeedForCustomFeed()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "Package Id   Version  Commands\n-----------------------------\nexample 1.0 example\n", ""));
        runner.Enqueue(new(0, "E https://api.nuget.org/v3/index.json\nE https://example.invalid/v3/index.json", ""));
        using var client = new HttpClient(new StubHttpHandler(_ => throw new InvalidOperationException("Public lookup must not run.")));
        var report = await new DotnetSource(new StubResolver(), runner, client).ScanAsync(Context("dotnet.exe"));
        Assert.Empty(report.Updates); Assert.Single(report.Issues);
    }

    [Fact]
    public async Task IgnoreIsRepositoryScopedAndLegacyRulesRemainBroad()
    {
        var settings = new MemorySettings();
        var source = new StubSource(SourceId.Winget, new([
            new("Example.App", "Example", "1", "2", Repository: "winget"),
            new("Example.App", "Example", "1", "2", Repository: "private")], []));
        var vm = Vm(source, settings);
        await Scan(vm);
        vm.IgnorePackageCommand.Execute(vm.Packages.First(p => p.Repository == "winget"));
        await Scan(vm);
        Assert.Equal("private", Assert.Single(vm.Packages).Repository);
        settings.SetUpdateIgnored("Winget:Example.App", true);
        await Scan(vm);
        Assert.Empty(vm.Packages);
        Assert.Equal(2, vm.IgnoredCount);
    }

    [Fact]
    public async Task OldDetailsCannotInstallAfterDisableIgnoreOrRescan()
    {
        var calls = 0;
        var source = new StubSource(SourceId.Npm, new([new("example", "Example", "1", "2")], []),
            _ => { calls++; return Task.CompletedTask; });
        var vm = Vm(source);
        await Scan(vm);
        var original = vm.Packages.Single(); vm.SelectedPackage = original;
        vm.SourceOptions.Single().IsEnabled = false;
        Assert.Null(vm.SelectedPackage);
        vm.RetryUpdateCommand.Execute(original);
        vm.SourceOptions.Single().IsEnabled = true;
        await Scan(vm);
        var rescanned = vm.Packages.Single(); vm.SelectedPackage = rescanned;
        await Scan(vm);
        vm.RetryUpdateCommand.Execute(rescanned);
        var ignored = vm.Packages.Single(); vm.SelectedPackage = ignored;
        vm.IgnorePackageCommand.Execute(ignored);
        Assert.Null(vm.SelectedPackage);
        vm.UpdateSingleCommand.Execute(ignored);
        vm.RetryElevatedCommand.Execute(original);
        await Idle(vm);
        Assert.Equal(0, calls);
    }

    [Fact]
    public async Task ExecutableOverrideChangesInvalidateOldDetails()
    {
        var settings = new MemorySettings();
        settings.SetExecutableOverride(ToolId.Npm, "custom.exe");
        var calls = 0;
        var vm = Vm(new StubSource(SourceId.Npm, new([new("example", "Example", "1", "2")], []),
            _ => { calls++; return Task.CompletedTask; }), settings);
        await Scan(vm);
        var old = vm.Packages.Single();
        vm.SelectedPackage = old;
        vm.UseAutomaticCommand.Execute(vm.SourceOptions.Single());
        Assert.Empty(vm.Packages);
        Assert.Null(vm.SelectedPackage);
        Assert.Equal(ScanSummaryKind.NeedsScan, vm.ScanSummary);
        vm.RetryUpdateCommand.Execute(old);
        Assert.Equal(0, calls);
    }

    [Fact]
    public async Task NewlyEnabledSourceInvalidatesCleanSummaryAndRetryRefreshesIt()
    {
        var settings = new MemorySettings(); settings.SetSourceEnabled(SourceId.Pip, false);
        var vm = new MainViewModel([new StubSource(SourceId.Npm, SourceScanReport.Empty),
            new StubSource(SourceId.Pip, SourceScanReport.Empty)], settings, new StubSourceInstaller());
        await Scan(vm);
        Assert.Equal(ScanSummaryKind.UpToDate, vm.ScanSummary);
        vm.SourceOptions.First(o => o.Id == SourceId.Pip).IsEnabled = true;
        Assert.Equal(ScanSummaryKind.NeedsScan, vm.ScanSummary);
        vm.RetryIssuesCommand.Execute(null); await Idle(vm);
        Assert.Equal(ScanSummaryKind.UpToDate, vm.ScanSummary);
    }

    [Fact]
    public async Task RemovingIgnoreRequiresFreshScan()
    {
        var vm = Vm(new StubSource(SourceId.Npm, new([new("example", "Example", "1", "2")], [])));
        await Scan(vm);
        vm.IgnorePackageCommand.Execute(vm.Packages.Single());
        vm.RemoveIgnoredCommand.Execute(vm.IgnoredUpdates.Single());
        Assert.Equal(ScanSummaryKind.NeedsScan, vm.ScanSummary);
        vm.RetryIssuesCommand.Execute(null); await Idle(vm);
        Assert.Single(vm.Packages);
    }

    [Fact]
    public async Task BrokenManagerIsNotOfferedForInstallationAndReprobeBlocksInstallation()
    {
        int probes = 0;
        var source = new StubSource(SourceId.Npm, SourceScanReport.Empty, probe: () => Task.FromResult(
            SourceProbe.Unavailable(++probes == 1
                ? new(SourceIssueKind.Unavailable, "npm not found")
                : new(SourceIssueKind.Configuration, "configured executable is broken"))));
        var installer = new StubSourceInstaller(_ => new("npm", "summary", false, []));
        var vm = new MainViewModel([source], new MemorySettings(), installer) { ConfirmInstall = _ => true };
        await Scan(vm);
        Assert.True(vm.SourceOptions.Single().CanInstall);
        vm.InstallSourceCommand.Execute(vm.SourceOptions.Single()); await Idle(vm);
        Assert.Empty(installer.Installed);
        Assert.False(vm.SourceOptions.Single().CanInstall);
    }

    [Fact]
    public async Task FailedRetryRemovesPreviousRowsAndDoesNotRepeatNetworkScan()
    {
        var source = new MutableSource();
        var vm = Vm(source);
        await Scan(vm);
        Assert.Single(vm.Packages);
        source.Fail = true;
        vm.RetryIssuesCommand.Execute(null); await Idle(vm);
        Assert.Empty(vm.Packages);
        Assert.Equal(2, source.Scans);
        Assert.Equal(1, source.Probes);
        Assert.Equal(ScanSummaryKind.CompletedWithIssues, vm.ScanSummary);
    }

    [Fact]
    public async Task SearchSelectionDistinguishesVisibleFromAllAndBatchesNotifications()
    {
        var vm = Vm(new StubSource(SourceId.Npm, new(Enumerable.Range(0, 100)
            .Select(i => new PackageInfo($"pkg{i}", i == 0 ? "Target" : $"Package {i}", "1", "2")).ToList(), [])));
        await Scan(vm);
        var notifications = 0;
        vm.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(vm.SelectedCount)) notifications++; };
        vm.SelectNoneCommand.Execute(null);
        Assert.Equal(1, notifications);
        vm.SearchText = "target npm pending";
        Assert.Equal(1, vm.VisibleCount);
        vm.SelectVisibleCommand.Execute(null);
        Assert.Equal(1, vm.SelectedCount);
        vm.SelectAllCommand.Execute(null);
        Assert.Equal(100, vm.SelectedCount);
        vm.DeselectVisibleCommand.Execute(null);
        Assert.Equal(99, vm.SelectedCount);
        vm.SearchText = "no match";
        Assert.True(vm.HasNoSearchMatches);
    }

    [Fact]
    public void SourceElapsedTimeResetsForNewScan()
    {
        var state = new SourceState();
        state.Set(SourceScanStatus.Probing);
        state.StartedAt = DateTimeOffset.Now.AddHours(-1);
        state.Set(SourceScanStatus.Succeeded);
        state.Set(SourceScanStatus.Waiting);
        Assert.Null(state.StartedAt);
        state.Set(SourceScanStatus.Scanning);
        Assert.True(DateTimeOffset.Now - state.StartedAt < TimeSpan.FromSeconds(5));
        Assert.Null(state.CompletedAt);
    }

    [Fact]
    public async Task NoNewerReleaseClearsOldBannerButNetworkErrorDoesNot()
    {
        var updater = new MutableUpdater();
        var vm = new MainViewModel([new StubSource(SourceId.Npm, SourceScanReport.Empty)],
            new MemorySettings(), new StubSourceInstaller(), updater);
        updater.Result = new("99.0", "u", "c", "r");
        vm.CheckForUpdatesCommand.Execute(null);
        Assert.True(vm.ShowAppUpdateBanner);
        updater.Fail = true;
        vm.CheckForUpdatesCommand.Execute(null);
        Assert.True(vm.ShowAppUpdateBanner);
        updater.Fail = false; updater.Result = null;
        vm.CheckForUpdatesCommand.Execute(null);
        Assert.False(vm.ShowAppUpdateBanner);
        await Task.CompletedTask;
    }

    [Theory]
    [InlineData("1!1.0", "2.0", 1)]
    [InlineData("1.0.dev1", "1.0a1", -1)]
    [InlineData("1.0rc1", "1.0", -1)]
    [InlineData("1.0", "1.0.0", 0)]
    [InlineData("1.0.post1.dev1", "1.0.post1", -1)]
    [InlineData("1.0+build.2", "1.0+build.10", -1)]
    [InlineData("1.0.post2", "1.0.post1", 1)]
    public void PythonVersionPrecedence(string left, string right, int expected) =>
        Assert.Equal(expected, Math.Sign(PackageVersions.ComparePython(left, right)!.Value));

    [Fact]
    public void NugetAndWingetCompareNumericRevisions()
    {
        Assert.Equal(1, Math.Sign(PackageVersions.CompareNuGet("1.0.0.4", "1.0.0.2")!.Value));
        Assert.Equal(-1, Math.Sign(PackageVersions.CompareNuGet("2.0.0-rc.2", "2.0.0-rc.10")!.Value));
        Assert.Equal(0, PackageVersions.CompareNuGet("1.2", "1.2.0.0"));
        Assert.Equal(1, Math.Sign(PackageVersions.CompareWinget("4.0.0.420000", "4.0.0.410000")!.Value));
        Assert.Null(PackageVersions.CompareWinget("2026 R2", "2026 R1"));
    }

    [Fact]
    public void CachedToolIsInvalidatedWhenExecutableChanges()
    {
        var directory = Directory.CreateTempSubdirectory("PackMan-cache191-");
        try
        {
            var path = Path.Combine(directory.FullName, "tool.exe");
            var settings = new SettingsService(Path.Combine(directory.FullName, "settings.json"));
            File.WriteAllText(path, "v1");
            settings.SetCachedContext(SourceId.Npm, Context(path, "1"));
            Assert.NotNull(settings.GetCachedContext(SourceId.Npm));
            File.WriteAllText(path, "v2 longer");
            Assert.Null(settings.GetCachedContext(SourceId.Npm));
        }
        finally { directory.Delete(true); }
    }

    [Fact]
    public void LongDiagnosticLinesRemainIntactExceptForCredentials()
    {
        var line = new string('x', 32_000);
        var redacted = DiagnosticRedactor.Redact(line + "\npassword: sample-secret");
        Assert.StartsWith(line, redacted);
        Assert.DoesNotContain("sample-secret", redacted);
    }

    [Fact]
    public async Task UpdateHistoryBatchesQueuedAndFinishedRecordsWithoutResettingCollection()
    {
        const int count = 100;
        var store = new CountingStore();
        var vm = Vm(new StubSource(SourceId.Npm, new(Enumerable.Range(0, count)
            .Select(i => new PackageInfo($"pkg{i}", $"Package {i}", "1", "2")).ToList(), [])), history: store);
        await Scan(vm);
        int resets = 0;
        vm.HistoryEntries.CollectionChanged += (_, e) => { if (e.Action == NotifyCollectionChangedAction.Reset) resets++; };
        vm.UpdateSelectedCommand.Execute(null); await Idle(vm);
        Assert.Equal(count, vm.UpdateSummary!.Updated);
        Assert.Equal(count * 2 + 2, store.Batches);
        Assert.Equal(count, store.Read().Count);
        Assert.Equal(0, resets);
    }

    [Fact]
    public async Task PersistentBatchRetainsInterruptedCheckpointAndAllOutcomes()
    {
        var directory = Directory.CreateTempSubdirectory("PackMan-history191-");
        try
        {
            var path = Path.Combine(directory.FullName, "history.json");
            var store = new UpdateHistoryStore(path);
            var first = Entry(); var second = Entry();
            await store.SaveRangeAsync([first, second]);
            await store.SaveRangeAsync([first with { Outcome = HistoryOutcome.Running }]);
            Assert.Contains(new UpdateHistoryStore(path).Read(), e => e.Id == first.Id && e.Outcome == HistoryOutcome.Interrupted);
            await store.SaveRangeAsync([first with { Outcome = HistoryOutcome.Updated }, second with { Outcome = HistoryOutcome.Failed }]);
            Assert.Equal(2, new UpdateHistoryStore(path).Read().Count);
            Assert.All(new UpdateHistoryStore(path).Read(), e => Assert.NotEqual(HistoryOutcome.Running, e.Outcome));
        }
        finally { directory.Delete(true); }
    }

    private static UpdateHistoryEntry Entry() => new(Guid.NewGuid(), Guid.NewGuid(), DateTimeOffset.Now, null,
        SourceId.Npm, "example", "Example", null, "1", "2", null, HistoryOutcome.NotStarted, RestartState.None, null, null, "tool", "");
    private sealed class CountingStore : IUpdateHistoryStore
    {
        private readonly UpdateHistoryStore _inner = new(null);
        public int Batches { get; private set; }
        public string? LoadIssue => null;
        public IReadOnlyList<UpdateHistoryEntry> Read() => _inner.Read();
        public void Save(UpdateHistoryEntry entry) => _inner.Save(entry);
        public Task SaveRangeAsync(IReadOnlyList<UpdateHistoryEntry> entries) { Batches++; return _inner.SaveRangeAsync(entries); }
    }
    private sealed class MutableSource : IPackageSource
    {
        public SourceDescriptor Descriptor { get; } = new(SourceId.Npm, "npm", ToolId.Npm, "tool", []);
        public bool Fail { get; set; }
        public int Scans { get; private set; }
        public int Probes { get; private set; }
        public Task<SourceProbe> ProbeAsync(CancellationToken cancellationToken = default)
        { Probes++; return Task.FromResult(SourceProbe.Available(Context())); }
        public Task<SourceScanReport> ScanAsync(ToolContext context, IProgress<SourcePhase>? progress = null, CancellationToken cancellationToken = default)
        {
            Scans++;
            if (Fail) throw new SourceException(SourceIssueKind.Network, "offline");
            return Task.FromResult(new SourceScanReport([new("example", "Example", "1", "2")], [new(SourceIssueKind.Network, "partial")]));
        }
        public Task<UpdateResult> UpdateAsync(UpdateRequest request, ToolContext context, IProgress<ProcessOutputEvent>? output = null,
            CancellationToken cancellationToken = default) => throw new InvalidOperationException();
        public Task<IReadOnlyDictionary<string, UpdateVerification>> VerifyAsync(IReadOnlyList<UpdateRequest> requests, ToolContext context,
            CancellationToken cancellationToken = default) => throw new InvalidOperationException();
    }
    private sealed class MutableUpdater : IAppUpdateService
    {
        public AppUpdateInfo? Result { get; set; }
        public bool Fail { get; set; }
        public Task<AppUpdateInfo?> CheckAsync(bool force = false, CancellationToken cancellationToken = default) =>
            Fail ? Task.FromException<AppUpdateInfo?>(new Exception("offline")) : Task.FromResult(Result);
        public Task ApplyAsync(AppUpdateInfo update, IProgress<string>? progress, CancellationToken cancellationToken) =>
            throw new InvalidOperationException();
    }
    private static MainViewModel Vm(IPackageSource source, ISettingsService? settings = null, IUpdateHistoryStore? history = null) =>
        new([source], settings ?? new MemorySettings(), new StubSourceInstaller(), history: history);
    private static async Task Scan(MainViewModel vm)
    { vm.ScanOrCancelCommand.Execute(null); await Idle(vm); }
    private static async Task Idle(MainViewModel vm)
    {
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        while (vm.IsBusy) await Task.Delay(10, limit.Token);
    }
}
