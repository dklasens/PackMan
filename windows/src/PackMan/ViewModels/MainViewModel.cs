using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;
using System.Windows.Data;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using PackMan.Models;
using PackMan.Services;

namespace PackMan.ViewModels;

public partial class MainViewModel : ObservableObject
{
    private readonly IReadOnlyList<IPackageSource> _sources;
    private readonly ISettingsService _settings;
    private readonly ISourceInstaller _installer;
    private CancellationTokenSource? _operationCts;
    private Task? _activeTask;
    private long _nextLogId;
    private readonly Dictionary<string, string> _lastOutput = [];

    public MainViewModel(IEnumerable<IPackageSource> sources, ISettingsService settings,
        ISourceInstaller installer)
    {
        _sources = sources.ToList();
        _settings = settings;
        _installer = installer;
        SourceOptions = new(_sources.Select(source => new SourceOptionViewModel(
            source, settings.IsSourceEnabled(source.Id), settings.GetExecutableOverride(source.Descriptor.ToolId),
            installer.HasPlan(source.Id))));
        foreach (var option in SourceOptions) option.PropertyChanged += OnSourceOptionChanged;
        PackagesView = CollectionViewSource.GetDefaultView(Packages);
        PackagesView.SortDescriptions.Add(new SortDescription(nameof(PackageUpdate.Source), ListSortDirection.Ascending));
        PackagesView.SortDescriptions.Add(new SortDescription(nameof(PackageUpdate.Name), ListSortDirection.Ascending));
        if (settings.LoadIssue is { } issue) AppendLog(issue, LogLevel.Warning);
    }

    public ObservableCollection<PackageUpdate> Packages { get; } = [];
    public ICollectionView PackagesView { get; }
    public ObservableCollection<LogEntry> LogEntries { get; } = [];
    public ObservableCollection<SourceOptionViewModel> SourceOptions { get; }
    public ObservableCollection<string> IgnoredUpdates { get; } = [];
    public bool HasIgnoredUpdates => IgnoredUpdates.Count > 0;

    [ObservableProperty] private AppOperationKind _operation = AppOperationKind.Idle;
    [ObservableProperty] private ScanSummaryKind _scanSummary = ScanSummaryKind.NotStarted;
    [ObservableProperty] private UpdateRunSummary? _updateSummary;
    [ObservableProperty] private bool _isLogVisible;
    [ObservableProperty] private int _operationCompleted;
    [ObservableProperty] private int _operationTotal;
    [ObservableProperty] private string? _currentItem;
    [ObservableProperty] private DateTimeOffset? _lastScanCompletedAt;
    [ObservableProperty] private string? _cacheCleanupStatus;

    public bool IsBusy => Operation != AppOperationKind.Idle;
    public int UpdateCount => Packages.Count(p => p.IsActionable);
    public int SelectedCount => Packages.Count(p => p.IsActionable && p.IsSelected);
    public bool CanUpdate => !IsBusy && SelectedCount > 0;
    public bool HasPackages => Packages.Count > 0;
    public bool HasSourceIssues => SourceOptions.Any(o => o.HasIssue);
    public int SourceIssueCount => SourceOptions.Count(o => o.HasIssue);
    public bool ShowIssueBanner => ScanSummary is ScanSummaryKind.CompletedWithIssues
        or ScanSummaryKind.AllUnavailable or ScanSummaryKind.Cancelled;
    public bool ShowSourceProgress => Operation is AppOperationKind.Scanning or AppOperationKind.Cancelling
        && SourceOptions.Any(o => o.State.Status is SourceScanStatus.Probing or SourceScanStatus.Scanning or SourceScanStatus.Waiting);
    public bool HasCacheCleanupStatus => !string.IsNullOrWhiteSpace(CacheCleanupStatus);
    public string ScanButtonText => IsBusy ? (Operation == AppOperationKind.Cancelling ? "Cancelling" : "Cancel") : "Scan";
    public string UpdateButtonText => SelectedCount > 0 ? $"Update {SelectedCount}" : "Update Selected";
    public string LogButtonText => IsLogVisible ? "Hide Log" : "Show Log";
    public static string VersionText =>
        typeof(MainViewModel).Assembly.GetName().Version is { } version
            ? $"v{version.Major}.{version.Minor}" + (version.Build > 0 ? $".{version.Build}" : string.Empty)
            : string.Empty;
    public string FooterText => $"{UpdateCount} update{(UpdateCount == 1 ? "" : "s")} • {SelectedCount} selected"
        + (LastScanCompletedAt is { } scannedAt ? $" • Last scan {scannedAt:HH:mm}" : string.Empty);
    public string StatusText => Operation == AppOperationKind.CleaningCache
        ? CacheCleanupStatus ?? "Clearing package caches…"
        : ScanSummary switch
        {
            ScanSummaryKind.NotStarted => "Ready. Scan enabled sources for updates.",
            ScanSummaryKind.Running => $"Scanning sources ({OperationCompleted}/{OperationTotal})…",
            ScanSummaryKind.UpdatesAvailable => $"{UpdateCount} update{(UpdateCount == 1 ? "" : "s")} available.",
            ScanSummaryKind.UpdatesCompleted => UpdateSummary is null ? "Updates completed." :
                $"Updated {UpdateSummary.Updated}; failed {UpdateSummary.Failed + UpdateSummary.VerificationFailed}.",
            ScanSummaryKind.UpToDate => "System is up to date. Every enabled source completed successfully.",
            ScanSummaryKind.CompletedWithIssues => $"Scan completed with issues; {UpdateCount} update{(UpdateCount == 1 ? "" : "s")} found.",
            ScanSummaryKind.AllUnavailable => "No enabled source could be scanned.",
            ScanSummaryKind.NoSources => "No sources selected.",
            ScanSummaryKind.Cancelled => "Scan cancelled. Completed source results were preserved.",
            _ => string.Empty,
        };
    public string EmptyTitle => ScanSummary switch
    {
        ScanSummaryKind.NotStarted => "Ready to Scan",
        ScanSummaryKind.Running => "Scanning Sources",
        ScanSummaryKind.UpdatesCompleted => "Updates Completed",
        ScanSummaryKind.UpToDate => "System is Up to Date",
        ScanSummaryKind.CompletedWithIssues => "Scan Completed with Issues",
        ScanSummaryKind.AllUnavailable => "No Sources Could Be Scanned",
        ScanSummaryKind.NoSources => "No Sources Selected",
        ScanSummaryKind.Cancelled => "Scan Cancelled",
        _ => "No Displayable Updates",
    };
    public string EmptyDescription => ScanSummary switch
    {
        ScanSummaryKind.NotStarted => "Check your enabled package managers for available updates.",
        ScanSummaryKind.Running => "Updates appear as each source completes.",
        ScanSummaryKind.UpdatesCompleted => "The selected packages were updated and verified.",
        ScanSummaryKind.UpToDate => "Every enabled source completed successfully.",
        ScanSummaryKind.CompletedWithIssues => "Some sources could not be checked, so these results may be incomplete.",
        ScanSummaryKind.AllUnavailable => "Open Sources to review executable paths and installation guidance.",
        ScanSummaryKind.NoSources => "Enable at least one package manager in Sources.",
        ScanSummaryKind.Cancelled => "Completed source results were preserved; this is not a full system check.",
        _ => string.Empty,
    };

