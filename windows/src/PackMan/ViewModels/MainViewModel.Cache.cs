using CommunityToolkit.Mvvm.Input;
using PackMan.Models;
using PackMan.Services;

namespace PackMan.ViewModels;

public partial class MainViewModel
{
    [RelayCommand]
    private void PreviewCaches()
    {
        if (IsBusy) return;
        StartOperation(async ct =>
        {
            Operation = AppOperationKind.InspectingCache;
            await InspectCachesAsync(CacheOptions.Where(i => i.IsSelected).ToList(), ct);
        });
    }

    private async Task InspectCachesAsync(IReadOnlyList<CacheOptionViewModel> items, CancellationToken ct)
    {
            foreach (var item in items)
            {
                ct.ThrowIfCancellationRequested();
                item.PreviewText = "Inspecting cache…";
                try
                {
                    var option = SourceOptions.First(o => o.Id == item.Id);
                    var probe = await item.Source.ProbeAsync(ct);
                    if (!probe.IsAvailable) { item.PreviewText = "Unavailable: " + probe.Issue?.Message; continue; }
                    option.ToolContext = probe.Context;
                    option.Refresh();
                    if (_cacheInspector is null) { item.PreviewText = "Cache size cannot be measured."; continue; }
                    var preview = await _cacheInspector.PreviewAsync(item.Source, probe.Context!, ct);
                    item.PreviewText = $"{preview.SizeText}\n{string.Join("\n", preview.Paths)}\n{preview.Note}";
                }
                catch (OperationCanceledException) { item.PreviewText = "Preview cancelled."; throw; }
                catch (Exception ex) { item.PreviewText = $"Size unavailable: {ex.Message}"; }
            }
    }
}
