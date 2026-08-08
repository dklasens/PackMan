namespace PackMan.Services;

public sealed class ChocoSource : PackageSourceBase
{
    private readonly IReadOnlyList<string> _knownCacheLocations;

    public ChocoSource(IToolResolver resolver, IProcessRunner runner)
        : this(resolver, runner, DefaultCacheLocations()) { }

    internal ChocoSource(IToolResolver resolver, IProcessRunner runner,
        IReadOnlyList<string> knownCacheLocations) : base(resolver, runner)
    {
        _knownCacheLocations = knownCacheLocations;
    }

    public override SourceDescriptor Descriptor { get; } = new(
        SourceId.Chocolatey, "Chocolatey", ToolId.Chocolatey, "choco",
        [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "chocolatey", "bin", "choco.exe")], "https://chocolatey.org/install");

    public override async Task<SourceScanReport> ScanAsync(ToolContext context,
        IProgress<SourcePhase>? progress = null, CancellationToken cancellationToken = default)
    {
        progress?.Report(SourcePhase.Scanning);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "outdated", "-r", "--no-color"), context.Environment, TimeSpan.FromMinutes(5)),
            cancellationToken: cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("choco outdated", result);
        var updates = new List<PackageInfo>();
        var issues = new List<SourceIssue>();
        foreach (var line in result.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = line.Split('|');
            if (parts.Length < 4 || !PackageIdValidator.IsValid(parts[0]))
            {
                if (line.Contains('|')) issues.Add(new(SourceIssueKind.Parsing, "Chocolatey returned an invalid package record."));
                continue;
            }
            if (string.Equals(parts[3], "true", StringComparison.OrdinalIgnoreCase)) continue;
            updates.Add(new(parts[0], parts[0], parts[1], parts[2]));
        }
        return new(updates, issues.DistinctBy(i => i.Id).ToList());
    }

    public override bool SupportsCacheClear => true;

    public override async Task<string> ClearCacheAsync(ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        // Chocolatey can redirect downloads with cacheLocation, while HTTP metadata is cached
        // separately for the user and for elevated commands. Query in automation/elevated mode
        // because some installations pause non-admin commands for 30 seconds. Discovery is
        // best-effort: known caches must still be purged if Chocolatey itself is slow or broken.
        string? configuredLocation = null;
        string? discoveryIssue = null;
        try
        {
            var configured = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
                Arguments(context, "config", "get", "cacheLocation", "--limit-output", "--yes", "--no-progress"),
                context.Environment, TimeSpan.FromSeconds(15), Elevated: true), cancellationToken: cancellationToken);
            if (configured.Success) configuredLocation = ParseCacheLocation(configured.StdOut);
            else discoveryIssue = SourceSupport.ErrorText(configured);
        }
        catch (Exception ex) when (ex is TimeoutException or SourceException)
        {
            discoveryIssue = ex.Message;
        }
        if (!string.IsNullOrWhiteSpace(discoveryIssue))
            output?.Report(new(ProcessOutputStream.StandardError,
                $"Could not discover Chocolatey's configured cache path ({discoveryIssue}); clearing known locations."));

        var locations = _knownCacheLocations
            .Append(configuredLocation)
            .Where(path => IsSafeCacheDirectory(path) && Directory.Exists(path))
            .Select(path => Path.GetFullPath(path!))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (locations.Count == 0) return "Chocolatey's package caches were already empty.";

        var environment = context.Environment.ToDictionary(pair => pair.Key, pair => pair.Value,
            StringComparer.OrdinalIgnoreCase);
        environment["PACKMAN_CHOCO_CACHE_PATHS"] = string.Join('\n', locations);
        const string script =
            "$paths = $env:PACKMAN_CHOCO_CACHE_PATHS -split '\\r?\\n'; " +
            "foreach ($path in $paths) { " +
            "if ($path -and (Test-Path -LiteralPath $path -PathType Container)) { " +
            "Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | " +
            "Remove-Item -Recurse -Force -ErrorAction Stop } }";
        var result = await Runner.RunAsync(new ProcessInvocation("powershell.exe",
            ["-NoProfile", "-Command", script], environment, TimeSpan.FromMinutes(2), Elevated: true),
            output, cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("Clearing the Chocolatey machine cache", result);
        return $"Cleared {locations.Count} Chocolatey cache location{(locations.Count == 1 ? "" : "s")}.";
    }

    internal static string? ParseCacheLocation(string output)
    {
        foreach (var raw in output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                     .Reverse())
        {
            var line = raw.Trim().Trim('"');
            if (line.StartsWith("cacheLocation", StringComparison.OrdinalIgnoreCase))
            {
                var separator = line.IndexOfAny(['|', '=']);
                if (separator >= 0) line = line[(separator + 1)..].Trim().Trim('"');
                else
                {
                    var space = line.IndexOf(' ');
                    line = space >= 0 ? line[(space + 1)..].Trim().Trim('"') : string.Empty;
                }
            }
            if (Path.IsPathFullyQualified(line)) return line;
        }
        return null;
    }

    private static bool IsSafeCacheDirectory(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)) return false;
        try
        {
            var fullPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
            var root = Path.TrimEndingDirectorySeparator(Path.GetPathRoot(fullPath) ?? string.Empty);
            if (fullPath.Equals(root, StringComparison.OrdinalIgnoreCase)) return false;
            return new[]
            {
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                Path.GetTempPath(),
            }.Where(value => !string.IsNullOrWhiteSpace(value))
                .Select(value => Path.TrimEndingDirectorySeparator(Path.GetFullPath(value)))
                .All(value => !fullPath.Equals(value, StringComparison.OrdinalIgnoreCase));
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    private static IReadOnlyList<string> DefaultCacheLocations() =>
    [
        Path.Combine(Path.GetTempPath(), "chocolatey"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".chocolatey", "http-cache"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "ChocolateyHttpCache"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "chocolatey", "cache"),
    ];

    public override async Task UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        Validate(request);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "upgrade", request.PackageId, "--version", request.TargetVersion, "-y", "--no-progress"),
            context.Environment, TimeSpan.FromMinutes(15), Elevated: true), output, cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("choco upgrade", result);
    }
}