    [RelayCommand]
    private void ScanOrCancel()
    {
        if (IsBusy)
        {
            if (Operation != AppOperationKind.Cancelling)
            {
                Operation = AppOperationKind.Cancelling;
                AppendLog("Cancellation requested…", LogLevel.Warning);
                _operationCts?.Cancel();
            }
            return;
        }
        StartOperation(ct => RunScanAsync(SourceOptions.Where(o => o.IsEnabled).Select(o => o.Id).ToHashSet(), true, ct));
    }

    [RelayCommand]
    private void RetryIssues()
    {
        if (IsBusy) return;
        var ids = SourceOptions.Where(o => o.HasIssue).Select(o => o.Id).ToHashSet();
        if (ids.Count > 0) StartOperation(ct => RunScanAsync(ids, false, ct));
    }

    [RelayCommand(CanExecute = nameof(CanUpdate))]
    private void UpdateSelected() => StartUpdates(Packages.Where(p => p.IsActionable && p.IsSelected).Select(p => (p, false)).ToList());

    [RelayCommand]
    private void UpdateSingle(PackageUpdate? package)
    {
        if (!IsBusy && package?.IsActionable == true) StartUpdates([(package, false)]);
    }

    [RelayCommand]
    private void RetryElevated(PackageUpdate? package)
    {
        if (!IsBusy && package?.IsActionable == true) StartUpdates([(package, true)]);
    }

    [RelayCommand] private void SelectAll() { foreach (var package in Packages.Where(p => p.IsActionable)) package.IsSelected = true; RefreshComputed(); }
    [RelayCommand] private void SelectNone() { foreach (var package in Packages) package.IsSelected = false; RefreshComputed(); }
    [RelayCommand] private void ToggleLog() => IsLogVisible = !IsLogVisible;
    [RelayCommand] private void ClearLog() => LogEntries.Clear();
    [RelayCommand]
    private void CopyPackageId(PackageUpdate? package)
    {
        if (package is not null) Clipboard.SetText(package.PackageId);
    }

    [RelayCommand]
    private void IgnoreUpdateVersion(PackageUpdate? package) => Ignore(package, versioned: true);

    [RelayCommand]
    private void IgnorePackage(PackageUpdate? package) => Ignore(package, versioned: false);

    [RelayCommand]
    private void RemoveIgnored(string? key)
    {
        if (string.IsNullOrWhiteSpace(key)) return;
        try
        {
            _settings.SetUpdateIgnored(key, false);
            IgnoredUpdates.Remove(key);
            OnPropertyChanged(nameof(HasIgnoredUpdates));
        }
        catch (Exception ex) { AppendLog($"Could not update ignore rules: {ex.Message}", LogLevel.Error); }
    }

    private void Ignore(PackageUpdate? package, bool versioned)
    {
        if (package is null || IsBusy) return;
        var key = versioned
            ? $"{package.SourceId}:{package.PackageId}@{package.AvailableVersion}"
            : $"{package.SourceId}:{package.PackageId}";
        try
        {
            _settings.SetUpdateIgnored(key, true);
            IgnoredUpdates.Add(key);
            package.PropertyChanged -= OnPackageChanged;
            Packages.Remove(package);
            PackagesView.Refresh();
            OnPropertyChanged(nameof(HasIgnoredUpdates));
            AppendLog($"Ignored {package.Name}{(versioned ? $" {package.AvailableVersion}" : "")}; it will stay hidden.");
        }
        catch (Exception ex) { AppendLog($"Could not update ignore rules: {ex.Message}", LogLevel.Error); }
        RefreshComputed();
    }

