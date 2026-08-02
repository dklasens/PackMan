using CommunityToolkit.Mvvm.ComponentModel;
using PackMan.Models;
using PackMan.Services;

namespace PackMan.ViewModels;

public partial class SourceOptionViewModel : ObservableObject
{
    public SourceOptionViewModel(IPackageSource source, bool enabled, string? executableOverride)
    {
        Source = source;
        _isEnabled = enabled;
        _executableOverride = executableOverride;
        State.Set(enabled ? SourceScanStatus.NotScanned : SourceScanStatus.Disabled);
    }

    public IPackageSource Source { get; }
    public SourceDescriptor Descriptor => Source.Descriptor;
    public SourceId Id => Source.Id;
    public string Name => Source.Name;
    public SourceState State { get; } = new();
    [ObservableProperty] private bool _isEnabled;
    [ObservableProperty] private ToolContext? _toolContext;
    [ObservableProperty] private SourceIssue? _probeIssue;
    [ObservableProperty] private string? _executableOverride;

    public bool HasIssue => IsEnabled && State.HasIssue;
    public string? ExecutablePath => ToolContext?.ExecutablePath ?? ExecutableOverride;
    public string VersionAndOrigin => ToolContext is null ? string.Empty : $"{ToolContext.Version} • {OriginText(ToolContext.Origin)}";
    public string StatusText => State.Status switch
    {
        SourceScanStatus.Disabled => "Disabled",
        SourceScanStatus.NotScanned or SourceScanStatus.Waiting => "Not checked",
        SourceScanStatus.Probing => "Checking availability",
        SourceScanStatus.Scanning => State.Phase switch
        {
            SourcePhase.Refreshing => "Refreshing metadata",
            SourcePhase.Verifying => "Verifying updates",
            _ => "Checking packages",
        },
        SourceScanStatus.Succeeded => $"Available • {State.UpdateCount} update{(State.UpdateCount == 1 ? "" : "s")}",
        SourceScanStatus.Partial => $"Partial • {State.UpdateCount} update{(State.UpdateCount == 1 ? "" : "s")}",
        SourceScanStatus.Unavailable => "Not available",
        SourceScanStatus.Failed => "Scan failed",
        SourceScanStatus.Cancelled => "Cancelled",
        _ => State.Status.ToString(),
    };
    public string IssueText => (ProbeIssue ?? State.Issues.FirstOrDefault())?.Message ?? string.Empty;
    public string RecoveryText => (ProbeIssue ?? State.Issues.FirstOrDefault())?.Recovery ?? string.Empty;
    public string ElapsedText => State.Status is SourceScanStatus.Probing or SourceScanStatus.Scanning && State.StartedAt is { } started
        ? $" • {(int)(DateTimeOffset.Now - started).TotalMinutes}:{(DateTimeOffset.Now - started).Seconds:00}" : string.Empty;
    public bool HasOverride => !string.IsNullOrWhiteSpace(ExecutableOverride);
    public bool ShowInstallationHelp => Descriptor.InstallationUrl is not null && (ProbeIssue is not null || State.Status == SourceScanStatus.Unavailable);

    public void Refresh()
    {
        OnPropertyChanged(nameof(HasIssue));
        OnPropertyChanged(nameof(ExecutablePath));
        OnPropertyChanged(nameof(VersionAndOrigin));
        OnPropertyChanged(nameof(StatusText));
        OnPropertyChanged(nameof(IssueText));
        OnPropertyChanged(nameof(RecoveryText));
        OnPropertyChanged(nameof(ElapsedText));
        OnPropertyChanged(nameof(HasOverride));
        OnPropertyChanged(nameof(ShowInstallationHelp));
    }

    private static string OriginText(ToolResolutionOrigin origin) => origin switch
    {
        ToolResolutionOrigin.Custom => "Custom",
        ToolResolutionOrigin.Path => "PATH",
        ToolResolutionOrigin.KnownLocation => "Known location",
        ToolResolutionOrigin.UserLocation => "User location",
        ToolResolutionOrigin.VersionManager => "Version manager",
        _ => origin.ToString(),
    };
}
