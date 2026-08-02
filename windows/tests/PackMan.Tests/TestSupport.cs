using PackMan.Services;

namespace PackMan.Tests;

internal sealed class StubRunner : IProcessRunner
{
    private readonly Queue<ProcessResult> _results = new();
    public List<ProcessInvocation> Invocations { get; } = [];
    public void Enqueue(ProcessResult result) => _results.Enqueue(result);
    public Task<ProcessResult> RunAsync(ProcessInvocation invocation, IProgress<ProcessOutputEvent>? output = null,
        CancellationToken cancellationToken = default)
    {
        Invocations.Add(invocation);
        cancellationToken.ThrowIfCancellationRequested();
        var result = _results.Dequeue();
        foreach (var line in result.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            output?.Report(new(ProcessOutputStream.StandardOutput, line));
        foreach (var line in result.StdErr.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            output?.Report(new(ProcessOutputStream.StandardError, line));
        return Task.FromResult(result);
    }
}

internal sealed class StubResolver(ResolvedTool? tool = null) : IToolResolver
{
    private readonly ResolvedTool _tool = tool ?? new("C:\\tools\\tool.exe", ToolResolutionOrigin.Custom, ["C:\\tools"]);
    public Task<ToolResolution> ResolveAsync(SourceDescriptor descriptor, CancellationToken cancellationToken = default) =>
        Task.FromResult(new ToolResolution(_tool));
}

internal sealed class StubElevationBroker : IElevationBroker
{
    public Task<ProcessResult> RunAsync(ProcessInvocation invocation, IProgress<ProcessOutputEvent>? output,
        CancellationToken cancellationToken) => throw new NotSupportedException();
}

internal sealed class MemorySettings : ISettingsService
{
    private readonly HashSet<SourceId> _disabled = [];
    private readonly Dictionary<ToolId, string> _overrides = [];
    public string? LoadIssue => null;
    public bool IsSourceEnabled(SourceId id) => !_disabled.Contains(id);
    public void SetSourceEnabled(SourceId id, bool enabled) { if (enabled) _disabled.Remove(id); else _disabled.Add(id); }
    public string? GetExecutableOverride(ToolId id) => _overrides.GetValueOrDefault(id);
    public void SetExecutableOverride(ToolId id, string? path)
    {
        if (path is null) _overrides.Remove(id); else _overrides[id] = path;
    }
}

internal sealed class StubSource(
    SourceId id,
    SourceScanReport report,
    Func<UpdateRequest, Task>? update = null,
    Func<IReadOnlyList<UpdateRequest>, Task<IReadOnlyDictionary<string, UpdateVerification>>>? verify = null,
    Func<Task<SourceProbe>>? probe = null) : IPackageSource
{
    public SourceDescriptor Descriptor { get; } = new(id, id.ToString(), ToolId.Npm, "stub", []);
    public Task<SourceProbe> ProbeAsync(CancellationToken cancellationToken = default) => probe?.Invoke()
        ?? Task.FromResult(SourceProbe.Available(new ToolContext("stub", "1", ToolResolutionOrigin.Custom, [])));
    public Task<SourceScanReport> ScanAsync(ToolContext context, IProgress<SourcePhase>? progress = null,
        CancellationToken cancellationToken = default) => Task.FromResult(report);
    public Task UpdateAsync(UpdateRequest request, ToolContext context, IProgress<ProcessOutputEvent>? output = null,
        CancellationToken cancellationToken = default) => update?.Invoke(request) ?? Task.CompletedTask;
    public Task<IReadOnlyDictionary<string, UpdateVerification>> VerifyAsync(IReadOnlyList<UpdateRequest> requests,
        ToolContext context, CancellationToken cancellationToken = default) => verify?.Invoke(requests)
        ?? Task.FromResult<IReadOnlyDictionary<string, UpdateVerification>>(
            requests.ToDictionary(r => r.PackageId, r => new UpdateVerification(true, r.TargetVersion)));
}
