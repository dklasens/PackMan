namespace PackMan.Services;

internal static class UiTestEnvironment
{
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
    public bool IsSourceEnabled(SourceId id) => true;
    public void SetSourceEnabled(SourceId id, bool enabled) { }
    public string? GetExecutableOverride(ToolId id) => null;
    public void SetExecutableOverride(ToolId id, string? path) { }
}

internal sealed class UiTestPackageSource(string scenario) : IPackageSource
{
    public SourceDescriptor Descriptor { get; } = new(SourceId.Npm, "npm", ToolId.Npm, "npm", []);

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

    public async Task UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        output?.Report(new(ProcessOutputStream.StandardOutput, $"Updating {request.Name}"));
        await Task.Delay(80, cancellationToken);
        if (scenario == "failedUpdate" && request.PackageId == "beta")
            throw new SourceException(SourceIssueKind.Command, "Synthetic update failure.");
    }

    public Task<IReadOnlyDictionary<string, UpdateVerification>> VerifyAsync(IReadOnlyList<UpdateRequest> requests,
        ToolContext context, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyDictionary<string, UpdateVerification>>(
            requests.ToDictionary(r => r.PackageId, r => new UpdateVerification(true, r.TargetVersion)));
}
