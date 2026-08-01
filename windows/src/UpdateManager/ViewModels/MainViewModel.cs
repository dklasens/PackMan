using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows.Data;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using UpdateManager.Models;
using UpdateManager.Services;

namespace UpdateManager.ViewModels;

public partial class MainViewModel : ObservableObject
{
    private readonly IReadOnlyList<IPackageSource> _sources;
    private readonly SettingsService _settings;

    public MainViewModel(IEnumerable<IPackageSource> sources, SettingsService settings)
    {
        _sources = sources.ToList();
        _settings = settings;
        _settings.Load();

        SourceOptions = new ObservableCollection<SourceOptionViewModel>(
            _sources.Select(s =>
            {
                var option = new SourceOptionViewModel(s)
                {
                    IsEnabled = !_settings.DisabledSources.Contains(s.Name),
                };
                option.PropertyChanged += OnSourceOptionChanged;
                return option;
            }));

        PackagesView = CollectionViewSource.GetDefaultView(Packages);
        PackagesView.SortDescriptions.Add(new SortDescription(nameof(PackageUpdate.Source), ListSortDirection.Ascending));
        PackagesView.SortDescriptions.Add(new SortDescription(nameof(PackageUpdate.Name), ListSortDirection.Ascending));
    }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(ScanCommand))]
    [NotifyCanExecuteChangedFor(nameof(UpdateSelectedCommand))]
    [NotifyCanExecuteChangedFor(nameof(SelectAllCommand))]
    [NotifyCanExecuteChangedFor(nameof(SelectNoneCommand))]
    private bool _isBusy;

    [ObservableProperty]
    private string _statusText = "Ready. Click Scan to check for updates.";

    public ObservableCollection<PackageUpdate> Packages { get; } = new();

    public ICollectionView PackagesView { get; }

    public ObservableCollection<string> LogLines { get; } = new();

    public ObservableCollection<SourceOptionViewModel> SourceOptions { get; }

    [RelayCommand(CanExecute = nameof(CanRun))]
    private async Task ScanAsync()
    {
        var enabledSources = SourceOptions.Where(o => o.IsEnabled).Select(o => o.Source).ToList();
        if (enabledSources.Count == 0)
        {
            StatusText = "No sources selected.";
            return;
        }

        IsBusy = true;
        StatusText = "Scanning...";
        Packages.Clear();
        Log($"Scan started ({string.Join(", ", enabledSources.Select(s => s.Name))}).");

        var results = await Task.WhenAll(enabledSources.Select(ScanSourceSafeAsync));
        foreach (var package in results.SelectMany(r => r))
        {
            Packages.Add(package);
        }

        Log($"Scan complete. {Packages.Count} update(s) found.");
        StatusText = Packages.Count > 0
            ? $"{Packages.Count} update(s) available."
            : "System is up to date.";
        IsBusy = false;
    }

    [RelayCommand(CanExecute = nameof(CanRun))]
    private async Task UpdateSelectedAsync()
    {
        var selected = Packages.Where(p => p.IsSelected && p.SourceRef is not null).ToList();
        if (selected.Count == 0)
        {
            StatusText = "Nothing selected.";
            return;
        }

        IsBusy = true;
        StatusText = $"Updating {selected.Count} package(s)...";
        Log($"Updating {selected.Count} selected package(s).");

        foreach (var package in selected)
        {
            package.Status = UpdateStatus.Updating;
            var lastLine = string.Empty;
            var progress = new Progress<string>(line =>
            {
                if (string.IsNullOrWhiteSpace(line) || line == lastLine)
                    return;
                lastLine = line;
                Log($"  {package.Name}: {line}");
            });

            try
            {
                await package.SourceRef!.UpdateAsync(package, progress);
                package.Status = UpdateStatus.Succeeded;
                package.CurrentVersion = package.AvailableVersion;
                Log($"[OK] {package.Name} -> {package.AvailableVersion}");
            }
            catch (Exception ex)
            {
                package.Status = UpdateStatus.Failed;
                package.StatusMessage = ex.Message;
                Log($"[FAIL] {package.Name}: {ex.Message}");
            }
        }

        var failed = selected.Count(p => p.Status == UpdateStatus.Failed);
        StatusText = failed == 0
            ? "Updates complete."
            : $"Updates finished with {failed} failure(s).";
        Log("Update run finished.");
        IsBusy = false;
    }

    [RelayCommand(CanExecute = nameof(CanRun))]
    private void SelectAll()
    {
        foreach (var package in Packages)
            package.IsSelected = true;
    }

    [RelayCommand(CanExecute = nameof(CanRun))]
    private void SelectNone()
    {
        foreach (var package in Packages)
            package.IsSelected = false;
    }

    private async Task<IReadOnlyList<PackageUpdate>> ScanSourceSafeAsync(IPackageSource source)
    {
        try
        {
            if (!await source.IsAvailableAsync())
            {
                Log($"{source.Name}: not found, skipped.");
                return [];
            }

            Log($"{source.Name}: scanning...");
            var found = await source.ScanAsync();
            Log($"{source.Name}: {found.Count} update(s).");
            return found;
        }
        catch (Exception ex)
        {
            Log($"{source.Name}: scan failed - {ex.Message}");
            return [];
        }
    }

    private void OnSourceOptionChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(SourceOptionViewModel.IsEnabled) || sender is not SourceOptionViewModel option)
            return;

        if (option.IsEnabled)
            _settings.DisabledSources.Remove(option.Name);
        else
            _settings.DisabledSources.Add(option.Name);

        _settings.Save();
    }

    private bool CanRun() => !IsBusy;

    private void Log(string message) => LogLines.Add($"[{DateTime.Now:HH:mm:ss}] {message}");
}
