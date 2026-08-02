using PackMan.Models;
using PackMan.Services;
using PackMan.ViewModels;

namespace PackMan.Tests;

public sealed class ViewModelTests
{
    [Fact]
    public async Task SuccessfulEmptyScanIsUpToDate()
    {
        var vm = new MainViewModel([new StubSource(SourceId.Npm, SourceScanReport.Empty)], new MemorySettings());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        Assert.Equal(ScanSummaryKind.UpToDate, vm.ScanSummary);
    }

    [Fact]
    public async Task PartialScanNeverReportsUpToDateAndKeepsUpdates()
    {
        var report = new SourceScanReport([new("ruff", "ruff", "1", "2")],
            [new(SourceIssueKind.Network, "offline")]);
        var vm = new MainViewModel([new StubSource(SourceId.Pipx, report)], new MemorySettings());
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
        var vm = new MainViewModel([new StubSource(SourceId.Npm, report)], new MemorySettings());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        vm.UpdateSelectedCommand.Execute(null);
        await WaitUntilIdle(vm);
        Assert.Empty(vm.Packages);
        Assert.Equal(1, vm.UpdateSummary?.Updated);
        Assert.Equal(ScanSummaryKind.UpdatesCompleted, vm.ScanSummary);
    }

    [Fact]
    public async Task FailedUpdateRemainsSelectedAndRetryable()
    {
        var report = new SourceScanReport([new("tool", "tool", "1", "2")], []);
        var source = new StubSource(SourceId.Npm, report,
            _ => throw new SourceException(SourceIssueKind.Command, "access denied", true));
        var vm = new MainViewModel([source], new MemorySettings());
        vm.ScanOrCancelCommand.Execute(null);
        await WaitUntilIdle(vm);
        vm.UpdateSelectedCommand.Execute(null);
        await WaitUntilIdle(vm);
        var package = Assert.Single(vm.Packages);
        Assert.Equal(UpdateStatus.Failed, package.Status);
        Assert.True(package.IsSelected);
        Assert.True(package.CanRetryElevated);
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
