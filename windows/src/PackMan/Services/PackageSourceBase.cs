namespace PackMan.Services;

public abstract class PackageSourceBase(IToolResolver resolver, IProcessRunner runner) : IPackageSource
{
    protected IToolResolver Resolver { get; } = resolver;
    protected IProcessRunner Runner { get; } = runner;
    public abstract SourceDescriptor Descriptor { get; }
    public SourceId Id => Descriptor.Id;
    public string Name => Descriptor.Name;
    public virtual bool SupportsCacheClear => false;
    protected virtual IReadOnlyList<string> VersionArguments => ["--version"];

    public virtual async Task<SourceProbe> ProbeAsync(CancellationToken cancellationToken = default)
    {
        var resolution = await Resolver.ResolveAsync(Descriptor, cancellationToken);
        if (resolution.Tool is null)
            return SourceProbe.Unavailable(resolution.Issue ?? new SourceIssue(
                SourceIssueKind.Unavailable, $"{Descriptor.ExecutableName} was not found.",
                Descriptor.InstallationUrl is null ? null : "Install it or choose its executable in Sources."));
        try
        {
            var args = (resolution.Tool.PrefixArguments ?? []).Concat(VersionArguments).ToArray();
            var result = await Runner.RunAsync(new ProcessInvocation(
                resolution.Tool.Path, args, BuildEnvironment(resolution.Tool.PathEntries), TimeSpan.FromSeconds(15)),
                cancellationToken: cancellationToken);
            if (!result.Success)
                return SourceProbe.Unavailable(new SourceIssue(SourceIssueKind.Configuration,
                    $"{Name} was found but could not be used: {SourceSupport.ErrorText(result)}",
                    "Check the executable and its runtime dependencies."));
            var version = result.StdOut.Trim();
            if (string.IsNullOrWhiteSpace(version)) version = result.StdErr.Trim();
            return SourceProbe.Available(new ToolContext(
                resolution.Tool.Path,
                version.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim() ?? "Available",
                resolution.Tool.Origin, resolution.Tool.PathEntries, resolution.Tool.PrefixArguments));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return SourceProbe.Unavailable(new SourceIssue(SourceIssueKind.Configuration,
                $"{Name} could not be started: {ex.Message}", "Review its executable in Sources."));
        }
    }

    public abstract Task<SourceScanReport> ScanAsync(ToolContext context, IProgress<SourcePhase>? progress = null,
        CancellationToken cancellationToken = default);
    public abstract Task UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default);

    public virtual Task<string> ClearCacheAsync(ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default) =>
        throw new NotSupportedException($"{Name} has no cache to clear.");

    public virtual async Task<IReadOnlyDictionary<string, UpdateVerification>> VerifyAsync(
        IReadOnlyList<UpdateRequest> requests, ToolContext context, CancellationToken cancellationToken = default)
    {
        var report = await ScanAsync(context, null, cancellationToken);
        if (report.Issues.Count > 0)
            throw new SourceException(SourceIssueKind.Verification,
                string.Join("; ", report.Issues.Select(i => i.Message)));
        var outstanding = report.Updates.ToDictionary(p => p.Id, StringComparer.OrdinalIgnoreCase);
        return requests.ToDictionary(
            r => r.PackageId,
            r => outstanding.TryGetValue(r.PackageId, out var package)
                ? new UpdateVerification(false, StillOutdated: package)
                : new UpdateVerification(true, r.TargetVersion),
            StringComparer.OrdinalIgnoreCase);
    }

    protected IReadOnlyList<string> Arguments(ToolContext context, params string[] arguments) =>
        (context.PrefixArguments ?? []).Concat(arguments).ToArray();

    protected static IReadOnlyDictionary<string, string> BuildEnvironment(IReadOnlyList<string> entries)
    {
        var inherited = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["PATH"] = string.Join(Path.PathSeparator, entries.Distinct(StringComparer.OrdinalIgnoreCase))
                + Path.PathSeparator + inherited,
        };
    }

    protected static void Validate(UpdateRequest request)
    {
        if (!PackageIdValidator.IsValid(request.PackageId))
            throw new SourceException(SourceIssueKind.Configuration,
                $"Refusing to update invalid package id '{request.PackageId}'.");
        if (!PackageIdValidator.IsValidVersion(request.TargetVersion))
            throw new SourceException(SourceIssueKind.Configuration,
                $"Refusing to use invalid target version '{request.TargetVersion}'.");
    }
}

public sealed class SourceException(SourceIssueKind kind, string message, bool canRetryElevated = false)
    : Exception(message)
{
    public SourceIssueKind Kind { get; } = kind;
    public bool CanRetryElevated { get; } = canRetryElevated;
}

public sealed class PackageUpdateCanceledException(string message) : Exception(message);

public sealed class ElevationDeclinedException()
    : Exception("Administrator approval was declined; the update did not run.");
