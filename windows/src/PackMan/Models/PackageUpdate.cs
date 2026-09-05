using CommunityToolkit.Mvvm.ComponentModel;
using PackMan.Services;

namespace PackMan.Models;

public partial class PackageUpdate : ObservableObject
{
    public required IPackageSource SourceRef { get; init; }
    public required ToolContext ToolContext { get; init; }
    public required SourceId SourceId { get; init; }
    public required string PackageId { get; init; }
    public string? Repository { get; init; }
    public bool HasExactIdentity { get; init; } = true;
    public bool RequiresUnknownVersionConsent { get; init; }
    public bool AllowUnknownVersion { get; init; }
    public string? ScanWarning { get; init; }
    public string Id => $"{SourceId}:{Repository}:{PackageId}";
    public string ToolPath => ToolContext.ExecutablePath;
    public string RepositoryText => Repository ?? Source;
    public bool SupportsInteractive => SourceId == SourceId.Winget;
    public bool SupportsMetadata => SourceId is SourceId.Winget or SourceId.Npm;
    public string? PackageUrl => SourceId switch
    {
        SourceId.Winget when Repository == "msstore" => $"https://apps.microsoft.com/detail/{Uri.EscapeDataString(PackageId)}",
        SourceId.Npm => $"https://www.npmjs.com/package/{Uri.EscapeDataString(PackageId)}",
        SourceId.Pip or SourceId.Pipx => $"https://pypi.org/project/{Uri.EscapeDataString(PackageId)}/",
        SourceId.Dotnet => $"https://www.nuget.org/packages/{Uri.EscapeDataString(PackageId)}",
        SourceId.Chocolatey => $"https://community.chocolatey.org/packages/{Uri.EscapeDataString(PackageId)}",
        _ => null,
    };

    [ObservableProperty] private string _name = string.Empty;
    [ObservableProperty] private string _source = string.Empty;
    [ObservableProperty] private string _currentVersion = string.Empty;
    [ObservableProperty] private string _availableVersion = string.Empty;
    [ObservableProperty] private bool _isSelected = true;
    [ObservableProperty] private UpdateStatus _status = UpdateStatus.Pending;
    [ObservableProperty] private UpdateFailureKind? _failureKind;
    [ObservableProperty] private string? _statusMessage;
    [ObservableProperty] private bool _canRetryElevated;
    [ObservableProperty] private RestartState _restart;
    [ObservableProperty] private string? _verificationEvidence;
    [ObservableProperty] private string _commandOutput = string.Empty;
    [ObservableProperty] private string? _publisherUrl;
    [ObservableProperty] private string? _releaseNotesUrl;
    [ObservableProperty] private string? _metadataStatus;

    public bool IsActionable => HasExactIdentity && (!RequiresUnknownVersionConsent || AllowUnknownVersion)
        && Status is UpdateStatus.Pending or UpdateStatus.Failed or UpdateStatus.Cancelled;
    public bool NeedsVerificationOnly => Status == UpdateStatus.Failed && FailureKind == UpdateFailureKind.Verification;
    public string StatusTitle => !HasExactIdentity ? "Incomplete ID" : Status switch
    {
        UpdateStatus.Pending => "Pending",
        UpdateStatus.Updating => "Updating",
        UpdateStatus.Verifying => "Verifying",
        UpdateStatus.Failed => "Failed",
        UpdateStatus.Cancelled => "Cancelled",
        _ => Status.ToString(),
    };

    public UpdateRequest ToRequest(bool elevated = false, bool interactive = false) =>
        new(PackageId, Name, AvailableVersion, elevated, Repository, AllowUnknownVersion, interactive);

    partial void OnStatusChanged(UpdateStatus value)
    {
        OnPropertyChanged(nameof(IsActionable));
        OnPropertyChanged(nameof(NeedsVerificationOnly));
        OnPropertyChanged(nameof(StatusTitle));
    }
}