    public void ReloadIgnored()
    {
        IgnoredUpdates.Clear();
        foreach (var key in _settings.GetIgnoredUpdates().OrderBy(k => k, StringComparer.OrdinalIgnoreCase))
            IgnoredUpdates.Add(key);
        OnPropertyChanged(nameof(HasIgnoredUpdates));
    }

    [RelayCommand]
    private void CopyLog()
    {
        if (LogEntries.Count > 0) Clipboard.SetText(string.Join(Environment.NewLine, LogEntries.Select(e => e.DisplayText)));
    }

    [RelayCommand]
    private void ChooseExecutable(SourceOptionViewModel? option)
    {
        if (option is null || IsBusy) return;
        var picker = new OpenFileDialog { Title = $"Choose {option.Descriptor.ExecutableName}", CheckFileExists = true };
        if (picker.ShowDialog() == true) SetExecutableOverride(option, picker.FileName);
    }

    [RelayCommand]
    private void UseAutomatic(SourceOptionViewModel? option)
    {
        if (option is not null && !IsBusy) SetExecutableOverride(option, null);
    }

    private void SetExecutableOverride(SourceOptionViewModel option, string? path)
    {
        try
        {
            _settings.SetExecutableOverride(option.Descriptor.ToolId, path);
            foreach (var related in SourceOptions.Where(o => o.Descriptor.ToolId == option.Descriptor.ToolId))
            {
                TrySetCachedContext(related.Id, null);
                related.ExecutableOverride = path;
                related.ToolContext = null;
                related.ProbeIssue = null;
                related.State.Set(related.IsEnabled ? SourceScanStatus.NotScanned : SourceScanStatus.Disabled);
                RemovePackages(related.Id);
                related.Refresh();
            }
        }
        catch (Exception ex) { AppendLog($"Could not save executable setting: {ex.Message}", LogLevel.Error); }
        RefreshComputed();
    }

