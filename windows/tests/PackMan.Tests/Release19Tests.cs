using PackMan.Models;
using PackMan.Services;
using PackMan.ViewModels;

namespace PackMan.Tests;

public sealed class Release19Tests
{
    private static ToolContext Context => new("tool.exe", "2.0", ToolResolutionOrigin.Custom, []);

    [Theory]
    [InlineData("")]
    [InlineData("Unexpected format\n")]
    [InlineData("Name              Id                 Version  Available  Source\n---------------------------------------------------------------\nbroken row\n")]
    public async Task UnrecognizedWingetScanIsNotClean(string output)
    {
        var runner = new StubRunner(); runner.Enqueue(new(0, output, ""));
        var report = await new WingetSource(new StubResolver(), runner).ScanAsync(Context);
        Assert.NotEmpty(report.Issues);
    }

    [Theory]
    [InlineData("No available upgrade found.")]
    [InlineData("No installed package found matching input criteria.")]
    public void RecognizedWingetEmptyResultIsClean(string text) =>
        Assert.Equal(0, WingetUpgradeParser.Parse(text).RejectedRows);

    [Fact]
    public async Task MissingWingetInventoryCannotVerifyAnUpdate()
    {
        var runner = new StubRunner(); runner.Enqueue(new(0, "Unexpected format", ""));
        await Assert.ThrowsAsync<SourceException>(() => new WingetSource(new StubResolver(), runner)
            .VerifyAsync([new("Example.App", "Example", "2")], Context));
    }

    [Fact]
    public async Task WingetUsesStructuredInventoryAndPreservesRepositoryIdentity()
    {
        var runner = new ExportRunner("""
            {"Sources":[{"SourceDetails":{"Name":"winget"},"Packages":[{"PackageIdentifier":"Example.App","Version":"2.0"}]},
            {"SourceDetails":{"Name":"private"},"Packages":[{"PackageIdentifier":"Example.App","Version":"1.0"}]}]}
            """);
        var source = new WingetSource(new StubResolver(), runner);
        var results = await source.VerifyAsync([new("Example.App", "Example", "2.0", Repository: "winget"),
            new("Example.App", "Example", "2.0", Repository: "private")], Context);
        Assert.True(results["winget:Example.App"].IsSatisfied);
        Assert.Equal("2.0", results["winget:Example.App"].InstalledVersion);
        Assert.False(results["private:Example.App"].IsSatisfied);
        Assert.False(File.Exists(runner.ExportPath));
    }

    [Fact]
    public void TruncatedIdentifiersResolveOnlyAgainstOneMatchingInstalledPackage()
    {
        var row = new WingetUpgradeRow("Example", "Vendor.App", "1", "2", "winget", true, true);
        var resolved = WingetSource.ResolveTruncated([row], [new("Vendor.App.Full", "winget", "1")]).Single();
        Assert.Equal("Vendor.App.Full", resolved.Id);
        Assert.False(resolved.IdentityTruncated);
        Assert.True(WingetSource.ResolveTruncated([row], [new("Vendor.App.One", "winget", "1"),
            new("Vendor.App.Two", "winget", "1")]).Single().IdentityTruncated);
        Assert.True(WingetSource.ResolveTruncated([row], [new("Vendor.App.Full", "other", "1")]).Single().IdentityTruncated);
    }

