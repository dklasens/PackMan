using CommunityToolkit.Mvvm.ComponentModel;
using PackMan.Services;

namespace PackMan.Models;

public partial class PackageUpdate : ObservableObject
{
    public required IPackageSource SourceRef { get; init; }
    public required ToolContext ToolContext { get; init; }
    public required SourceId SourceId { get; init; }
    public required string PackageId { get; init; }
    public string Id => $"{SourceId}:{PackageId}";

    [ObservableProperty] private string _name = string.Empty;
    [ObservableProperty] private string _source = string.Empty;
    [ObservableProperty] private string _currentVersion = string.Empty;
    [ObservableProperty] private string _availableVersion = string.Empty;
    [ObservableProperty] private bool _isSelected = true;
    [ObservableProperty] private UpdateStatus _status = UpdateStatus.Pending;
    [ObservableProperty] private UpdateFailureKind? _failureKind;
    [ObservableProperty] private string? _statusMessage;
    [ObservableProperty] private bool _canRetryElevated;

    public bool IsActionable => Status is UpdateStatus.Pending or UpdateStatus.Failed or UpdateStatus.Cancelled;
    public bool NeedsVerificationOnly => Status == UpdateStatus.Failed && FailureKind == UpdateFailureKind.Verification;
    public string StatusTitle => Status switch
    {
        UpdateStatus.Pending => "Pending",
        UpdateStatus.Updating => "Updating",
        UpdateStatus.Verifying => "Verifying",
        UpdateStatus.Failed => "Failed",
        UpdateStatus.Cancelled => "Cancelled",
        _ => Status.ToString(),
    };

    public UpdateRequest ToRequest(bool elevated = false) =>
        new(PackageId, Name, AvailableVersion, elevated);

    partial void OnStatusChanged(UpdateStatus value)
    {
        OnPropertyChanged(nameof(IsActionable));
        OnPropertyChanged(nameof(NeedsVerificationOnly));
        OnPropertyChanged(nameof(StatusTitle));
    }
}