    internal Func<string, bool> ConfirmInstall { get; set; } = message =>
        MessageBox.Show(message, "PackMan", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;
    internal Action<string> ShowInstallNotice { get; set; } = message =>
        MessageBox.Show(message, "PackMan", MessageBoxButton.OK, MessageBoxImage.Information);
    internal Func<string, bool> ConfirmCacheClear { get; set; } = message =>
        MessageBox.Show(message, "PackMan", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes;

    [RelayCommand]
    private async Task InstallSource(SourceOptionViewModel? option)
    {
        if (option is null || IsBusy) return;
        SourceInstallPlan? plan;
        try { plan = await _installer.BuildPlanAsync(option.Id); }
        catch (Exception ex)
        {
            AppendLog($"Could not prepare the {option.Name} installer: {ex.Message}", LogLevel.Error, option.Name);
            return;
        }
        if (plan is null)
        {
            var message = $"{option.Name} cannot be installed automatically because a prerequisite is missing. " +
                "Use Installation Help for manual steps.";
            AppendLog(message, LogLevel.Warning, option.Name);
            ShowInstallNotice(message);
            return;
        }
        var confirmation = $"{plan.Summary}\n\n" +
            (plan.RequiresElevation
                ? "Windows will ask for administrator approval."
                : "No administrator rights are needed.") +
            $"\n\nInstall {plan.Title}?";
        if (!ConfirmInstall(confirmation)) return;
        StartOperation(ct => RunInstallAsync(option, plan, ct));
    }

    private async Task RunInstallAsync(SourceOptionViewModel option, SourceInstallPlan plan,
        CancellationToken cancellationToken)
    {
        Operation = AppOperationKind.Installing;
        CurrentItem = option.Name;
        IsLogVisible = true;
        AppendLog($"Installing {plan.Title} — {plan.Summary}", scope: option.Name);
        option.State.Set(SourceScanStatus.Installing);
        option.Refresh();
        try
        {
            // The install is only offered for unavailable sources; re-probe right before running
            // so an installation completed outside PackMan in the meantime is never repeated.
            var existing = await option.Source.ProbeAsync(cancellationToken);
            if (existing.IsAvailable)
            {
                option.ToolContext = existing.Context;
                option.ProbeIssue = null;
                TrySetCachedContext(option.Id, existing.Context);
                AppendLog($"{option.Name} is already installed; nothing to do.", LogLevel.Info, option.Name);
            }
            else
            {
                var progress = new Progress<ProcessOutputEvent>(output =>
                {
                    var line = output.Line.Trim();
                    if (line.Length > 0) AppendLog(line, LogLevel.Output, option.Name, output.Stream);
                });
                await _installer.InstallAsync(plan, progress, cancellationToken);
                AppendLog($"{plan.Title} installer finished; verifying the installation…", LogLevel.Success, option.Name);
                TrySetCachedContext(option.Id, null);
                option.ToolContext = null;
                var verify = await option.Source.ProbeAsync(cancellationToken);
                if (!verify.IsAvailable)
                {
                    option.ProbeIssue = verify.Issue;
                    option.State.Set(SourceScanStatus.Unavailable,
                        issues: verify.Issue is null ? [] : [verify.Issue]);
                    AppendLog($"{option.Name} was installed but could not be found afterwards. " +
                        "A restart of PackMan may be required, or choose its executable in Sources.",
                        LogLevel.Warning, option.Name);
                    option.Refresh();
                    RefreshComputed();
                    return;
                }
                option.ToolContext = verify.Context;
                option.ProbeIssue = null;
                TrySetCachedContext(option.Id, verify.Context);
                AppendLog($"{option.Name} is installed ({verify.Context!.Version}).", LogLevel.Success, option.Name);
            }
        }
        catch (ElevationDeclinedException ex)
        {
            option.State.Set(SourceScanStatus.Unavailable, issues: option.ProbeIssue is null ? [] : [option.ProbeIssue]);
            option.Refresh();
            AppendLog(ex.Message, LogLevel.Warning, option.Name);
            RefreshComputed();
            return;
        }
        catch (OperationCanceledException)
        {
            option.State.Set(SourceScanStatus.Unavailable, issues: option.ProbeIssue is null ? [] : [option.ProbeIssue]);
            option.Refresh();
            AppendLog($"Installing {option.Name} was cancelled.", LogLevel.Warning, option.Name);
            RefreshComputed();
            return;
        }
        catch (Exception ex)
        {
            option.State.Set(SourceScanStatus.Unavailable, issues:
                [new SourceIssue(SourceIssueKind.Command, $"Installation failed: {ex.Message}",
                    "Open the log for details, or use Installation Help for manual steps.")]);
            option.Refresh();
            AppendLog($"Installing {option.Name} failed — {ex.Message}", LogLevel.Error, option.Name);
            RefreshComputed();
            return;
        }

        var outcome = await ScanOneAsync(option, cancellationToken);
        ApplyOutcome(outcome);
        if (ScanSummary is not (ScanSummaryKind.NotStarted or ScanSummaryKind.NoSources or ScanSummaryKind.Running))
            DeriveScanSummary();
        else if (UpdateCount > 0) ScanSummary = ScanSummaryKind.UpdatesAvailable;
        RefreshComputed();
    }

    [RelayCommand]
    private void ClearCache()
    {
        if (IsBusy) return;
        var sources = _sources.Where(source => source.SupportsCacheClear).ToList();
        if (sources.Count == 0)
        {
            CacheCleanupStatus = "No package-manager caches are available to clear.";
            return;
        }
        const string confirmation =
            "Clear downloaded installers and package caches for every available source?\n\n" +
            "Future installs may need to download these files again. Clearing the NuGet cache also means " +
            "projects may need to restore their packages again.";
        if (!ConfirmCacheClear(confirmation)) return;
        StartOperation(ct => RunCacheCleanupAsync(sources, ct));
    }

    private async Task RunCacheCleanupAsync(IReadOnlyList<IPackageSource> sources,
        CancellationToken cancellationToken)
    {
        Operation = AppOperationKind.CleaningCache;
        OperationCompleted = 0;
        OperationTotal = sources.Count;
        CacheCleanupStatus = $"Clearing caches (0/{sources.Count})…";
        AppendLog($"Clearing package caches for {sources.Count} source(s).");
        var cleared = 0;
        var skipped = 0;
        var failed = 0;

        foreach (var source in sources)
        {
            cancellationToken.ThrowIfCancellationRequested();
            CurrentItem = source.Name;
            CacheCleanupStatus = $"Clearing {source.Name} ({OperationCompleted + 1}/{OperationTotal})…";
            try
            {
                var option = SourceOptions.First(o => o.Id == source.Id);
                var context = option.ToolContext ?? _settings.GetCachedContext(source.Id);
                if (context is null)
                {
                    var probe = await source.ProbeAsync(cancellationToken);
                    if (!probe.IsAvailable)
                    {
                        skipped++;
                        AppendLog($"Cache cleanup skipped — {probe.Issue?.Message ?? "source is unavailable"}.",
                            LogLevel.Warning, source.Name);
                        continue;
                    }
                    context = probe.Context!;
                    option.ToolContext = context;
                    option.ProbeIssue = null;
                    TrySetCachedContext(option.Id, context);
                    option.Refresh();
                }

                var progress = new Progress<ProcessOutputEvent>(output =>
                {
                    var line = output.Line.Trim();
                    if (line.Length > 0) AppendLog(line, LogLevel.Output, source.Name, output.Stream);
                });
                var result = await source.ClearCacheAsync(context, progress, cancellationToken);
                cleared++;
                AppendLog(result, LogLevel.Success, source.Name);
            }
            catch (ElevationDeclinedException ex)
            {
                failed++;
                AppendLog(ex.Message, LogLevel.Warning, source.Name);
            }
            catch (OperationCanceledException)
            {
                CacheCleanupStatus = $"Cache cleanup cancelled after {cleared} source{(cleared == 1 ? "" : "s")}.";
                AppendLog(CacheCleanupStatus, LogLevel.Warning);
                return;
            }
            catch (Exception ex)
            {
                failed++;
                AppendLog($"Cache cleanup failed — {ex.Message}", LogLevel.Error, source.Name);
            }
            finally
            {
                OperationCompleted++;
            }
        }

        CacheCleanupStatus = failed > 0
            ? $"Cleared {cleared}; skipped {skipped}; failed {failed}. Open the main log for details."
            : $"Cache cleanup complete: {cleared} cleared" + (skipped > 0 ? $"; {skipped} unavailable" : string.Empty) + ".";
        AppendLog(CacheCleanupStatus, failed > 0 ? LogLevel.Warning : LogLevel.Success);
    }

    private void StartUpdates(IReadOnlyList<(PackageUpdate Package, bool Elevated)> packages)
    {
        if (IsBusy || packages.Count == 0) return;
        StartOperation(ct => RunUpdatesAsync(packages, ct));
    }

    private void StartOperation(Func<CancellationToken, Task> work)
    {
        if (_activeTask is not null) return;
        _operationCts = new CancellationTokenSource();
        _activeTask = Task.CompletedTask;
        var task = RunOwnedAsync(work, _operationCts.Token);
        _activeTask = task.IsCompleted ? null : task;
    }

    private async Task RunOwnedAsync(Func<CancellationToken, Task> work, CancellationToken cancellationToken)
    {
        try { await work(cancellationToken); }
        catch (Exception ex) when (ex is not OperationCanceledException) { AppendLog(ex.Message, LogLevel.Error); }
        finally
        {
            CurrentItem = null;
            _operationCts?.Dispose();
            _operationCts = null;
            _activeTask = null;
            Operation = AppOperationKind.Idle;
            RefreshComputed();
        }
    }

    private async Task RunScanAsync(HashSet<SourceId> ids, bool fresh, CancellationToken cancellationToken)
    {
        var options = SourceOptions.Where(o => ids.Contains(o.Id) && o.IsEnabled).ToList();
        if (options.Count == 0) { ScanSummary = ScanSummaryKind.NoSources; RefreshComputed(); return; }
        Operation = AppOperationKind.Scanning;
        ScanSummary = ScanSummaryKind.Running;
        OperationCompleted = 0;
        OperationTotal = options.Count;
        UpdateSummary = null;
        if (fresh)
        {
            Packages.Clear();
            foreach (var option in SourceOptions)
            {
                option.State.Set(option.IsEnabled ? SourceScanStatus.Waiting : SourceScanStatus.Disabled);
                option.ToolContext = null;
                option.ProbeIssue = null;
                option.Refresh();
            }
        }
        else
        {
            foreach (var option in options) { option.State.Set(SourceScanStatus.Waiting); option.Refresh(); }
        }
        AppendLog(fresh ? $"Scan started ({string.Join(", ", options.Select(o => o.Name))})."
            : $"Retrying sources with issues ({string.Join(", ", options.Select(o => o.Name))}).");

        var pending = options.Select(option => ScanOneAsync(option, cancellationToken)).ToList();
        var cancelled = false;
        while (pending.Count > 0)
        {
            var completedTask = await Task.WhenAny(pending);
            pending.Remove(completedTask);
            var outcome = await completedTask;
            ApplyOutcome(outcome);
            OperationCompleted++;
            cancelled |= outcome.Kind == OutcomeKind.Cancelled;
            if (Operation != AppOperationKind.Cancelling) Operation = AppOperationKind.Scanning;
            RefreshComputed();
        }
        if (cancelled || cancellationToken.IsCancellationRequested)
        {
            ScanSummary = ScanSummaryKind.Cancelled;
            AppendLog("Scan cancelled. Completed source results were preserved.", LogLevel.Warning);
        }
        else DeriveScanSummary();
        LastScanCompletedAt = DateTimeOffset.Now;
    }

    private async Task<SourceOutcome> ScanOneAsync(SourceOptionViewModel option, CancellationToken cancellationToken)
    {
        option.State.Set(SourceScanStatus.Probing, SourcePhase.Probing); option.Refresh();
        var progress = new Progress<SourcePhase>(phase => { option.State.Set(SourceScanStatus.Scanning, phase); option.Refresh(); });
        var cached = option.ToolContext ?? _settings.GetCachedContext(option.Id);
        if (cached is not null)
        {
            option.ToolContext = cached;
            option.ProbeIssue = null;
            option.State.Set(SourceScanStatus.Scanning, SourcePhase.Scanning); option.Refresh();
            try
            {
                return new(option, OutcomeKind.Report, await option.Source.ScanAsync(cached, progress, cancellationToken));
            }
            catch (OperationCanceledException) { return new(option, OutcomeKind.Cancelled); }
            catch
            {
                TrySetCachedContext(option.Id, null);
                option.ToolContext = null;
            }
        }
        try
        {
            var probe = await option.Source.ProbeAsync(cancellationToken);
            if (!probe.IsAvailable) return new(option, OutcomeKind.Unavailable, Issue: probe.Issue);
            option.ToolContext = probe.Context;
            option.ProbeIssue = null;
            option.State.Set(SourceScanStatus.Scanning, SourcePhase.Scanning); option.Refresh();
            var report = await option.Source.ScanAsync(probe.Context!, progress, cancellationToken);
            TrySetCachedContext(option.Id, probe.Context);
            return new(option, OutcomeKind.Report, report);
        }
        catch (OperationCanceledException) { return new(option, OutcomeKind.Cancelled); }
        catch (Exception ex)
        {
            var kind = ex is SourceException source ? source.Kind : SourceIssueKind.Command;
            return new(option, OutcomeKind.Failed, Issue: new(kind, ex.Message, "Open the log for details and retry."));
        }
    }

    private void TrySetCachedContext(SourceId id, ToolContext? context)
    {
        try { _settings.SetCachedContext(id, context); }
        catch (Exception ex) { AppendLog($"Could not save tool cache: {ex.Message}", LogLevel.Warning); }
    }

    private void ApplyOutcome(SourceOutcome outcome)
    {
        var option = outcome.Option;
        switch (outcome.Kind)
        {
            case OutcomeKind.Report:
                var report = outcome.Report!;
                var hidden = ReplacePackages(option, report.Updates);
                var visible = report.Updates.Count - hidden;
                option.State.Set(report.Issues.Count == 0 ? SourceScanStatus.Succeeded : SourceScanStatus.Partial,
                    updateCount: visible, issues: report.Issues);
                AppendLog($"{option.Name}: {(report.Issues.Count == 0 ? "" : "partial • ")}{visible} update(s)"
                    + (hidden > 0 ? $", {hidden} hidden by ignore rules" : string.Empty) + ".",
                    report.Issues.Count == 0 ? LogLevel.Info : LogLevel.Warning);
                foreach (var issue in report.Issues) AppendLog(issue.Message, LogLevel.Warning, option.Name);
                break;
            case OutcomeKind.Unavailable:
                option.ProbeIssue = outcome.Issue;
                option.State.Set(SourceScanStatus.Unavailable, issues: outcome.Issue is null ? [] : [outcome.Issue]);
                AppendLog($"{option.Name}: unavailable — {outcome.Issue?.Message}", LogLevel.Warning);
                break;
            case OutcomeKind.Failed:
                option.State.Set(SourceScanStatus.Failed, issues: outcome.Issue is null ? [] : [outcome.Issue]);
                AppendLog($"{option.Name}: scan failed — {outcome.Issue?.Message}", LogLevel.Error);
                IsLogVisible = true;
                break;
            case OutcomeKind.Cancelled:
                option.State.Set(SourceScanStatus.Cancelled);
                AppendLog($"{option.Name}: cancelled.", LogLevel.Warning);
                break;
        }
        option.Refresh();
    }

    private void DeriveScanSummary()
    {
        var enabled = SourceOptions.Where(o => o.IsEnabled).ToList();
        if (enabled.Count == 0) ScanSummary = ScanSummaryKind.NoSources;
        else if (enabled.All(o => o.State.Status == SourceScanStatus.Unavailable)) ScanSummary = ScanSummaryKind.AllUnavailable;
        else if (enabled.Any(o => o.State.HasIssue)) ScanSummary = ScanSummaryKind.CompletedWithIssues;
        else ScanSummary = UpdateCount == 0 ? ScanSummaryKind.UpToDate : ScanSummaryKind.UpdatesAvailable;
        AppendLog($"Scan complete. {UpdateCount} update(s) found.", HasSourceIssues ? LogLevel.Warning : LogLevel.Info);
        RefreshComputed();
    }

    private async Task RunUpdatesAsync(IReadOnlyList<(PackageUpdate Package, bool Elevated)> selected,
        CancellationToken cancellationToken)
    {
        Operation = AppOperationKind.Updating;
        OperationCompleted = 0;
        OperationTotal = selected.Count;
        IsLogVisible = true;
        AppendLog($"Updating {selected.Count} selected package(s).");
        var updated = 0; var failed = 0; var cancelled = 0; var verificationFailed = 0;
        var batches = new List<VerificationBatch>();
        foreach (var group in selected.GroupBy(item => item.Package.SourceId))
        {
            var items = new List<(PackageUpdate Package, UpdateRequest Request)>();
            foreach (var item in group)
            {
                var package = item.Package;
                if (cancellationToken.IsCancellationRequested) { cancelled++; break; }
                CurrentItem = package.Name;
                var request = package.ToRequest(item.Elevated);
                if (package.NeedsVerificationOnly)
                {
                    package.Status = UpdateStatus.Verifying;
                    items.Add((package, request));
                    continue;
                }
                package.Status = UpdateStatus.Updating;
                package.StatusMessage = null;
                package.CanRetryElevated = false;
                var progress = new Progress<ProcessOutputEvent>(output => AppendOutput(package, output));
                try
                {
                    await UpdateWithElevationRetryAsync(package, request, progress, cancellationToken);
                    package.Status = UpdateStatus.Verifying;
                    items.Add((package, request));
                }
                catch (PackageUpdateCanceledException ex)
                {
                    package.Status = UpdateStatus.Cancelled;
                    package.FailureKind = UpdateFailureKind.Update;
                    package.StatusMessage = ex.Message;
                    package.IsSelected = true;
                    cancelled++;
                    OperationCompleted++;
                    AppendLog($"Update cancelled — {ex.Message}", LogLevel.Warning, package.Name);
                }
                catch (ElevationDeclinedException ex)
                {
                    package.Status = UpdateStatus.Cancelled;
                    package.FailureKind = UpdateFailureKind.Update;
                    package.StatusMessage = ex.Message;
                    package.IsSelected = true;
                    cancelled++;
                    OperationCompleted++;
                    AppendLog(ex.Message, LogLevel.Warning, package.Name);
                }
                catch (OperationCanceledException)
                {
                    package.Status = UpdateStatus.Cancelled; package.IsSelected = true; cancelled++; break;
                }
                catch (Exception ex)
                {
                    package.Status = UpdateStatus.Failed;
                    package.FailureKind = UpdateFailureKind.Update;
                    package.StatusMessage = ex.Message;
                    package.CanRetryElevated = ex is SourceException { CanRetryElevated: true };
                    package.IsSelected = true;
                    failed++;
                    OperationCompleted++;
                    AppendLog($"Update failed — {ex.Message}", LogLevel.Error, package.Name);
                    if (package.CanRetryElevated)
                        AppendLog("Retry as administrator is available for this package.",
                            LogLevel.Warning, package.Name);
                }
            }
            if (items.Count > 0) batches.Add(new(items[0].Package.SourceRef, items[0].Package.ToolContext, items));
            if (cancellationToken.IsCancellationRequested) break;
        }

        var outcomes = await Task.WhenAll(batches.Select(async batch =>
        {
            try
            {
                var results = await batch.Source.VerifyAsync(batch.Items.Select(i => i.Request).ToList(),
                    batch.Context, cancellationToken);
                return new VerificationOutcome(batch, results, null, false);
            }
            catch (OperationCanceledException) { return new VerificationOutcome(batch, null, null, true); }
            catch (Exception ex) { return new VerificationOutcome(batch, null, ex, false); }
        }));

        foreach (var outcome in outcomes)
        {
            foreach (var (package, _) in outcome.Batch.Items)
            {
                UpdateVerification? result = null;
                if (outcome.Results?.TryGetValue(package.PackageId, out var found) == true) result = found;
                if (result?.IsSatisfied == true)
                {
                    if (!string.IsNullOrWhiteSpace(result.InstalledVersion)) package.CurrentVersion = result.InstalledVersion;
                    package.IsSelected = false;
                    Packages.Remove(package);
                    updated++;
                    AppendLog($"Updated to {package.CurrentVersion}.", LogLevel.Success, package.Name);
                }
                else if (outcome.Results is not null)
                {
                    if (result?.StillOutdated is { } info)
                    {
                        package.CurrentVersion = info.CurrentVersion;
                        package.AvailableVersion = info.AvailableVersion;
                    }
                    package.Status = UpdateStatus.Failed;
                    package.FailureKind = UpdateFailureKind.Update;
                    package.StatusMessage = "The package is still outdated after the update command completed.";
                    package.IsSelected = true;
                    failed++;
                }
                else
                {
                    package.Status = UpdateStatus.Failed;
                    package.FailureKind = UpdateFailureKind.Verification;
                    package.StatusMessage = outcome.Cancelled
                        ? "The update command completed, but verification was cancelled."
                        : $"The update command completed, but verification failed: {outcome.Error?.Message}";
                    package.IsSelected = true;
                    verificationFailed++;
                }
                OperationCompleted++;
            }
            if (outcome.Error is not null)
                AppendLog($"Verification failed — {outcome.Error.Message}", LogLevel.Error,
                    outcome.Batch.Items[0].Package.Source);
        }
        UpdateSummary = new(updated, failed, cancelled, verificationFailed);
        ScanSummary = HasSourceIssues ? ScanSummaryKind.CompletedWithIssues
            : UpdateCount == 0 ? ScanSummaryKind.UpdatesCompleted : ScanSummaryKind.UpdatesAvailable;
        AppendLog(cancellationToken.IsCancellationRequested ? "Update run cancelled." : "Update run finished.",
            failed + verificationFailed + cancelled > 0 ? LogLevel.Warning : LogLevel.Success);
        RefreshComputed();
    }

    private async Task UpdateWithElevationRetryAsync(PackageUpdate package, UpdateRequest request,
        IProgress<ProcessOutputEvent> progress, CancellationToken cancellationToken)
    {
        try
        {
            await package.SourceRef.UpdateAsync(request, package.ToolContext, progress, cancellationToken);
        }
        catch (SourceException ex) when (!request.Elevated && ex.CanRetryElevated
            && !cancellationToken.IsCancellationRequested)
        {
            AppendLog("Retrying with administrator approval…", LogLevel.Warning, package.Name);
            try
            {
                await package.SourceRef.UpdateAsync(request with { Elevated = true },
                    package.ToolContext, progress, cancellationToken);
            }
            catch (SourceException elevatedEx) when (elevatedEx.CanRetryElevated)
            {
                // Elevation was already tried: offering another administrator retry is misleading.
                throw new SourceException(elevatedEx.Kind, elevatedEx.Message, canRetryElevated: false);
            }
        }
    }

    private int ReplacePackages(SourceOptionViewModel option, IReadOnlyList<PackageInfo> infos)
    {
        RemovePackages(option.Id);
        var ignored = _settings.GetIgnoredUpdates();
        var visible = infos.Where(info => !IsIgnored(ignored, option.Id, info)).ToList();
        foreach (var info in visible)
        {
            var package = new PackageUpdate
            {
                SourceRef = option.Source,
                ToolContext = option.ToolContext!,
                SourceId = option.Id,
                PackageId = info.Id,
                Name = info.Name,
                Source = option.Name,
                CurrentVersion = info.CurrentVersion,
                AvailableVersion = info.AvailableVersion,
                Status = info.StatusMessage is null ? UpdateStatus.Pending : UpdateStatus.Failed,
                FailureKind = info.StatusMessage is null ? null : UpdateFailureKind.Verification,
                StatusMessage = info.StatusMessage,
            };
            package.PropertyChanged += OnPackageChanged;
            Packages.Add(package);
        }
        PackagesView.Refresh();
        return infos.Count - visible.Count;
    }

    private void RemovePackages(SourceId sourceId)
    {
        foreach (var package in Packages.Where(p => p.SourceId == sourceId).ToList())
        {
            package.PropertyChanged -= OnPackageChanged;
            Packages.Remove(package);
        }
    }

    private static bool IsIgnored(IReadOnlySet<string> ignored, SourceId sourceId, PackageInfo info) =>
        ignored.Contains($"{sourceId}:{info.Id}")
        || ignored.Contains($"{sourceId}:{info.Id}@{info.AvailableVersion}");

    private void OnPackageChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(PackageUpdate.IsSelected) or nameof(PackageUpdate.Status)) RefreshComputed();
        if (e.PropertyName is nameof(PackageUpdate.Name) or nameof(PackageUpdate.Source)
            or nameof(PackageUpdate.CurrentVersion) or nameof(PackageUpdate.AvailableVersion)
            or nameof(PackageUpdate.StatusTitle)) PackagesView.Refresh();
    }

