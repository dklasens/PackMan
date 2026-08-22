using System.Net;
using System.Net.Http;
using PackMan.Services;

namespace PackMan.Tests;

internal sealed class StubRunner : IProcessRunner
{
    private readonly Queue<object> _results = new();
    public List<ProcessInvocation> Invocations { get; } = [];
    public void Enqueue(ProcessResult result) => _results.Enqueue(result);
    public void EnqueueException(Exception exception) => _results.Enqueue(exception);
    public Task<ProcessResult> RunAsync(ProcessInvocation invocation, IProgress<ProcessOutputEvent>? output = null,
        CancellationToken cancellationToken = default)
    {
        Invocations.Add(invocation);
        cancellationToken.ThrowIfCancellationRequested();
        var outcome = _results.Dequeue();
        if (outcome is Exception exception) throw exception;
        var result = (ProcessResult)outcome;
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

internal sealed class DescriptorResolver(Func<SourceDescriptor, ResolvedTool?> resolve) : IToolResolver
{
    public Task<ToolResolution> ResolveAsync(SourceDescriptor descriptor, CancellationToken cancellationToken = default) =>
        Task.FromResult(new ToolResolution(resolve(descriptor)));
}

internal sealed class StubElevationBroker : IElevationBroker
{
    public Task<ProcessResult> RunAsync(ProcessInvocation invocation, IProgress<ProcessOutputEvent>? output,
        CancellationToken cancellationToken) => throw new NotSupportedException();
}

internal sealed class StubHttpHandler(Func<Uri, HttpResponseMessage> responder) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
        Task.FromResult(responder(request.RequestUri!));

    public static HttpClient JsonClient(string json) => new(new StubHttpHandler(_ =>
        new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json, System.Text.Encoding.UTF8) }));
}

internal sealed class MemorySettings : ISettingsService
{
    private readonly HashSet<SourceId> _disabled = [];
    private readonly Dictionary<ToolId, string> _overrides = [];
    private readonly Dictionary<SourceId, ToolContext> _contexts = [];
    private readonly HashSet<string> _ignored = new(StringComparer.OrdinalIgnoreCase);
    public string? LoadIssue => null;
    public bool IsSourceEnabled(SourceId id) => !_disabled.Contains(id);
    public void SetSourceEnabled(SourceId id, bool enabled) { if (enabled) _disabled.Remove(id); else _disabled.Add(id); }
    public string? GetExecutableOverride(ToolId id) => _overrides.GetValueOrDefault(id);
    public void SetExecutableOverride(ToolId id, string? path)
    {
        if (path is null) _overrides.Remove(id); else _overrides[id] = path;
    }
    public ToolContext? GetCachedContext(SourceId id) => _contexts.GetValueOrDefault(id);
    public void SetCachedContext(SourceId id, ToolContext? context)
    {
        if (context is null) _contexts.Remove(id); else _contexts[id] = context;
    }
    public IReadOnlySet<string> GetIgnoredUpdates() => _ignored;
    public void SetUpdateIgnored(string key, bool ignored) { if (ignored) _ignored.Add(key); else _ignored.Remove(key); }
    public DateTimeOffset? LastAppUpdateCheck { get; set; }
    public string? SkippedAppUpdateVersion { get; set; }
    public AppUpdateInfo? AvailableAppUpdate { get; set; }
    public DateTimeOffset? GetLastAppUpdateCheck() => LastAppUpdateCheck;
    public void SetLastAppUpdateCheck(DateTimeOffset? checkedAt) => LastAppUpdateCheck = checkedAt;
    public string? GetSkippedAppUpdateVersion() => SkippedAppUpdateVersion;
    public void SetSkippedAppUpdateVersion(string? version) => SkippedAppUpdateVersion = version;
    public AppUpdateInfo? GetAvailableAppUpdate() => AvailableAppUpdate;
    public void SetAvailableAppUpdate(AppUpdateInfo? update) => AvailableAppUpdate = update;
}

internal sealed class StubAppUpdateService(AppUpdateInfo? available = null,
    Func<AppUpdateInfo, Task>? apply = null) : IAppUpdateService
{
    public List<bool> Checks { get; } = [];
    public List<AppUpdateInfo> Applied { get; } = [];
    public Task<AppUpdateInfo?> CheckAsync(bool force = false, CancellationToken cancellationToken = default)
    {
        Checks.Add(force);
        return Task.FromResult(available);
    }
    public Task ApplyAsync(AppUpdateInfo update, IProgress<string>? progress, CancellationToken cancellationToken)
    {
        Applied.Add(update);
        return apply?.Invoke(update) ?? Task.CompletedTask;
    }
}

internal sealed class StubSourceInstaller : ISourceInstaller
{
    private readonly Func<SourceId, SourceInstallPlan?>? _plan;
    private readonly Func<SourceInstallPlan, Task>? _install;
    public StubSourceInstaller(Func<SourceId, SourceInstallPlan?>? plan = null,
        Func<SourceInstallPlan, Task>? install = null)
    {
        _plan = plan;
        _install = install;
    }
    public List<SourceInstallPlan> Installed { get; } = [];
    public bool HasPlan(SourceId id) => true;
    public Task<SourceInstallPlan?> BuildPlanAsync(SourceId id, CancellationToken cancellationToken = default) =>
        Task.FromResult(_plan?.Invoke(id));
    public Task InstallAsync(SourceInstallPlan plan, IProgress<ProcessOutputEvent>? output,
        CancellationToken cancellationToken)
    {
        Installed.Add(plan);
        return _install?.Invoke(plan) ?? Task.CompletedTask;
    }
}

internal sealed class StubSource(
    SourceId id,
    SourceScanReport report,
    Func<UpdateRequest, Task>? update = null,
    Func<IReadOnlyList<UpdateRequest>, Task<IReadOnlyDictionary<string, UpdateVerification>>>? verify = null,
    Func<Task<SourceProbe>>? probe = null,
    Func<ToolContext, Task<string>>? clearCache = null) : IPackageSource
{
    public SourceDescriptor Descriptor { get; } = new(id, id.ToString(), ToolId.Npm, "stub", []);
    public bool SupportsCacheClear => clearCache is not null;
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
    public Task<string> ClearCacheAsync(ToolContext context, IProgress<ProcessOutputEvent>? output = null,
        CancellationToken cancellationToken = default) => clearCache?.Invoke(context)
        ?? throw new NotSupportedException();
}
