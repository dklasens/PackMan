using CommunityToolkit.Mvvm.ComponentModel;
using UpdateManager.Services;

namespace UpdateManager.Models;

public partial class PackageUpdate : ObservableObject
{
    public IPackageSource? SourceRef { get; set; }

    public string SourceDetail { get; set; } = string.Empty;

    [ObservableProperty]
    private string _id = string.Empty;

    [ObservableProperty]
    private string _name = string.Empty;

    [ObservableProperty]
    private string _source = string.Empty;

    [ObservableProperty]
    private string _currentVersion = string.Empty;

    [ObservableProperty]
    private string _availableVersion = string.Empty;

    [ObservableProperty]
    private bool _isSelected = true;

    [ObservableProperty]
    private UpdateStatus _status = UpdateStatus.Pending;

    [ObservableProperty]
    private string? _statusMessage;
}
