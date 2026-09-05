using System.Text.Json;
using System.Text.Json.Serialization;

namespace PackMan.Services;

public sealed class PipSource(IToolResolver resolver, IProcessRunner runner) : PackageSourceBase(resolver, runner)
{
    private const string FindDependentsScript = """
        import importlib.metadata as metadata
        import json
        import re
        import sys

        normalize = lambda value: re.sub(r"[-_.]+", "-", value).lower()
        target = normalize(sys.argv[1])
        dependents = {}
        for distribution in metadata.distributions():
            name = distribution.metadata.get("Name")
            version = distribution.version
            if not name or not version or normalize(name) == target:
                continue
            for requirement in distribution.requires or ():
                match = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", requirement)
                if match and normalize(match.group(1)) == target:
                    dependents.setdefault(normalize(name), {"name": name, "version": version})
                    break
        print(json.dumps(list(dependents.values()), ensure_ascii=True))
        """;

    public override SourceDescriptor Descriptor { get; } = new(
        SourceId.Pip, "pip", ToolId.Python, "py",
        [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "py.exe")],
        "https://www.python.org/downloads/windows/");

    public override async Task<SourceProbe> ProbeAsync(CancellationToken cancellationToken = default)
    {
        var candidates = new List<ResolvedTool>();
        var pyResolution = await Resolver.ResolveAsync(Descriptor, cancellationToken);
        if (pyResolution.Tool is not null) candidates.Add(pyResolution.Tool);
        var pythonResolution = await Resolver.ResolveAsync(
            Descriptor with { ExecutableName = "python", KnownPaths = PythonPaths() }, cancellationToken);
        if (pythonResolution.Tool is not null
            && !candidates.Any(c => SameExecutable(c, pythonResolution.Tool))) candidates.Add(pythonResolution.Tool);
        foreach (var path in PythonPaths())
        {
            var tool = new ResolvedTool(path, ToolResolutionOrigin.KnownLocation, [Path.GetDirectoryName(path)!]);
            if (!candidates.Any(c => SameExecutable(c, tool))) candidates.Add(tool);
        }
        if (candidates.Count == 0)
            return SourceProbe.Unavailable(pyResolution.Issue ?? pythonResolution.Issue
                ?? new(SourceIssueKind.Unavailable, "Python with pip was not found."));

        // A candidate can be a non-functional Microsoft Store alias stub, so keep trying the
        // remaining interpreters before declaring the source unavailable.
        SourceIssue? lastIssue = null;
        foreach (var tool in candidates)
        {
            var prefix = Path.GetFileNameWithoutExtension(tool.Path).Equals("py", StringComparison.OrdinalIgnoreCase)
                ? new[] { "-3", "-m", "pip" } : new[] { "-m", "pip" };
            ProcessResult result;
            try
            {
                result = await Runner.RunAsync(new ProcessInvocation(tool.Path,
                    prefix.Concat(["--version"]).ToArray(), BuildEnvironment(tool.PathEntries), TimeSpan.FromSeconds(15)),
                    cancellationToken: cancellationToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                lastIssue = new SourceIssue(SourceIssueKind.Configuration,
                    $"Python at {tool.Path} could not be started: {ex.Message}",
                    "Review the interpreter in Sources.");
                continue;
            }
            if (result.Success)
                return SourceProbe.Available(new ToolContext(tool.Path, result.StdOut.Trim(),
                    tool.Origin, tool.PathEntries, prefix));
            lastIssue = new SourceIssue(SourceIssueKind.Configuration,
                $"Python was found but pip could not be used: {SourceSupport.ErrorText(result)}",
                "Install pip for this Python interpreter or choose another interpreter.");
        }
        return SourceProbe.Unavailable(lastIssue!);
    }

    private static bool SameExecutable(ResolvedTool left, ResolvedTool right) =>
        string.Equals(Path.GetFullPath(left.Path), Path.GetFullPath(right.Path), StringComparison.OrdinalIgnoreCase);

    public override async Task<SourceScanReport> ScanAsync(ToolContext context,
        IProgress<SourcePhase>? progress = null, CancellationToken cancellationToken = default)
    {
        progress?.Report(SourcePhase.Scanning);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "list", "--outdated", "--format", "json", "--disable-pip-version-check"),
            context.Environment, TimeSpan.FromMinutes(3)), cancellationToken: cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("pip list", result);
        List<PipEntry> entries;
        try { entries = string.IsNullOrWhiteSpace(result.StdOut) ? [] : JsonSerializer.Deserialize<List<PipEntry>>(result.StdOut) ?? []; }
        catch (JsonException ex) { throw new SourceException(SourceIssueKind.Parsing, $"pip JSON could not be parsed: {ex.Message}"); }
        var invalid = entries.Count(e => !PackageIdValidator.IsValid(e.Name));
        var issues = invalid == 0 ? [] : new[] { new SourceIssue(SourceIssueKind.Parsing, $"pip returned {invalid} invalid package record(s).") };
        return new(entries.Where(e => PackageIdValidator.IsValid(e.Name))
            .Select(e => new PackageInfo(e.Name!, e.Name!, e.Version ?? string.Empty, e.LatestVersion ?? string.Empty)).ToList(), issues);
    }

    public override bool SupportsCacheClear => true;

    public override async Task<IReadOnlyDictionary<string, UpdateVerification>> VerifyAsync(
        IReadOnlyList<UpdateRequest> requests, ToolContext context, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "list", "--format", "json", "--disable-pip-version-check"), context.Environment,
            TimeSpan.FromMinutes(2)), cancellationToken: cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("pip installed inventory", result);
        try
        {
            var installed = JsonSerializer.Deserialize<List<PipEntry>>(result.StdOut)
                ?? throw new JsonException("No installed inventory was returned.");
            return requests.ToDictionary(r => r.Identity, r => VerifyInstalled(installed.FirstOrDefault(p =>
                NormalizeName(p.Name) == NormalizeName(r.PackageId))?.Version, r), StringComparer.OrdinalIgnoreCase);
        }
        catch (JsonException ex) { throw new SourceException(SourceIssueKind.Verification, $"pip inventory could not be read: {ex.Message}"); }
    }

    private static string NormalizeName(string? name) =>
        System.Text.RegularExpressions.Regex.Replace(name ?? "", "[-_.]+", "-").ToLowerInvariant();

    public override async Task<string> ClearCacheAsync(ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "cache", "purge"), context.Environment, TimeSpan.FromMinutes(2)),
            output, cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("pip cache purge", result);
        return "Cleared the pip download cache.";
    }

    public override async Task<UpdateResult> UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        Validate(request);
        var dependents = await FindInstalledDependentsAsync(request.PackageId, context, cancellationToken);
        var requirements = new[] { $"{request.PackageId}=={request.TargetVersion}" }
            .Concat(dependents.Select(item => $"{item.Name}=={item.Version}"))
            .ToArray();
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, ["install", "--upgrade", .. requirements]),
            context.Environment, TimeSpan.FromMinutes(15), request.Elevated), output, cancellationToken);
        if (!result.Success && result.StdErr.Contains("ResolutionImpossible", StringComparison.OrdinalIgnoreCase)
            && dependents.Count > 0)
        {
            var names = string.Join(", ", dependents.Select(item => $"{item.Name} {item.Version}"));
            throw new SourceException(SourceIssueKind.Command,
                $"pip blocked {request.PackageId} {request.TargetVersion} because it conflicts with " +
                $"installed dependent package(s): {names}. No packages were changed; review the command log for the constraints.");
        }
        if (!result.Success) throw SourceSupport.CommandFailure("pip install", result);
        return new();
    }

    private async Task<IReadOnlyList<PipDependent>> FindInstalledDependentsAsync(string packageId,
        ToolContext context, CancellationToken cancellationToken)
    {
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            PythonArguments(context, "-c", FindDependentsScript, packageId),
            context.Environment, TimeSpan.FromSeconds(30)), cancellationToken: cancellationToken);
        if (!result.Success)
            throw new SourceException(SourceIssueKind.Command,
                $"Could not inspect installed pip dependencies, so the update was not attempted: {SourceSupport.ErrorText(result)}");
        try
        {
            var dependents = string.IsNullOrWhiteSpace(result.StdOut)
                ? []
                : JsonSerializer.Deserialize<List<PipDependent>>(result.StdOut) ?? [];
            if (dependents.Any(item => !PackageIdValidator.IsValid(item.Name)
                || !PackageIdValidator.IsValidVersion(item.Version)))
            {
                throw new SourceException(SourceIssueKind.Parsing,
                    "Installed pip dependency metadata contained an invalid name or version, so the update was not attempted.");
            }
            return dependents;
        }
        catch (JsonException ex)
        {
            throw new SourceException(SourceIssueKind.Parsing,
                $"Could not read installed pip dependencies, so the update was not attempted: {ex.Message}");
        }
    }

    private static IReadOnlyList<string> PythonArguments(ToolContext context, params string[] arguments)
    {
        var prefix = context.PrefixArguments ?? [];
        var pipModuleIndex = -1;
        for (var index = 0; index < prefix.Count - 1; index++)
        {
            if (prefix[index] == "-m" && prefix[index + 1].Equals("pip", StringComparison.OrdinalIgnoreCase))
            {
                pipModuleIndex = index;
                break;
            }
        }
        return prefix.Take(pipModuleIndex >= 0 ? pipModuleIndex : prefix.Count).Concat(arguments).ToArray();
    }

    private static string[] PythonPaths()
    {
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Python");
        if (!Directory.Exists(root)) return [];
        try
        {
            return Directory.EnumerateDirectories(root, "Python3*").OrderDescending()
            .Select(path => Path.Combine(path, "python.exe")).Where(File.Exists).ToArray();
        }
        catch { return []; }
    }

    private sealed class PipEntry
    {
        [JsonPropertyName("name")] public string? Name { get; set; }
        [JsonPropertyName("version")] public string? Version { get; set; }
        [JsonPropertyName("latest_version")] public string? LatestVersion { get; set; }
    }

    private sealed class PipDependent
    {
        [JsonPropertyName("name")] public required string Name { get; set; }
        [JsonPropertyName("version")] public required string Version { get; set; }
    }
}
