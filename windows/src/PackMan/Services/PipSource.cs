using System.Text.Json;
using System.Text.Json.Serialization;

namespace PackMan.Services;

public sealed class PipSource(IToolResolver resolver, IProcessRunner runner) : PackageSourceBase(resolver, runner)
{
    public override SourceDescriptor Descriptor { get; } = new(
        SourceId.Pip, "pip", ToolId.Python, "py",
        [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "py.exe")],
        "https://www.python.org/downloads/windows/");

    public override async Task<SourceProbe> ProbeAsync(CancellationToken cancellationToken = default)
    {
        var resolution = await Resolver.ResolveAsync(Descriptor, cancellationToken);
        if (resolution.Tool is null)
            resolution = await Resolver.ResolveAsync(Descriptor with { ExecutableName = "python", KnownPaths = PythonPaths() }, cancellationToken);
        if (resolution.Tool is null)
            return SourceProbe.Unavailable(resolution.Issue ?? new(SourceIssueKind.Unavailable, "Python with pip was not found."));
        var prefix = Path.GetFileNameWithoutExtension(resolution.Tool.Path).Equals("py", StringComparison.OrdinalIgnoreCase)
            ? new[] { "-3", "-m", "pip" } : new[] { "-m", "pip" };
        var result = await Runner.RunAsync(new ProcessInvocation(resolution.Tool.Path,
            prefix.Concat(["--version"]).ToArray(), BuildEnvironment(resolution.Tool.PathEntries), TimeSpan.FromSeconds(15)),
            cancellationToken: cancellationToken);
        if (!result.Success)
            return SourceProbe.Unavailable(new SourceIssue(SourceIssueKind.Configuration,
                $"Python was found but pip could not be used: {SourceSupport.ErrorText(result)}",
                "Install pip for this Python interpreter or choose another interpreter."));
        return SourceProbe.Available(new ToolContext(resolution.Tool.Path, result.StdOut.Trim(), resolution.Tool.Origin,
            resolution.Tool.PathEntries, prefix));
    }

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

    public override async Task UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        Validate(request);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "install", "--upgrade", $"{request.PackageId}=={request.TargetVersion}"),
            context.Environment, TimeSpan.FromMinutes(15), request.Elevated), output, cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("pip install", result);
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
}
