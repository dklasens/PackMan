using CommunityToolkit.Mvvm.ComponentModel;
using PackMan.Services;

namespace PackMan.Models;

public enum SourceScanStatus
{
    Disabled,
    NotScanned,
    Waiting,
    Probing,
    Scanning,
    Installing,
    Succeeded,
    Partial,
    Unavailable,
    Failed,
    Cancelled,
}

public partial class SourceState : ObservableObject
{
    [ObservableProperty] private SourceScanStatus _status = SourceScanStatus.NotScanned;
    [ObservableProperty] private SourcePhase _phase = SourcePhase.Probing;
    [ObservableProperty] private DateTimeOffset? _startedAt;
    [ObservableProperty] private DateTimeOffset? _completedAt;
    [ObservableProperty] private int _updateCount;
    [ObservableProperty] private IReadOnlyList<SourceIssue> _issues = [];

    public bool HasIssue => Status is SourceScanStatus.Partial or SourceScanStatus.Unavailable
        or SourceScanStatus.Failed or SourceScanStatus.Cancelled;

    public void Set(SourceScanStatus status, SourcePhase phase = SourcePhase.Probing,
        int updateCount = 0, IReadOnlyList<SourceIssue>? issues = null)
    {
        Status = status;
        Phase = phase;
        UpdateCount = updateCount;
        Issues = issues ?? [];
        if (status is SourceScanStatus.Probing or SourceScanStatus.Scanning or SourceScanStatus.Installing)
            StartedAt ??= DateTimeOffset.Now;
        if (status is SourceScanStatus.Succeeded or SourceScanStatus.Partial or SourceScanStatus.Unavailable
            or SourceScanStatus.Failed or SourceScanStatus.Cancelled)
            CompletedAt = DateTimeOffset.Now;
        OnPropertyChanged(nameof(HasIssue));
    }
}

public enum AppOperationKind { Idle, Scanning, Updating, Installing, CleaningCache, Cancelling, UpdatingApp }
public enum ScanSummaryKind
{
    NotStarted,
    Running,
    UpdatesAvailable,
    UpdatesCompleted,
    UpToDate,
    CompletedWithIssues,
    AllUnavailable,
    NoSources,
    Cancelled,
}

public sealed record UpdateRunSummary(int Updated, int Failed, int Cancelled, int VerificationFailed);

public enum LogLevel { Info, Output, Warning, Error, Success }
public sealed record LogEntry(
    long Id,
    DateTimeOffset Timestamp,
    LogLevel Level,
    string Message,
    string? Scope = null,
    ProcessOutputStream? Stream = null)
{
    public string DisplayText => $"[{Timestamp:HH:mm:ss}]"
        + (Scope is null ? "" : $" [{Scope}]")
        + (Stream == ProcessOutputStream.StandardError ? " [stderr]" : "")
        + $" {Message}";
}
