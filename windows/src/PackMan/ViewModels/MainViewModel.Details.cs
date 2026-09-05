using System.Diagnostics;
using System.Text.Json;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using PackMan.Models;
using PackMan.Services;

namespace PackMan.ViewModels;

public partial class MainViewModel
{
    [RelayCommand]
    private void ShowPackageDetails(PackageUpdate? package)
    {
        if (package is null) return;
        SelectedPackage = package;
        new ActivityWindow(this) { Owner = System.Windows.Application.Current?.MainWindow }.Show();
    }
    [RelayCommand]
    private void CancelOperation()
    {
        if (IsBusy) ScanOrCancelCommand.Execute(null);
    }

    [RelayCommand]
    private void LoadPackageLinks(PackageUpdate? package)
    {
        if (IsBusy || package?.HasExactIdentity != true || _metadata is null) return;
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
        if (IsBusy || package?.IsActionable != true) return;
        package.FailureKind = null;
        StartUpdates([(package, false)]);
    }

    [RelayCommand]
    private void VerifyAgain(PackageUpdate? package)
    {
        if (IsBusy || package?.HasExactIdentity != true) return;
        StartUpdates([(package, false)], verifyOnly: true);
    }

    [RelayCommand]
    private void UpdateInteractive(PackageUpdate? package)
    {
        if (IsBusy || package?.IsActionable != true || !package.SupportsInteractive) return;
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
        RemovePackages(SourceId.Winget);
        ScanSummary = ScanSummaryKind.NotStarted;
        RefreshComputed();
    }

    private void SaveHistory(UpdateHistoryEntry entry)
    {
        try
        {
            _history.Save(entry);
            HistoryEntries.Clear();
            foreach (var item in _history.Read()) HistoryEntries.Add(item);
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
