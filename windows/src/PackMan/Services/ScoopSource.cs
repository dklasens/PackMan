using System.Text.RegularExpressions;

namespace PackMan.Services;

public sealed class ScoopSource(IToolResolver resolver, IProcessRunner runner) : PackageSourceBase(resolver, runner)
{
    public override SourceDescriptor Descriptor { get; } = new(
        SourceId.Scoop, "Scoop", ToolId.Scoop, "scoop",
        [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "scoop", "shims", "scoop.cmd")],
        "https://scoop.sh/");

    public override async Task<SourceProbe> ProbeAsync(CancellationToken cancellationToken = default)
    {
        var probe = await base.ProbeAsync(cancellationToken);
        if (probe.IsAvailable || probe.Issue?.Kind is SourceIssueKind.Unavailable) return probe;
        // Older scoop builds reject --version; `scoop help` is always available.
        var resolution = await Resolver.ResolveAsync(Descriptor, cancellationToken);
        if (resolution.Tool is null) return probe;
        try
        {
            var result = await Runner.RunAsync(new ProcessInvocation(resolution.Tool.Path,
                (resolution.Tool.PrefixArguments ?? []).Append("help").ToArray(),
                BuildEnvironment(resolution.Tool.PathEntries), TimeSpan.FromSeconds(15)),
                cancellationToken: cancellationToken);
            return result.Success
                ? SourceProbe.Available(new ToolContext(resolution.Tool.Path, "Available",
                    resolution.Tool.Origin, resolution.Tool.PathEntries, resolution.Tool.PrefixArguments))
                : probe;
        }
        catch (Exception ex) when (ex is not OperationCanceledException) { return probe; }
    }

    public override async Task<SourceScanReport> ScanAsync(ToolContext context,
        IProgress<SourcePhase>? progress = null, CancellationToken cancellationToken = default)
    {
        progress?.Report(SourcePhase.Scanning);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "status"), context.Environment, TimeSpan.FromMinutes(5)), cancellationToken: cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("scoop status", result);
        var parsed = ScoopStatusParser.Parse(result.StdOut);
        return new(parsed.Updates, parsed.Issues);
    }

    public override async Task UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        Validate(request);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "update", request.PackageId), context.Environment, TimeSpan.FromMinutes(15), request.Elevated),
            output, cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("scoop update", result);
    }
}

public static class ScoopStatusParser
{
    public sealed record ParseResult(IReadOnlyList<PackageInfo> Updates, IReadOnlyList<SourceIssue> Issues);

    public static ParseResult Parse(string output)
    {
        var updates = new List<PackageInfo>();
        var issues = new List<SourceIssue>();
        var inTable = false;
        foreach (var raw in output.Split('\n'))
        {
            var line = Regex.Replace(raw.TrimEnd('\r'), @"\x1B\[[0-9;?]*[A-Za-z]", string.Empty).Trim();
            if (string.IsNullOrWhiteSpace(line)) continue;
            if (line.StartsWith("Name", StringComparison.OrdinalIgnoreCase)
                && line.Contains("Version", StringComparison.OrdinalIgnoreCase)) { inTable = true; continue; }
            if (line.All(c => c is '-' or ' ')) continue;
            if (!inTable) continue;
            var parts = Regex.Split(line, @"\s{2,}").Where(x => !string.IsNullOrWhiteSpace(x)).ToArray();
            if (parts.Length < 3 || !PackageIdValidator.IsValid(parts[0]))
            {
                issues.Add(new(SourceIssueKind.Parsing, "Scoop returned a package record that could not be parsed."));
                continue;
            }
            var info = parts.Length > 3 ? string.Join(" ", parts.Skip(3)) : string.Empty;
            if (info.Contains("hold", StringComparison.OrdinalIgnoreCase)) continue;
            updates.Add(new(parts[0], parts[0], parts[1], parts[2]));
        }
        return new(updates, issues.DistinctBy(i => i.Id).ToList());
    }
}