    private void OnSourceOptionChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(SourceOptionViewModel.IsEnabled) || sender is not SourceOptionViewModel option) return;
        if (IsBusy) { option.IsEnabled = !option.IsEnabled; return; }
        try
        {
            _settings.SetSourceEnabled(option.Id, option.IsEnabled);
            if (!option.IsEnabled) RemovePackages(option.Id);
            option.State.Set(option.IsEnabled ? SourceScanStatus.NotScanned : SourceScanStatus.Disabled);
            option.Refresh();
        }
        catch (Exception ex) { AppendLog($"Could not save source setting: {ex.Message}", LogLevel.Error); }
        RefreshComputed();
    }

    private void AppendOutput(PackageUpdate package, ProcessOutputEvent output)
    {
        var line = output.Line.Trim();
        if (line.Length == 0) return;
        var key = $"{package.Id}|{output.Stream}";
        if (_lastOutput.GetValueOrDefault(key) == line) return;
        _lastOutput[key] = line;
        AppendLog(line, LogLevel.Output, package.Name, output.Stream);
    }

    internal void LogLaunchDiagnostic(string message) => AppendLog(message);

    private void AppendLog(string message, LogLevel level = LogLevel.Info, string? scope = null,
        ProcessOutputStream? stream = null)
    {
        LogEntries.Add(new(++_nextLogId, DateTimeOffset.Now, level, message, scope, stream));
        while (LogEntries.Count > 1000) LogEntries.RemoveAt(0);
    }

    private void RefreshComputed()
    {
        OnPropertyChanged(nameof(IsBusy));
        OnPropertyChanged(nameof(UpdateCount));
        OnPropertyChanged(nameof(SelectedCount));
        OnPropertyChanged(nameof(CanUpdate));
        OnPropertyChanged(nameof(HasPackages));
        OnPropertyChanged(nameof(HasSourceIssues));
        OnPropertyChanged(nameof(SourceIssueCount));
        OnPropertyChanged(nameof(ShowIssueBanner));
        OnPropertyChanged(nameof(ShowSourceProgress));
        OnPropertyChanged(nameof(HasCacheCleanupStatus));
        OnPropertyChanged(nameof(ScanButtonText));
        OnPropertyChanged(nameof(UpdateButtonText));
        OnPropertyChanged(nameof(LogButtonText));
        OnPropertyChanged(nameof(FooterText));
        OnPropertyChanged(nameof(StatusText));
        OnPropertyChanged(nameof(EmptyTitle));
        OnPropertyChanged(nameof(EmptyDescription));
        UpdateSelectedCommand.NotifyCanExecuteChanged();
    }

    partial void OnOperationChanged(AppOperationKind value) => RefreshComputed();
    partial void OnScanSummaryChanged(ScanSummaryKind value) => RefreshComputed();
    partial void OnIsLogVisibleChanged(bool value) => RefreshComputed();
    partial void OnOperationCompletedChanged(int value) => OnPropertyChanged(nameof(StatusText));
    partial void OnOperationTotalChanged(int value) => OnPropertyChanged(nameof(StatusText));
    partial void OnLastScanCompletedAtChanged(DateTimeOffset? value) => OnPropertyChanged(nameof(FooterText));
    partial void OnCacheCleanupStatusChanged(string? value)
    {
        OnPropertyChanged(nameof(HasCacheCleanupStatus));
        OnPropertyChanged(nameof(StatusText));
    }

    private enum OutcomeKind { Report, Unavailable, Failed, Cancelled }
    private sealed record SourceOutcome(SourceOptionViewModel Option, OutcomeKind Kind,
        SourceScanReport? Report = null, SourceIssue? Issue = null);
    private sealed record VerificationBatch(IPackageSource Source, ToolContext Context,
        List<(PackageUpdate Package, UpdateRequest Request)> Items);
    private sealed record VerificationOutcome(VerificationBatch Batch,
        IReadOnlyDictionary<string, UpdateVerification>? Results, Exception? Error, bool Cancelled);
}
