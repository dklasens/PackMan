using PackMan.Models;
using PackMan.Services;
using PackMan.ViewModels;

namespace PackMan.Tests;

public sealed class HistoryAndCacheTests
{
    [Fact]
    public void HistorySurvivesRestartAndMarksInterruptedCommands()
    {
        var directory = Directory.CreateTempSubdirectory("PackMan-history-");
        try
        {
            var path = Path.Combine(directory.FullName, "history.json");
            var store = new UpdateHistoryStore(path);
            var record = Entry(HistoryOutcome.Running);
            store.Save(record);
            var reloaded = new UpdateHistoryStore(path).Read().Single();
            Assert.Equal(HistoryOutcome.Interrupted, reloaded.Outcome);
            Assert.Equal(record.PackageId, reloaded.PackageId);
            store.Save(record with { Outcome = HistoryOutcome.Updated, InstalledVersion = "2.1", FinishedAt = DateTimeOffset.Now });
            reloaded = new UpdateHistoryStore(path).Read().Single();
            Assert.Equal(HistoryOutcome.Updated, reloaded.Outcome); Assert.Equal("2.1", reloaded.InstalledVersion);
        }
        finally { directory.Delete(true); }
    }

    [Fact]
    public void CorruptHistoryIsVisibleAndDoesNotPreventStartup()
    {
        var directory = Directory.CreateTempSubdirectory("PackMan-history-");
        try
        {
            var path = Path.Combine(directory.FullName, "history.json");
            File.WriteAllText(path, "not json");
            var store = new UpdateHistoryStore(path);
            Assert.NotNull(store.LoadIssue); Assert.Empty(store.Read());
        }
        finally { directory.Delete(true); }
    }

    [Theory]
    [InlineData("https://user:secret@registry.test/pkg", "secret")]
    [InlineData("Authorization: Bearer abc123", "abc123")]
    [InlineData("npm_token=abc123", "abc123")]
    [InlineData("password: abc123", "abc123")]
    [InlineData("{\"api_key\":\"abc123\"}", "abc123")]
    [InlineData("https://registry.test/pkg?sig=abc123&version=2", "abc123")]
    public void DiagnosticsRedactCredentials(string text, string secret) =>
        Assert.DoesNotContain(secret, DiagnosticRedactor.Redact(text));

    [Fact]
    public void HistoryIsBoundedAndReplacesAnAttemptWithoutDuplicatingIt()
    {
        var store = new UpdateHistoryStore(null);
        for (var i = 0; i < 501; i++) store.Save(Entry(HistoryOutcome.Updated));
        Assert.Equal(500, store.Read().Count);
        var record = store.Read()[0];
        store.Save(record with { Message = "changed" });
        Assert.Equal(500, store.Read().Count); Assert.Equal("changed", store.Read()[0].Message);
    }

    [Fact]
    public async Task MixedRunPersistsActualVersionsAndDoesNotLoseFailureSummary()
    {
        var store = new UpdateHistoryStore(null);
        var report = new SourceScanReport([new("a", "A", "1", "2"), new("b", "B", "1", "2")], []);
        var source = new StubSource(SourceId.Npm, report,
            request => request.PackageId == "b" ? Task.FromException(new Exception("failed")) : Task.CompletedTask,
            requests => Task.FromResult<IReadOnlyDictionary<string, UpdateVerification>>(
                requests.ToDictionary(r => r.Identity, _ => new UpdateVerification(true, "2.1", Evidence: "Inventory confirmed 2.1"))));
        var vm = new MainViewModel([source], new MemorySettings(), new StubSourceInstaller(), history: store);
        vm.ScanOrCancelCommand.Execute(null); await Idle(vm);
        vm.UpdateSelectedCommand.Execute(null); await Idle(vm);
        Assert.Equal(1, vm.UpdateSummary!.Updated); Assert.Equal(1, vm.UpdateSummary.Failed);
        Assert.True(vm.HasUpdateSummary); Assert.Contains("1 failed", vm.UpdateSummaryText);
        Assert.Equal("2.1", store.Read().Single(e => e.PackageId == "a").InstalledVersion);
        Assert.Equal("1", store.Read().Single(e => e.PackageId == "a").BeforeVersion);
        Assert.Equal(HistoryOutcome.Failed, store.Read().Single(e => e.PackageId == "b").Outcome);
    }

    [Fact]
    public async Task FailedVerificationRecordsUnverifiedAndRetriesWithoutInstalling()
    {
        var calls = 0;
        var source = new StubSource(SourceId.Npm, new([new("a", "A", "1", "2")], []),
            _ => { calls++; return Task.CompletedTask; }, _ => throw new Exception("offline"));
        var vm = new MainViewModel([source], new MemorySettings(), new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null); await Idle(vm);
        vm.UpdateSelectedCommand.Execute(null); await Idle(vm);
        Assert.Equal(HistoryOutcome.Unverified, vm.HistoryEntries.Single().Outcome);
        vm.RetryFailedCommand.Execute(null); await Idle(vm);
        Assert.Equal(1, calls); Assert.Equal(2, vm.HistoryEntries.Count);
    }

