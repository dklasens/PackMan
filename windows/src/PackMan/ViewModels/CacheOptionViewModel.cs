using CommunityToolkit.Mvvm.ComponentModel;
using PackMan.Services;

namespace PackMan.ViewModels;

public partial class CacheOptionViewModel(IPackageSource source) : ObservableObject
{
    public IPackageSource Source { get; } = source;
    public SourceId Id => Source.Id;
    public string Name => Source.Name;
    public string Scope => CacheInspector.ScopeFor(Id);
    [ObservableProperty] private bool _isSelected = true;
    [ObservableProperty] private string _previewText = "Preview to estimate reclaimable space.";
    [ObservableProperty] private string _resultText = string.Empty;
}
