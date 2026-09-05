namespace PackMan.Services;

internal static class UiTestEnvironment
{
    internal static void CaptureWindow(System.Windows.FrameworkElement window, string name)
    {
        if (Scenario is null || Environment.GetEnvironmentVariable("PACKMAN_UI_SCREENSHOT_DIR") is not { Length: > 0 } directory) return;
        _ = window.Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ContextIdle, new Action(() =>
        {
            if (window.ActualWidth <= 0 || window.ActualHeight <= 0) return;
            var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),
                (int)Math.Ceiling(window.ActualHeight), 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
            // Mica belongs to the compositor, outside the WPF visual tree. Render the managed
            // content over the system window color for readable offscreen layout inspection.
            var background = new System.Windows.Media.DrawingVisual();
            using (var drawing = background.RenderOpen()) drawing.DrawRectangle(System.Windows.SystemColors.WindowBrush,
                null, new System.Windows.Rect(0, 0, window.ActualWidth, window.ActualHeight));
            bitmap.Render(background);
            bitmap.Render(window);
            var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
            encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
            Directory.CreateDirectory(directory);
            using var stream = File.Create(Path.Combine(directory, name));
            encoder.Save(stream);
        }));
    }

    internal static string? Scenario
    {
        get
        {
            var args = Environment.GetCommandLineArgs();
            var index = Array.IndexOf(args, "--ui-test-scenario");
            return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
        }
    }
}

internal sealed class UiTestSettings : ISettingsService
{
    public string? LoadIssue => null;
    public bool IncludeUnknownVersions { get; set; }
    public bool IsSourceEnabled(SourceId id) => true;
    public void SetSourceEnabled(SourceId id, bool enabled) { }
    public string? GetExecutableOverride(ToolId id) => null;
    public void SetExecutableOverride(ToolId id, string? path) { }
    public ToolContext? GetCachedContext(SourceId id) => null;
    public void SetCachedContext(SourceId id, ToolContext? context) { }
    public IReadOnlySet<string> GetIgnoredUpdates() => new HashSet<string>();
    public void SetUpdateIgnored(string key, bool ignored) { }
    public DateTimeOffset? GetLastAppUpdateCheck() => null;
    public void SetLastAppUpdateCheck(DateTimeOffset? checkedAt) { }
    public string? GetSkippedAppUpdateVersion() => null;
    public void SetSkippedAppUpdateVersion(string? version) { }
    public AppUpdateInfo? GetAvailableAppUpdate() => null;
    public void SetAvailableAppUpdate(AppUpdateInfo? update) { }
}

internal sealed class UiTestPackageSource(string scenario) : IPackageSource
{
    public SourceDescriptor Descriptor { get; } = new(SourceId.Npm, "npm", ToolId.Npm, "npm", []);
    public bool SupportsCacheClear => true;
    public Task<string> ClearCacheAsync(ToolContext context, IProgress<ProcessOutputEvent>? output = null,
        CancellationToken cancellationToken = default) => Task.FromResult("Synthetic cache cleared.");

    public Task<SourceProbe> ProbeAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(SourceProbe.Available(new ToolContext("C:\\ui-test\\npm.cmd", "npm 12.0.0",
            ToolResolutionOrigin.Custom, ["C:\\ui-test"])));

    public async Task<SourceScanReport> ScanAsync(ToolContext context, IProgress<SourcePhase>? progress = null,
        CancellationToken cancellationToken = default)
    {
        progress?.Report(SourcePhase.Scanning);
        await Task.Delay(scenario == "slowScan" ? 5000 : 100, cancellationToken);
        var updates = new[]
        {
            new PackageInfo("alpha", "Alpha Tool", "1.0.0", "2.0.0"),
            new PackageInfo("beta", "Beta Tool", "3.9.0", "3.10.0"),
        };
        return scenario switch
        {
            "initial" => SourceScanReport.Empty,
            "partial" => new([updates[0]], [new(SourceIssueKind.Network, "Registry lookup failed for one package.")]),
            _ => new(updates, []),
        };
    }

    public async Task<UpdateResult> UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        output?.Report(new(ProcessOutputStream.StandardOutput, $"Updating {request.Name}"));
        await Task.Delay(80, cancellationToken);
        if (scenario == "failedUpdate" && request.PackageId == "beta")
            throw new SourceException(SourceIssueKind.Command, "Synthetic update failure.");
        return new();
    }

    public Task<IReadOnlyDictionary<string, UpdateVerification>> VerifyAsync(IReadOnlyList<UpdateRequest> requests,
        ToolContext context, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyDictionary<string, UpdateVerification>>(
            requests.ToDictionary(r => r.PackageId, r => new UpdateVerification(true, r.TargetVersion)));
}

internal sealed class UiTestCacheInspector : ICacheInspector
{
    public Task<CachePreview> PreviewAsync(IPackageSource source, ToolContext context, CancellationToken cancellationToken) =>
        Task.FromResult(new CachePreview(CacheInspector.ScopeFor(source.Id), ["C:\\ui-test\\cache"], 2097152));
}