    [Fact]
    public async Task CleanupOnlyTouchesSelectedSourcesAndPreviewsBeforeConfirmation()
    {
        var cleared = new List<SourceId>();
        var source = new StubSource(SourceId.Npm, SourceScanReport.Empty,
            clearCache: _ => { cleared.Add(SourceId.Npm); return Task.FromResult("cleared npm"); });
        var other = new StubSource(SourceId.Dotnet, SourceScanReport.Empty,
            clearCache: _ => throw new Exception("Deselected source must never be touched"));
        var inspector = new StubInspector();
        var vm = new MainViewModel([source, other], new MemorySettings(), new StubSourceInstaller(), cacheInspector: inspector);
        vm.CacheOptions.Single(i => i.Id == SourceId.Dotnet).IsSelected = false;
        vm.ConfirmCacheClear = message =>
        {
            Assert.Equal(new[] { SourceId.Npm }, inspector.Inspected);
            Assert.Contains("2.0 MB", message); Assert.DoesNotContain("NuGet", message);
            return true;
        };
        vm.ClearCacheCommand.Execute(null); await Idle(vm);
        Assert.Equal(new[] { SourceId.Npm }, cleared);
        Assert.Equal("cleared npm", vm.CacheOptions.Single(i => i.Id == SourceId.Npm).ResultText);
    }

    [Fact]
    public async Task CacheMeasurementDeduplicatesOverlappingPathsAndHonorsCancellation()
    {
        var directory = Directory.CreateTempSubdirectory("PackMan-cache-");
        try
        {
            var child = Directory.CreateDirectory(Path.Combine(directory.FullName, "child"));
            await File.WriteAllBytesAsync(Path.Combine(child.FullName, "cache.bin"), new byte[1024]);
            var result = await CacheInspector.MeasureAsync([directory.FullName, child.FullName], CancellationToken.None);
            Assert.Equal(1024, result.Bytes); Assert.True(result.Complete);
            using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => CacheInspector.MeasureAsync([directory.FullName], cancellation.Token));
        }
        finally { directory.Delete(true); }
    }

    [Fact]
    public async Task PreviewUsesConfiguredNpmCacheWithoutCleaningAnything()
    {
        var directory = Directory.CreateTempSubdirectory("PackMan-cache-");
        try
        {
            await File.WriteAllBytesAsync(Path.Combine(directory.FullName, "cache.bin"), new byte[2048]);
            var runner = new StubRunner(); runner.Enqueue(new(0, directory.FullName, ""));
            var preview = await new CacheInspector(runner).PreviewAsync(new NpmSource(new StubResolver(), runner),
                new("npm.cmd", "12", ToolResolutionOrigin.Custom, []), CancellationToken.None);
            Assert.Equal(2048, preview.Bytes); Assert.True(File.Exists(Path.Combine(directory.FullName, "cache.bin")));
            Assert.Equal(new[] { "config", "get", "cache" }, runner.Invocations.Single().Arguments);
        }
        finally { directory.Delete(true); }
    }

    [Fact]
    public void MetadataAcceptsWebLinksAndRejectsExecutableSchemes()
    {
        var links = PackageMetadataService.ParseWinget("Publisher Url: https://example.test\nRelease Notes Url: https://example.test/releases/2");
        Assert.Equal("https://example.test/", links.PublisherUrl);
        Assert.Equal("https://example.test/releases/2", links.ReleaseNotesUrl);
        Assert.Null(PackageMetadataService.SafeUrl("file:///C:/bad.exe"));
        Assert.Null(PackageMetadataService.SafeUrl("https://user:password@example.test"));
    }

    private static UpdateHistoryEntry Entry(HistoryOutcome outcome) => new(Guid.NewGuid(), Guid.NewGuid(), DateTimeOffset.Now,
        null, SourceId.Npm, "example", "Example", null, "1", "2", null, outcome, RestartState.None, null, null, "npm.cmd", "");
    private static async Task Idle(MainViewModel vm)
    {
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (vm.IsBusy) await Task.Delay(10, limit.Token);
    }
    private sealed class StubInspector : ICacheInspector
    {
        public List<SourceId> Inspected { get; } = [];
        public Task<CachePreview> PreviewAsync(IPackageSource source, ToolContext context, CancellationToken cancellationToken)
        {
            Inspected.Add(source.Id);
            return Task.FromResult(new CachePreview(CacheInspector.ScopeFor(source.Id), [], 2 * 1048576));
        }
    }
}
