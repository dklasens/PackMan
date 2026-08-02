namespace PackMan.Services;

public enum SourceId { Winget, Chocolatey, Scoop, Npm, Pip, Pipx }
public enum ToolId { Winget, Chocolatey, Scoop, Npm, Node, Python, Pip, Pipx }
public enum ToolResolutionOrigin { Custom, Path, KnownLocation, UserLocation, VersionManager }
public enum SourceIssueKind { Unavailable, Command, Parsing, Network, Configuration, Verification }
public enum SourcePhase { Probing, Refreshing, Scanning, Verifying }

public sealed record SourceDescriptor(
    SourceId Id,
    string Name,
    ToolId ToolId,
    string ExecutableName,
    IReadOnlyList<string> KnownPaths,
    string? InstallationUrl = null);

public sealed record ResolvedTool(
    string Path,
    ToolResolutionOrigin Origin,
    IReadOnlyList<string> PathEntries,
    IReadOnlyList<string>? PrefixArguments = null);

public sealed record ToolContext(
    string ExecutablePath,
    string Version,
    ToolResolutionOrigin Origin,
    IReadOnlyList<string> PathEntries,
    IReadOnlyList<string>? PrefixArguments = null)
{
    public IReadOnlyDictionary<string, string> Environment
    {
        get
        {
            var inherited = System.Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
            var path = string.Join(Path.PathSeparator, PathEntries.Where(p => !string.IsNullOrWhiteSpace(p)).Distinct(StringComparer.OrdinalIgnoreCase));
            return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["PATH"] = string.IsNullOrEmpty(path) ? inherited : $"{path}{Path.PathSeparator}{inherited}",
            };
        }
    }
}

public sealed record SourceIssue(SourceIssueKind Kind, string Message, string? Recovery = null)
{
    public string Id => $"{Kind}:{Message}";
}

public sealed record SourceProbe(ToolContext? Context, SourceIssue? Issue)
{
    public bool IsAvailable => Context is not null;
    public static SourceProbe Available(ToolContext context) => new(context, null);
    public static SourceProbe Unavailable(SourceIssue issue) => new(null, issue);
}

public sealed record PackageInfo(
    string Id,
    string Name,
    string CurrentVersion,
    string AvailableVersion,
    string? StatusMessage = null);

public sealed record SourceScanReport(
    IReadOnlyList<PackageInfo> Updates,
    IReadOnlyList<SourceIssue> Issues)
{
    public static SourceScanReport Empty { get; } = new([], []);
}

public sealed record UpdateRequest(string PackageId, string Name, string TargetVersion, bool Elevated = false);
public sealed record UpdateVerification(bool IsSatisfied, string? InstalledVersion = null, PackageInfo? StillOutdated = null);

public interface IPackageSource
{
    SourceDescriptor Descriptor { get; }
    SourceId Id => Descriptor.Id;
    string Name => Descriptor.Name;
    Task<SourceProbe> ProbeAsync(CancellationToken cancellationToken = default);
    Task<SourceScanReport> ScanAsync(ToolContext context, IProgress<SourcePhase>? progress = null,
        CancellationToken cancellationToken = default);
    Task UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default);
    Task<IReadOnlyDictionary<string, UpdateVerification>> VerifyAsync(
        IReadOnlyList<UpdateRequest> requests, ToolContext context, CancellationToken cancellationToken = default);
}
