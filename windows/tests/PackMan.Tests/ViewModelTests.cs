using PackMan.Models;
using PackMan.Services;
using PackMan.ViewModels;

namespace PackMan.Tests;

public sealed class ViewModelTests
{
    [Fact]
    public async Task SuccessfulEmptyScanIsUpToDate()
    {
        var vm = new MainViewModel([new StubSource(SourceId.Npm, SourceScanReport.Empty)], new MemorySettings(), new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        Assert.Equal(ScanSummaryKind.UpToDate, vm.ScanSummary);
    }

    [Fact]
    public async Task PartialScanNeverReportsUpToDateAndKeepsUpdates()
    {
        var report = new SourceScanReport([new("ruff", "ruff", "1", "2")],
            [new(SourceIssueKind.Network, "offline")]);
        var vm = new MainViewModel([new StubSource(SourceId.Pipx, report)], new MemorySettings(), new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        Assert.Equal(ScanSummaryKind.CompletedWithIssues, vm.ScanSummary);
        Assert.Single(vm.Packages);
        Assert.DoesNotContain("up to date", vm.StatusText, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task VerifiedUpdateIsRemovedAndSummarized()
    {
        var report = new SourceScanReport([new("tool", "tool", "1", "2")], []);
        var vm = new MainViewModel([new StubSource(SourceId.Npm, report)], new MemorySettings(), new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        vm.UpdateSelectedCommand.Execute(null);
        await WaitUntilIdle(vm);
        Assert.Empty(vm.Packages);
        Assert.Equal(1, vm.UpdateSummary?.Updated);
        Assert.Equal(ScanSummaryKind.UpdatesCompleted, vm.ScanSummary);
    }

    [Fact]
    public async Task FailedUpdateRemainsSelected()
    {
        var report = new SourceScanReport([new("tool", "tool", "1", "2")], []);
        var source = new StubSource(SourceId.Npm, report,
            _ => throw new SourceException(SourceIssueKind.Command, "access denied", true));
        var vm = new MainViewModel([source], new MemorySettings(), new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        vm.UpdateSelectedCommand.Execute(null);
        await WaitUntilIdle(vm);
        var package = Assert.Single(vm.Packages);
        Assert.Equal(UpdateStatus.Failed, package.Status);
        Assert.True(package.IsSelected);
        Assert.Contains(vm.LogEntries, entry =>
            entry.Message.Contains("Retrying with administrator approval", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task ManualElevatedRetrySucceeds()
    {
        var attempts = new List<bool>();
        var report = new SourceScanReport([new("tool", "tool", "1", "2")], []);
        var source = new StubSource(SourceId.Npm, report, request =>
        {
            attempts.Add(request.Elevated);
            return request.Elevated
                ? Task.CompletedTask
                : Task.FromException(new SourceException(SourceIssueKind.Command, "plain failure", false));
        });
        var vm = new MainViewModel([source], new MemorySettings(), new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        vm.UpdateSelectedCommand.Execute(null);
        await WaitUntilIdle(vm);
        Assert.Equal([false], attempts);
        var package = Assert.Single(vm.Packages);
        Assert.Equal(UpdateStatus.Failed, package.Status);

        vm.RetryElevatedCommand.Execute(package);
        await WaitUntilIdle(vm);

        Assert.Equal([false, true], attempts);
        Assert.Empty(vm.Packages);
        Assert.Equal(1, vm.UpdateSummary?.Updated);
    }

    [Fact]
    public async Task InstallerCancellationDoesNotStopRemainingUpdates()
    {
        var attempted = new List<string>();
        var report = new SourceScanReport([
            new("cancelled", "cancelled", "1", "2"),
            new("successful", "successful", "1", "2")], []);
        var source = new StubSource(SourceId.Winget, report, request =>
        {
            attempted.Add(request.PackageId);
            return request.PackageId == "cancelled"
                ? Task.FromException(new PackageUpdateCanceledException("The installer was cancelled by the user."))
                : Task.CompletedTask;
        });
        var vm = new MainViewModel([source], new MemorySettings(), new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);

        vm.UpdateSelectedCommand.Execute(null);
        await WaitUntilIdle(vm);

        Assert.Equal(["cancelled", "successful"], attempted);
        var package = Assert.Single(vm.Packages);
        Assert.Equal("cancelled", package.PackageId);
        Assert.Equal(UpdateStatus.Cancelled, package.Status);
        Assert.Equal(1, vm.UpdateSummary?.Updated);
        Assert.Equal(1, vm.UpdateSummary?.Cancelled);
    }

    [Fact]
    public async Task SecondScanUsesCachedProbeContext()
    {
        var probes = 0;
        var source = new StubSource(SourceId.Npm, SourceScanReport.Empty,
            probe: () =>
            {
                probes++;
                return Task.FromResult(SourceProbe.Available(new ToolContext("stub", "1", ToolResolutionOrigin.Custom, [])));
            });
        var vm = new MainViewModel([source], new MemorySettings(), new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        Assert.Equal(1, probes);
    }

    [Fact]
    public async Task IgnoredUpdatesStayHiddenUntilRuleRemoved()
    {
        var report = new SourceScanReport([new("a", "a", "1", "2"), new("b", "b", "1", "2")], []);
        var settings = new MemorySettings();
        var vm = new MainViewModel([new StubSource(SourceId.Npm, report)], settings, new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        Assert.Equal(2, vm.Packages.Count);
        vm.IgnorePackageCommand.Execute(vm.Packages.First(p => p.PackageId == "a"));
        Assert.Single(vm.Packages);
        Assert.True(vm.HasIgnoredUpdates);
        Assert.Contains("Npm:a", settings.GetIgnoredUpdates());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        Assert.Single(vm.Packages);
        vm.RemoveIgnoredCommand.Execute("Npm:a");
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        Assert.Equal(2, vm.Packages.Count);
    }

    [Fact]
    public async Task IgnoredVersionHidesOnlyThatVersion()
    {
        var report = new SourceScanReport([new("a", "a", "1", "2")], []);
        var vm = new MainViewModel([new StubSource(SourceId.Npm, report)], new MemorySettings(), new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        vm.IgnoreUpdateVersionCommand.Execute(vm.Packages.Single());
        Assert.Empty(vm.Packages);
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        Assert.Empty(vm.Packages);
    }

    [Fact]
    public async Task ElevationFailureRetriesOnceElevatedAndSucceeds()
    {
        var attempts = new List<bool>();
        var report = new SourceScanReport([new("tool", "tool", "1", "2")], []);
        var source = new StubSource(SourceId.Winget, report, request =>
        {
            attempts.Add(request.Elevated);
            return request.Elevated
                ? Task.CompletedTask
                : Task.FromException(new SourceException(SourceIssueKind.Command, "access denied", true));
        });
        var vm = new MainViewModel([source], new MemorySettings(), new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);

        vm.UpdateSelectedCommand.Execute(null);
        await WaitUntilIdle(vm);

        Assert.Equal([false, true], attempts);
        Assert.Empty(vm.Packages);
        Assert.Equal(1, vm.UpdateSummary?.Updated);
        Assert.Contains(vm.LogEntries, entry =>
            entry.Message.Contains("Retrying with administrator approval", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task NonRetryableFailureDoesNotRetryElevated()
    {
        var attempts = 0;
        var report = new SourceScanReport([new("tool", "tool", "1", "2")], []);
        var source = new StubSource(SourceId.Winget, report, _ =>
        {
            attempts++;
            return Task.FromException(new SourceException(SourceIssueKind.Configuration,
                "different install technology", false));
        });
        var vm = new MainViewModel([source], new MemorySettings(), new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);

        vm.UpdateSelectedCommand.Execute(null);
        await WaitUntilIdle(vm);

        Assert.Equal(1, attempts);
        var package = Assert.Single(vm.Packages);
        Assert.Equal(UpdateStatus.Failed, package.Status);
        Assert.False(package.CanRetryElevated);
    }

    [Fact]
    public async Task DeclinedElevationMarksPackageCancelledWithoutRetry()
    {
        var attempts = 0;
        var report = new SourceScanReport([new("tool", "tool", "1", "2")], []);
        var source = new StubSource(SourceId.Chocolatey, report, _ =>
        {
            attempts++;
            return Task.FromException(new ElevationDeclinedException());
        });
        var vm = new MainViewModel([source], new MemorySettings(), new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);

        vm.UpdateSelectedCommand.Execute(null);
        await WaitUntilIdle(vm);

        Assert.Equal(1, attempts);
        var package = Assert.Single(vm.Packages);
        Assert.Equal(UpdateStatus.Cancelled, package.Status);
        Assert.Equal(1, vm.UpdateSummary?.Cancelled);
        Assert.Contains(vm.LogEntries, entry =>
            entry.Message.Contains("declined", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task RepeatedlyFailingElevationStopsAfterOneRetry()
    {
        var attempts = 0;
        var report = new SourceScanReport([new("tool", "tool", "1", "2")], []);
        var source = new StubSource(SourceId.Winget, report, _ =>
        {
            attempts++;
            return Task.FromException(new SourceException(SourceIssueKind.Command, "access denied", true));
        });
        var vm = new MainViewModel([source], new MemorySettings(), new StubSourceInstaller());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);

        vm.UpdateSelectedCommand.Execute(null);
        await WaitUntilIdle(vm);

        Assert.Equal(2, attempts);
        var package = Assert.Single(vm.Packages);
        Assert.Equal(UpdateStatus.Failed, package.Status);
        // Elevation was already attempted, so the manual administrator hint must not be offered.
        Assert.False(package.CanRetryElevated);
        Assert.DoesNotContain(vm.LogEntries, entry =>
            entry.Message.Contains("Retry as administrator", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task InstallSourceRunsPlanAndRescans()
    {
        var probes = 0;
        var report = new SourceScanReport([new("tool", "tool", "1", "2")], []);
        var source = new StubSource(SourceId.Pipx, report, probe: () =>
        {
            probes++;
            return Task.FromResult(probes < 2
                ? SourceProbe.Unavailable(new SourceIssue(SourceIssueKind.Unavailable, "pipx was not found."))
                : SourceProbe.Available(new ToolContext("pipx.exe", "1.7", ToolResolutionOrigin.Path, [])));
        });
        var plan = new SourceInstallPlan("pipx", "summary", false,
            [new ProcessInvocation("cmd.exe", ["/d", "/c", "echo ok"])]);
        var installer = new StubSourceInstaller(_ => plan);
        var vm = new MainViewModel([source], new MemorySettings(), installer)
        {
            ConfirmInstall = _ => true,
        };
        var option = vm.SourceOptions.Single();
        option.State.Set(SourceScanStatus.Unavailable);
        option.Refresh();

        vm.InstallSourceCommand.Execute(option);
        await WaitUntilIdle(vm);

        Assert.Same(plan, Assert.Single(installer.Installed));
        Assert.Equal(2, probes);
        Assert.Equal(SourceScanStatus.Succeeded, option.State.Status);
        Assert.Single(vm.Packages);
        Assert.Equal(ScanSummaryKind.UpdatesAvailable, vm.ScanSummary);
    }

    [Fact]
    public async Task InstallSkippedWhenManagerAppearedMeanwhile()
    {
        var probes = 0;
        var source = new StubSource(SourceId.Pipx, SourceScanReport.Empty, probe: () =>
        {
            probes++;
            return Task.FromResult(SourceProbe.Available(new ToolContext("pipx.exe", "1.7",
                ToolResolutionOrigin.Path, [])));
        });
        var plan = new SourceInstallPlan("pipx", "summary", false,
            [new ProcessInvocation("cmd.exe", ["/d", "/c", "echo ok"])]);
        var installer = new StubSourceInstaller(_ => plan);
        var vm = new MainViewModel([source], new MemorySettings(), installer)
        {
            ConfirmInstall = _ => true,
        };
        var option = vm.SourceOptions.Single();
        option.State.Set(SourceScanStatus.Unavailable);
        option.Refresh();

        vm.InstallSourceCommand.Execute(option);
        await WaitUntilIdle(vm);

        Assert.Empty(installer.Installed);
        Assert.Equal(1, probes);
        Assert.Contains(vm.LogEntries, entry =>
            entry.Message.Contains("already installed", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task InstallDeclinedByUserDoesNotRun()
    {
        var source = new StubSource(SourceId.Chocolatey, SourceScanReport.Empty);
        var plan = new SourceInstallPlan("Chocolatey", "summary", true,
            [new ProcessInvocation("powershell.exe", ["-NoProfile"])]);
        var installer = new StubSourceInstaller(_ => plan);
        var vm = new MainViewModel([source], new MemorySettings(), installer)
        {
            ConfirmInstall = _ => false,
        };
        var option = vm.SourceOptions.Single();
        option.State.Set(SourceScanStatus.Unavailable);
        option.Refresh();

        vm.InstallSourceCommand.Execute(option);
        await WaitUntilIdle(vm);

        Assert.Empty(installer.Installed);
    }

    [Fact]
    public async Task DeclinedElevationDuringInstallRestoresUnavailableState()
    {
        var source = new StubSource(SourceId.Chocolatey, SourceScanReport.Empty,
            probe: () => Task.FromResult(
                SourceProbe.Unavailable(new SourceIssue(SourceIssueKind.Unavailable, "choco was not found."))));
        var plan = new SourceInstallPlan("Chocolatey", "summary", true,
            [new ProcessInvocation("powershell.exe", ["-NoProfile"])]);
        var installer = new StubSourceInstaller(_ => plan,
            _ => Task.FromException(new ElevationDeclinedException()));
        var vm = new MainViewModel([source], new MemorySettings(), installer)
        {
            ConfirmInstall = _ => true,
        };
        var option = vm.SourceOptions.Single();
        option.State.Set(SourceScanStatus.Unavailable);
        option.Refresh();

        vm.InstallSourceCommand.Execute(option);
        await WaitUntilIdle(vm);

        Assert.Equal(SourceScanStatus.Unavailable, option.State.Status);
        Assert.Contains(vm.LogEntries, entry =>
            entry.Message.Contains("declined", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task ClearCacheRunsEverySupportedSourceAndContinuesAfterFailure()
    {
        var cleared = new List<SourceId>();
        var npm = new StubSource(SourceId.Npm, SourceScanReport.Empty,
            clearCache: _ =>
            {
                cleared.Add(SourceId.Npm);
                return Task.FromResult("npm cleared");
            });
        var pip = new StubSource(SourceId.Pip, SourceScanReport.Empty,
            clearCache: _ =>
            {
                cleared.Add(SourceId.Pip);
                return Task.FromException<string>(new SourceException(SourceIssueKind.Command, "pip failed"));
            });
        var unsupported = new StubSource(SourceId.Pipx, SourceScanReport.Empty);
        var vm = new MainViewModel([npm, pip, unsupported], new MemorySettings(), new StubSourceInstaller())
        {
            ConfirmCacheClear = _ => true,
        };

        vm.ClearCacheCommand.Execute(null);
        await WaitUntilIdle(vm);

        Assert.Equal([SourceId.Npm, SourceId.Pip], cleared);
        Assert.Contains("failed 1", vm.CacheCleanupStatus, StringComparison.OrdinalIgnoreCase);
        Assert.Contains(vm.LogEntries, entry =>
            entry.Scope == SourceId.Npm.ToString() && entry.Level == LogLevel.Success);
        Assert.Contains(vm.LogEntries, entry =>
            entry.Scope == SourceId.Pip.ToString() && entry.Level == LogLevel.Error);
    }

    [Fact]
    public async Task ClearCacheHonorsConfirmation()
    {
        var attempts = 0;
        var source = new StubSource(SourceId.Npm, SourceScanReport.Empty,
            clearCache: _ =>
            {
                attempts++;
                return Task.FromResult("cleared");
            });
        var vm = new MainViewModel([source], new MemorySettings(), new StubSourceInstaller())
        {
            ConfirmCacheClear = _ => false,
        };

        vm.ClearCacheCommand.Execute(null);
        await WaitUntilIdle(vm);

        Assert.Equal(0, attempts);
        Assert.Null(vm.CacheCleanupStatus);
    }

    private static async Task WaitUntilIdle(MainViewModel vm)
    {
        var deadline = DateTime.UtcNow.AddSeconds(3);
        do
        {
            if (!vm.IsBusy) return;
            await Task.Delay(10);
        } while (DateTime.UtcNow < deadline);
        throw new TimeoutException("View model did not become idle.");
    }
}