    [Fact]
    public async Task WingetUnknownVersionChoiceControlsDiscoveryAndExecution()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "No available upgrade found.", ""));
        runner.Enqueue(new(0, "No available upgrade found.", ""));
        runner.Enqueue(new(0, "updated", ""));
        var settings = new MemorySettings();
        var source = new WingetSource(new StubResolver(), runner, settings);
        await source.ScanAsync(Context);
        Assert.DoesNotContain("--include-unknown", runner.Invocations[0].Arguments);
        settings.IncludeUnknownVersions = true;
        await source.ScanAsync(Context);
        Assert.Contains("--include-unknown", runner.Invocations[1].Arguments);
        await source.UpdateAsync(new("Example.App", "Example", "2", Repository: "private",
            AllowUnknownVersion: true, Interactive: true), Context);
        var args = runner.Invocations[2].Arguments;
        Assert.Contains("--include-unknown", args);
        Assert.Contains("--source", args); Assert.Contains("private", args);
        Assert.Contains("--interactive", args); Assert.DoesNotContain("--silent", args);
    }

    [Fact]
    public async Task ChocolateyOutdatedCodeTwoPreservesResults()
    {
        var runner = new StubRunner(); runner.Enqueue(new(2, "example|1|2|false", ""));
        Assert.Single((await new ChocoSource(new StubResolver(), runner).ScanAsync(Context)).Updates);
    }

    [Theory]
    [InlineData(0, RestartState.None)]
    [InlineData(2, RestartState.None)]
    [InlineData(3010, RestartState.Required)]
    [InlineData(1641, RestartState.Initiated)]
    public async Task ChocolateyKeepsSuccessAndRebootOutcomes(int code, RestartState restart)
    {
        var runner = new StubRunner(); runner.Enqueue(new(code, "completed", ""));
        var result = await new ChocoSource(new StubResolver(), runner).UpdateAsync(new("example", "Example", "2"), Context);
        Assert.Equal(restart, result.Restart); Assert.Equal(code, result.ExitCode);
    }

    [Fact]
    public async Task ChocolateyFailureStillFails()
    {
        var runner = new StubRunner(); runner.Enqueue(new(1, "failed", ""));
        await Assert.ThrowsAsync<SourceException>(() => new ChocoSource(new StubResolver(), runner)
            .UpdateAsync(new("example", "Example", "2"), Context));
    }

    [Fact]
    public void LocalizedDotnetTableCannotSilentlyDisappear()
    {
        Assert.NotEmpty(DotnetToolListParser.Parse("Paket-ID Version Befehle\n-------------------\nexample 1.0 example").Issues);
        Assert.Empty(DotnetToolListParser.Parse("Package Id      Version      Commands\n--------------------------------------").Issues);
    }

    [Fact]
    public async Task NpmVerificationReadsActualInstalledVersion()
    {
        var runner = new StubRunner(); runner.Enqueue(new(0, """{"dependencies":{"example":{"version":"1.0"}}}""", ""));
        var result = (await new NpmSource(new StubResolver(), runner).VerifyAsync([new("example", "Example", "2.0")], Context))["example"];
        Assert.False(result.IsSatisfied); Assert.Equal("1.0", result.InstalledVersion);
        Assert.NotNull(result.StillOutdated);
    }

    [Fact]
    public async Task ConfirmedOlderVersionRetriesInstallationInsteadOfOnlyVerifying()
    {
        var runner = new StubRunner(); runner.Enqueue(new(0, """{"dependencies":{"example":{"version":"1.5"}}}""", ""));
        var observed = (await new NpmSource(new StubResolver(), runner).VerifyAsync([new("example", "Example", "2.0")], Context))["example"];
        var calls = 0;
        var vm = Vm(new StubSource(SourceId.Npm, new([new("example", "Example", "1.0", "2.0")], []),
            _ => { calls++; return Task.CompletedTask; }, requests => Task.FromResult<IReadOnlyDictionary<string, UpdateVerification>>(
                requests.ToDictionary(r => r.Identity, _ => observed))));
        vm.ScanOrCancelCommand.Execute(null); await Idle(vm);
        vm.UpdateSelectedCommand.Execute(null); await Idle(vm);
        Assert.Equal("1.5", vm.Packages.Single().CurrentVersion);
        Assert.Equal(UpdateFailureKind.Update, vm.Packages.Single().FailureKind);
        Assert.Equal(HistoryOutcome.Failed, vm.HistoryEntries.Single().Outcome);
        vm.RetryFailedCommand.Execute(null); await Idle(vm);
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task IgnoringLastVisibleUpdateImmediatelyExplainsTheEmptyTable()
    {
        var vm = Vm(new StubSource(SourceId.Npm, new([new("example", "Example", "1", "2")], [])));
        vm.ScanOrCancelCommand.Execute(null); await Idle(vm);
        vm.IgnorePackageCommand.Execute(vm.Packages.Single());
        Assert.Equal(ScanSummaryKind.IgnoredOnly, vm.ScanSummary);
        Assert.Equal(1, vm.IgnoredCount);
    }

    [Fact]
    public async Task AScanWarningDoesNotSkipFirstInstallation()
    {
        var calls = 0;
        var vm = Vm(new StubSource(SourceId.Npm, new([new("example", "Example", "1", "2", "Display name shortened")], []),
            _ => { calls++; return Task.CompletedTask; }));
        vm.ScanOrCancelCommand.Execute(null); await Idle(vm);
        Assert.Equal(UpdateStatus.Pending, vm.Packages.Single().Status);
        vm.UpdateSelectedCommand.Execute(null); await Idle(vm);
        Assert.Equal(1, calls); Assert.Equal(1, vm.UpdateSummary!.Updated);
    }

    [Fact]
    public async Task IncompleteIdentityCannotBeInstalled()
    {
        var vm = Vm(new StubSource(SourceId.Winget, new([new("Example", "Example", "1", "2", HasExactIdentity: false)], []),
            _ => throw new Exception("Must not run")));
        vm.ScanOrCancelCommand.Execute(null); await Idle(vm);
        Assert.False(vm.Packages.Single().IsActionable); Assert.False(vm.CanUpdate);
    }

    [Fact]
    public async Task IgnoredPackagesRetainDetectedCountAndAccurateSummary()
    {
        var settings = new MemorySettings(); settings.SetUpdateIgnored("Npm:example", true);
        var vm = new MainViewModel([new StubSource(SourceId.Npm, new([new("example", "Example", "1", "2")], []))],
            settings, new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null); await Idle(vm);
        Assert.Equal(1, vm.DetectedCount); Assert.Equal(1, vm.IgnoredCount); Assert.Equal(0, vm.UpdateCount);
        Assert.Equal(ScanSummaryKind.IgnoredOnly, vm.ScanSummary);
        Assert.DoesNotContain("up to date", vm.StatusText, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task VerifyAgainDoesNotRunTheInstaller()
    {
        var vm = Vm(new StubSource(SourceId.Npm, new([new("example", "Example", "1", "2")], []),
            _ => throw new Exception("Must not install")));
        vm.ScanOrCancelCommand.Execute(null); await Idle(vm);
        vm.VerifyAgainCommand.Execute(vm.Packages.Single()); await Idle(vm);
        Assert.Equal(1, vm.UpdateSummary!.Verified);
        Assert.Equal(0, vm.UpdateSummary.Updated);
    }

    [Fact]
    public async Task CancellationCountsEveryQueuedPackageAndWaitsForCleanup()
    {
        var started = new TaskCompletionSource();
        var finished = new TaskCompletionSource();
        var source = new CancellableSource(started, finished);
        var vm = Vm(source);
        vm.ScanOrCancelCommand.Execute(null); await Idle(vm);
        vm.UpdateSelectedCommand.Execute(null);
        await started.Task.WaitAsync(TimeSpan.FromSeconds(3));
        await vm.CancelAndWaitAsync();
        Assert.True(finished.Task.IsCompleted); Assert.False(vm.IsBusy);
        Assert.Equal(1, vm.UpdateSummary!.Cancelled); Assert.Equal(2, vm.UpdateSummary.NotStarted);
        Assert.Equal(3, vm.HistoryEntries.Count);
    }

    [Fact]
    public void FailedElevatedRelaunchNeverStartsDirectly()
    {
        var direct = false; string? notice = null;
        UpdateApplier.RelaunchSafely("app.exe", true, _ => false, _ => direct = true, message => notice = message);
        Assert.False(direct); Assert.Contains("Open PackMan again", notice);
        UpdateApplier.RelaunchSafely("app.exe", false, _ => throw new Exception(), _ => direct = true);
        Assert.True(direct);
    }

    private static MainViewModel Vm(IPackageSource source) => new([source], new MemorySettings(), new StubSourceInstaller());
    private static async Task Idle(MainViewModel vm)
    {
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (vm.IsBusy) await Task.Delay(10, limit.Token);
    }

    private sealed class ExportRunner(string json) : IProcessRunner
    {
        public string? ExportPath { get; private set; }
        public async Task<ProcessResult> RunAsync(ProcessInvocation invocation, IProgress<ProcessOutputEvent>? output = null,
            CancellationToken cancellationToken = default)
        {
            ExportPath = invocation.Arguments.SkipWhile(a => a != "--output").Skip(1).First();
            await File.WriteAllTextAsync(ExportPath, json, cancellationToken);
            return new(0, "Exported", "");
        }
    }

    private sealed class CancellableSource(TaskCompletionSource started, TaskCompletionSource finished) : IPackageSource
    {
        public SourceDescriptor Descriptor { get; } = new(SourceId.Npm, "npm", ToolId.Npm, "stub", []);
        public Task<SourceProbe> ProbeAsync(CancellationToken cancellationToken = default) => Task.FromResult(SourceProbe.Available(Context));
        public Task<SourceScanReport> ScanAsync(ToolContext context, IProgress<SourcePhase>? progress = null,
            CancellationToken cancellationToken = default) => Task.FromResult(new SourceScanReport([
                new("a", "A", "1", "2"), new("b", "B", "1", "2"), new("c", "C", "1", "2")], []));
        public async Task<UpdateResult> UpdateAsync(UpdateRequest request, ToolContext context,
            IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
        {
            started.SetResult();
            try { await Task.Delay(10000, cancellationToken); return new(); }
            finally { await Task.Delay(30); finished.SetResult(); }
        }
        public Task<IReadOnlyDictionary<string, UpdateVerification>> VerifyAsync(IReadOnlyList<UpdateRequest> requests,
            ToolContext context, CancellationToken cancellationToken = default) => throw new Exception("Not installed");
    }
}
