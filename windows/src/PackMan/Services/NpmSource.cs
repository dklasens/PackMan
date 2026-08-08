using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace PackMan.Services;

public sealed class NpmSource(IToolResolver resolver, IProcessRunner runner) : PackageSourceBase(resolver, runner)
{
    public override SourceDescriptor Descriptor { get; } = new(
        SourceId.Npm, "npm", ToolId.Npm, "npm",
        [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "nodejs", "npm.cmd")],
        "https://nodejs.org/en/download");

    public override async Task<SourceProbe> ProbeAsync(CancellationToken cancellationToken = default)
    {
        var npmProbe = await base.ProbeAsync(cancellationToken);
        if (!npmProbe.IsAvailable) return npmProbe;
        var nodeDescriptor = new SourceDescriptor(SourceId.Npm, "Node.js", ToolId.Node, "node",
            [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "nodejs", "node.exe")]);
        var adjacentNode = Path.Combine(Path.GetDirectoryName(npmProbe.Context!.ExecutablePath)!, "node.exe");
        var node = File.Exists(adjacentNode)
            ? new ToolResolution(new ResolvedTool(adjacentNode, npmProbe.Context.Origin, [Path.GetDirectoryName(adjacentNode)!]))
            : await Resolver.ResolveAsync(nodeDescriptor, cancellationToken);
        if (node.Tool is null)
            return SourceProbe.Unavailable(new SourceIssue(SourceIssueKind.Configuration,
                $"npm was found at {npmProbe.Context!.ExecutablePath}, but its Node.js runtime was not found.",
                "Choose a complete Node.js installation in Sources or add node.exe to PATH."));
        var entries = npmProbe.Context!.PathEntries.Concat(node.Tool.PathEntries)
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        var nodeResult = await Runner.RunAsync(new ProcessInvocation(node.Tool.Path, ["--version"],
            BuildEnvironment(entries), TimeSpan.FromSeconds(15)), cancellationToken: cancellationToken);
        if (!nodeResult.Success)
            return SourceProbe.Unavailable(new SourceIssue(SourceIssueKind.Configuration,
                $"The Node.js runtime for npm could not be started: {SourceSupport.ErrorText(nodeResult)}"));
        return SourceProbe.Available(npmProbe.Context with { PathEntries = entries });
    }

    public override async Task<SourceScanReport> ScanAsync(ToolContext context,
        IProgress<SourcePhase>? progress = null, CancellationToken cancellationToken = default)
    {
        progress?.Report(SourcePhase.Scanning);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "outdated", "-g", "--json"), context.Environment, TimeSpan.FromMinutes(3)),
            cancellationToken: cancellationToken);
        if (result.ExitCode is not (0 or 1))
        {
            if (await IsMissingGlobalPrefixAsync(result, context, cancellationToken))
                return SourceScanReport.Empty;
            throw SourceSupport.CommandFailure("npm outdated", result);
        }
        if (string.IsNullOrWhiteSpace(result.StdOut)) return SourceScanReport.Empty;
        Dictionary<string, NpmEntry> entries;
        try { entries = JsonSerializer.Deserialize<Dictionary<string, NpmEntry>>(result.StdOut) ?? []; }
        catch (JsonException ex) { throw new SourceException(SourceIssueKind.Parsing, $"npm JSON could not be parsed: {ex.Message}"); }
        var updates = new List<PackageInfo>();
        var issues = new List<SourceIssue>();
        foreach (var (id, entry) in entries)
        {
            if (!PackageIdValidator.IsValid(id)) { issues.Add(new(SourceIssueKind.Parsing, "npm returned an invalid package identifier.")); continue; }
            if (string.IsNullOrWhiteSpace(entry.Latest)) { issues.Add(new(SourceIssueKind.Parsing, $"{id}: npm did not return a latest version.")); continue; }
            updates.Add(new(id, id, entry.Current ?? string.Empty, entry.Latest));
        }
        return new(updates, issues);
    }

    public override bool SupportsCacheClear => true;

    public override async Task<string> ClearCacheAsync(ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "cache", "clean", "--force"), context.Environment, TimeSpan.FromMinutes(2)),
            output, cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("npm cache clean", result);
        return "Cleared the npm cache.";
    }

    public override async Task UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        Validate(request);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "install", "-g", $"{request.PackageId}@{request.TargetVersion}"),
            context.Environment, TimeSpan.FromMinutes(15), request.Elevated), output, cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("npm install", result);
    }

    private static readonly Regex ErrorPathPattern = new(
        // ProcessRunner rebuilds output with Environment.NewLine, so lines end \r\n on real
        // runs even when the tool itself emitted \n. Tolerate the \r before the end anchor.
        @"(?im)^npm (?:error|err!) path (?<path>[^\r\n]+?)\r?$", RegexOptions.Compiled);

    private async Task<bool> IsMissingGlobalPrefixAsync(ProcessResult failure, ToolContext context,
        CancellationToken cancellationToken)
    {
        var error = $"{failure.StdOut}\n{failure.StdErr}";
        if (failure.ExitCode != -4058
            || !error.Contains("ENOENT", StringComparison.OrdinalIgnoreCase)
            || !error.Contains("lstat", StringComparison.OrdinalIgnoreCase)) return false;

        var pathMatch = ErrorPathPattern.Match(error);
        if (!pathMatch.Success) return false;

        var prefixResult = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "prefix", "-g"), context.Environment, TimeSpan.FromSeconds(30)),
            cancellationToken: cancellationToken);
        if (!prefixResult.Success) return false;

        var prefix = prefixResult.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .LastOrDefault()?.Trim();
        var missingPath = pathMatch.Groups["path"].Value.Trim();
        if (string.IsNullOrWhiteSpace(prefix)) return false;
        try
        {
            var normalizedPrefix = Path.TrimEndingDirectorySeparator(Path.GetFullPath(prefix));
            var normalizedMissing = Path.TrimEndingDirectorySeparator(Path.GetFullPath(missingPath));
            return string.Equals(normalizedPrefix, normalizedMissing, StringComparison.OrdinalIgnoreCase)
                && !Directory.Exists(normalizedPrefix);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    private sealed class NpmEntry
    {
        [JsonPropertyName("current")] public string? Current { get; set; }
        [JsonPropertyName("latest")] public string? Latest { get; set; }
    }
}
