using CommunityToolkit.Mvvm.ComponentModel;
using UpdateManager.Services;

namespace UpdateManager.ViewModels;

public partial class SourceOptionViewModel : ObservableObject
{
    public SourceOptionViewModel(IPackageSource source)
    {
        Source = source;
    }

    public IPackageSource Source { get; }

    public string Name => Source.Name;

    [ObservableProperty]
    private bool _isEnabled = true;
}
