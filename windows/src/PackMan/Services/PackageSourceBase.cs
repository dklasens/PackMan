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
    public abstract Task<UpdateResult> UpdateAsync(UpdateRequest request, ToolContext context,
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
        return requests.ToDictionary(
            r => r.Identity,
            r => report.Updates.FirstOrDefault(p => p.Id.Equals(r.PackageId, StringComparison.OrdinalIgnoreCase)
                && (r.Repository is null || string.Equals(p.Repository, r.Repository, StringComparison.OrdinalIgnoreCase))) is { } package
                ? new UpdateVerification(false, package.CurrentVersion, package,
                    "The source still reports an available update.")
                : new UpdateVerification(true, Evidence:
                    "No longer reported as outdated by the source. Installed version was not independently confirmed."),
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
        if (request.Repository is not null && !PackageIdValidator.IsValid(request.Repository))
            throw new SourceException(SourceIssueKind.Configuration, "The repository identity is invalid.");
    }

    protected static UpdateVerification VerifyInstalled(string? installed, UpdateRequest request)
    {
        var satisfied = installed is not null && (string.Equals(installed, request.TargetVersion,
            StringComparison.OrdinalIgnoreCase) || SemanticVersion.Compare(installed, request.TargetVersion) is >= 0);
        var outdated = installed is not null && SemanticVersion.Compare(installed, request.TargetVersion) is < 0
            ? new PackageInfo(request.PackageId, request.Name, installed, request.TargetVersion, Repository: request.Repository)
            : null;
        return new(satisfied, installed, outdated, Evidence: installed is null
            ? "The package was not found in the installed inventory."
            : $"Installed inventory reports {installed}; requested {request.TargetVersion}.");
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
