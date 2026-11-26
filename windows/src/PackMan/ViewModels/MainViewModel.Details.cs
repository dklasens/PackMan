using System.Diagnostics;
using System.Text.Json;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using PackMan.Models;
using PackMan.Services;

namespace PackMan.ViewModels;

public partial class MainViewModel
{
    private ActivityWindow? _activityWindow;

    [RelayCommand]
    private void ShowPackageDetails(PackageUpdate? package)
    {
        if (package is null) return;
        SelectedPackage = package;
        OpenActivityWindow();
    }

    internal void OpenActivityWindow(bool history = false)
    {
        if (_activityWindow is { } existing)
        {
            existing.SelectTab(history);
            if (existing.WindowState == System.Windows.WindowState.Minimized)
                existing.WindowState = System.Windows.WindowState.Normal;
            existing.Activate();
            return;
        }
        var window = new ActivityWindow(this, history) { Owner = System.Windows.Application.Current?.MainWindow };
        _activityWindow = window;
        window.Closed += (_, _) => { if (ReferenceEquals(_activityWindow, window)) _activityWindow = null; };
        window.Show();
    }
    [RelayCommand]
    private void CancelOperation()
    {
        if (IsBusy) ScanOrCancelCommand.Execute(null);
    }

    [RelayCommand]
    private void LoadPackageLinks(PackageUpdate? package)
    {
        if (IsBusy || package?.HasExactIdentity != true || !IsCurrentPackage(package) || _metadata is null) return;
        StartOperation(async ct =>
        {
            Operation = AppOperationKind.InspectingPackage;
            package.MetadataStatus = "Loading publisher and release links…";
            try
            {
                var links = await _metadata.GetAsync(package.SourceId, package.ToRequest(), package.ToolContext, ct);
                package.PublisherUrl = links.PublisherUrl;
                package.ReleaseNotesUrl = links.ReleaseNotesUrl;
                package.MetadataStatus = links.PublisherUrl is null && links.ReleaseNotesUrl is null
                    ? "No publisher or release links were supplied by this source. The package page may have more information."
                    : "Links supplied by the package source.";
            }
            catch (OperationCanceledException) { package.MetadataStatus = "Link lookup cancelled."; }
            catch (Exception ex) { package.MetadataStatus = $"Could not load links: {ex.Message}"; }
        });
    }

    private static bool CanOpenMetadataLink(string? url) => PackageMetadataService.SafeUrl(url) is not null;

    [RelayCommand(CanExecute = nameof(CanOpenMetadataLink))]
    private void OpenMetadataLink(string? url)
    {
        if (PackageMetadataService.SafeUrl(url) is not { } safeUrl) return;
        try { Process.Start(new ProcessStartInfo(safeUrl) { UseShellExecute = true }); }
        catch (Exception ex) { AppendLog($"Could not open link: {ex.Message}", LogLevel.Warning); }
    }
    [RelayCommand]
    private void RetryUpdate(PackageUpdate? package)
    {
        if (IsBusy || package?.IsActionable != true || !IsCurrentPackage(package)) return;
        package.FailureKind = null;
        StartUpdates([(package, false)]);
    }

    [RelayCommand]
    private void VerifyAgain(PackageUpdate? package)
    {
        if (IsBusy || package?.HasExactIdentity != true || !IsCurrentPackage(package)) return;
        StartUpdates([(package, false)], verifyOnly: true);
    }

    [RelayCommand]
    private void UpdateInteractive(PackageUpdate? package)
    {
        if (IsBusy || package?.IsActionable != true || !package.SupportsInteractive || !IsCurrentPackage(package)) return;
        package.FailureKind = null;
        StartUpdates([(package, false)], interactive: true);
    }

    [RelayCommand]
    private void RetryFailed()
    {
        if (IsBusy) return;
        StartUpdates(Packages.Where(p => p.IsActionable && p.Status == UpdateStatus.Failed).Select(p => (p, false)).ToList());
    }

    private static bool CanOpenPackagePage(PackageUpdate? package) => package?.PackageUrl is not null;

    [RelayCommand(CanExecute = nameof(CanOpenPackagePage))]
    private void OpenPackagePage(PackageUpdate? package)
    {
        if (package?.PackageUrl is not { } url) return;
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception ex) { AppendLog($"Could not open package page: {ex.Message}", LogLevel.Warning); }
    }

    partial void OnUpdateSummaryChanged(UpdateRunSummary? value)
    {
        OnPropertyChanged(nameof(HasUpdateSummary));
        OnPropertyChanged(nameof(UpdateSummaryText));
    }

    partial void OnIncludeUnknownVersionsChanged(bool value)
    {
        if (IsBusy)
        {
            _includeUnknownVersions = !value;
            OnPropertyChanged(nameof(IncludeUnknownVersions));
            return;
        }
        try { _settings.IncludeUnknownVersions = value; }
        catch (Exception ex) { AppendLog($"Could not save unknown-version preference: {ex.Message}", LogLevel.Error); }
        if (SourceOptions.FirstOrDefault(option => option.Id == SourceId.Winget) is { } winget)
            InvalidateSource(winget);
        DeriveScanSummary(log: false);
        RefreshComputed();
    }

    private Task SaveHistoryAsync(UpdateHistoryEntry entry) => SaveHistoryAsync([entry]);

    private async Task SaveHistoryAsync(IEnumerable<UpdateHistoryEntry> entries)
    {
        try
        {
            await _history.SaveRangeAsync(entries.ToArray());
            var snapshot = _history.Read();
            var ids = snapshot.Select(item => item.Id).ToHashSet();
            for (var i = HistoryEntries.Count - 1; i >= 0; i--)
                if (!ids.Contains(HistoryEntries[i].Id)) HistoryEntries.RemoveAt(i);
            for (var i = 0; i < snapshot.Count; i++)
            {
                if (i < HistoryEntries.Count && HistoryEntries[i] == snapshot[i]) continue;
                var existing = HistoryEntries.FirstOrDefault(item => item.Id == snapshot[i].Id);
                if (existing is null) HistoryEntries.Insert(i, snapshot[i]);
                else
                {
                    var oldIndex = HistoryEntries.IndexOf(existing);
                    if (oldIndex != i) HistoryEntries.Move(oldIndex, i);
                    if (HistoryEntries[i] != snapshot[i]) HistoryEntries[i] = snapshot[i];
                }
            }
        }
        catch (Exception ex) { AppendLog($"Could not save update history: {ex.Message}", LogLevel.Warning); }
    }

    [RelayCommand]
    private void ExportDiagnostics()
    {
        var picker = new SaveFileDialog { Title = "Export redacted diagnostics", Filter = "JSON files|*.json",
            FileName = $"PackMan-diagnostics-{DateTime.Now:yyyyMMdd-HHmm}.json" };
        if (picker.ShowDialog() != true) return;
        try { File.WriteAllText(picker.FileName, BuildDiagnostics()); }
        catch (Exception ex) { AppendLog($"Could not export diagnostics: {ex.Message}", LogLevel.Error); }
    }

    internal string BuildDiagnostics()
    {
        var entries = HistoryEntries.Select(e => e with {
            Name = DiagnosticRedactor.Redact(e.Name), PackageId = DiagnosticRedactor.Redact(e.PackageId),
            Repository = DiagnosticRedactor.Redact(e.Repository), ToolPath = DiagnosticRedactor.Redact(e.ToolPath),
            Output = DiagnosticRedactor.Redact(e.Output), Message = DiagnosticRedactor.Redact(e.Message),
            Evidence = DiagnosticRedactor.Redact(e.Evidence) });
        return JsonSerializer.Serialize(new { Version = VersionText, ExportedAt = DateTimeOffset.Now,
            History = entries, Log = LogEntries.Select(e => DiagnosticRedactor.Redact(e.DisplayText)) },
            new JsonSerializerOptions { WriteIndented = true });
    }
}
