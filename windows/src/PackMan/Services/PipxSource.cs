using System.Text.Json;
using System.Text.Json.Serialization;

namespace PackMan.Services;

public sealed class PipxSource(IToolResolver resolver, IProcessRunner runner)
    : PackageSourceBase(resolver, runner)
{
    public override SourceDescriptor Descriptor { get; } = new(
        SourceId.Pipx, "pipx", ToolId.Pipx, "pipx",
        [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Python", "Scripts", "pipx.exe")],
        "https://pipx.pypa.io/stable/installation/");

    private (string Path, string Version, string Prefix, bool Supported)? _outdatedCapability;

    public override async Task<IReadOnlyDictionary<string, UpdateVerification>> VerifyAsync(
        IReadOnlyList<UpdateRequest> requests, ToolContext context, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "list", "--short"), context.Environment, TimeSpan.FromMinutes(1)), cancellationToken: cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("pipx installed inventory", result);
        var installed = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in result.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2 || !PackageIdValidator.IsValid(parts[0]) || !PackageVersions.IsPythonVersion(parts[1].TrimEnd(',')))
                throw new SourceException(SourceIssueKind.Verification, "pipx returned an unrecognized installed-package record.");
            installed[parts[0]] = parts[1].TrimEnd(',');
        }
        return requests.ToDictionary(r => r.Identity, r => VerifyInstalled(installed.GetValueOrDefault(r.PackageId), r, PackageVersions.ComparePython),
            StringComparer.OrdinalIgnoreCase);
    }

    public override bool SupportsCacheClear => true;

    public override async Task<string> ClearCacheAsync(ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        // pipx delegates downloads to the pip inside each managed environment. Asking each
        // environment to purge its own configured pip cache also handles non-default locations.
        var list = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "list", "--short"), context.Environment, TimeSpan.FromMinutes(1)),
            cancellationToken: cancellationToken);
        if (!list.Success) throw SourceSupport.CommandFailure("pipx list", list);
        var packages = list.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(line => line.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault())
            .Where(PackageIdValidator.IsValid)
            .Select(package => package!)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (packages.Count == 0) return "pipx has no managed environments with package caches.";

        var failures = new List<string>();
        foreach (var package in packages)
        {
            var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
                Arguments(context, "runpip", package, "cache", "purge"), context.Environment,
                TimeSpan.FromMinutes(2)), output, cancellationToken);
            if (!result.Success) failures.Add($"{package}: {SourceSupport.ErrorText(result)}");
        }
        if (failures.Count > 0)
            throw new SourceException(SourceIssueKind.Command,
                $"Could not clear {failures.Count} pipx cache{(failures.Count == 1 ? "" : "s")}: " +
                string.Join("; ", failures));
        return $"Cleared pip caches for {packages.Count} pipx environment{(packages.Count == 1 ? "" : "s")}.";
    }

    public override async Task<SourceScanReport> ScanAsync(ToolContext context,
        IProgress<SourcePhase>? progress = null, CancellationToken cancellationToken = default)
    {
        progress?.Report(SourcePhase.Scanning);
        var prefix = string.Join("\0", context.PrefixArguments ?? []);
        var cached = _outdatedCapability;
        bool supported;
        if (cached is { } capability && capability.Path.Equals(context.ExecutablePath, StringComparison.OrdinalIgnoreCase)
            && capability.Version == context.Version && capability.Prefix == prefix)
            supported = capability.Supported;
        else
        {
            var help = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
                Arguments(context, "list", "--help"), context.Environment, TimeSpan.FromSeconds(20)),
                cancellationToken: cancellationToken);
            supported = help.Success && help.StdOut.Contains("--outdated") && help.StdOut.Contains("--output");
            if (help.Success) _outdatedCapability = (context.ExecutablePath, context.Version, prefix, supported);
        }
        return supported
            ? await ScanNativeAsync(context, cancellationToken)
            : await ScanLegacyAsync(context, cancellationToken);
    }

    public override async Task<UpdateResult> UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        Validate(request, PackageVersions.IsPythonVersion);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "upgrade", request.PackageId), context.Environment, TimeSpan.FromMinutes(15), request.Elevated,
            ProcessRunner.DiagnosticCaptureLimit),
            output, cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("pipx upgrade", result);
        return new();
    }

    private async Task<SourceScanReport> ScanNativeAsync(ToolContext context, CancellationToken cancellationToken)
    {
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "list", "--outdated", "--output", "json"), context.Environment, TimeSpan.FromMinutes(3)),
            cancellationToken: cancellationToken);
        if (string.IsNullOrWhiteSpace(result.StdOut))
        {
            if (result.Success) return new([], [new(SourceIssueKind.Parsing, "pipx did not return its outdated JSON response.")]);
            throw SourceSupport.CommandFailure("pipx list --outdated", result);
        }
        PipxEnvelope envelope;
        try { envelope = JsonSerializer.Deserialize<PipxEnvelope>(result.StdOut) ?? new(); }
        catch (JsonException ex) { throw new SourceException(SourceIssueKind.Parsing, $"pipx JSON could not be parsed: {ex.Message}"); }
        var issues = (envelope.Errors ?? []).Select(error => error is null
            ? new SourceIssue(SourceIssueKind.Parsing, "pipx returned an invalid error record.")
            : new SourceIssue(SourceIssueKind.Network,
                $"{error.Environment ?? error.Package ?? "pipx"}: {error.Message ?? "outdated check failed"}",
                "Check the package index configuration and retry.")).ToList();
        var updates = new List<PackageInfo>();
        if (envelope.Data?.Packages is null)
            issues.Add(new(SourceIssueKind.Parsing, "pipx returned an unrecognized outdated response."));
        if (envelope.Status is not (null or "success" or "partial" or "error"))
            issues.Add(new(SourceIssueKind.Parsing, "pipx returned an unrecognized response status."));
        foreach (var package in envelope.Data?.Packages ?? [])
        {
            if (package is not null && (package.Injected || package.Pinned)) continue;
            if (package is null || !PackageIdValidator.IsValid(package.Environment ?? package.Package)
                || !PackageIdValidator.IsValid(package.Package) || !PackageVersions.IsPythonVersion(package.Version)
                || !PackageVersions.IsPythonVersion(package.LatestVersion))
            {
                issues.Add(new(SourceIssueKind.Parsing, "pipx returned an invalid package record."));
                continue;
            }
            if (PackageVersions.ComparePython(package.LatestVersion, package.Version) is > 0)
                updates.Add(new(package.Environment ?? package.Package!, package.Package!, package.Version!, package.LatestVersion!));
            else if (PackageVersions.ComparePython(package.LatestVersion, package.Version) is null)
                issues.Add(new(SourceIssueKind.Parsing, $"{package.Package}: Python versions could not be compared."));
        }
        if ((!result.Success || envelope.Status is "partial" or "error") && issues.Count == 0)
            issues.Add(new(SourceIssueKind.Command, "pipx reported an unsuccessful outdated check.", SourceSupport.ErrorText(result)));
        return new(updates, issues);
    }

    private async Task<SourceScanReport> ScanLegacyAsync(ToolContext context, CancellationToken cancellationToken)
    {
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "list", "--json"), context.Environment, TimeSpan.FromMinutes(1)),
            cancellationToken: cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("pipx list", result);
        var installed = new List<(string Environment, string Name, string Version)>();
        var issues = new List<SourceIssue>();
        try
        {
            using var document = JsonDocument.Parse(result.StdOut);
            if (!document.RootElement.TryGetProperty("venvs", out var venvs) || venvs.ValueKind != JsonValueKind.Object)
                throw new JsonException("Missing pipx environment inventory.");
            foreach (var environment in venvs.EnumerateObject())
            {
                if (!PackageIdValidator.IsValid(environment.Name)
                    || !environment.Value.TryGetProperty("metadata", out var metadata)
                    || !metadata.TryGetProperty("main_package", out var package))
                { issues.Add(new(SourceIssueKind.Parsing, "pipx returned incomplete environment metadata.")); continue; }
                var name = package.TryGetProperty("package", out var packageName) ? packageName.GetString() : null;
                var version = package.TryGetProperty("package_version", out var packageVersion) ? packageVersion.GetString() : null;
                if (!PackageIdValidator.IsValid(name) || !PackageVersions.IsPythonVersion(version))
                { issues.Add(new(SourceIssueKind.Parsing, "pipx returned invalid package metadata.")); continue; }
                if (package.TryGetProperty("pinned", out var pinned) && pinned.ValueKind == JsonValueKind.True) continue;
                if (!package.TryGetProperty("package_or_url", out var origin) || origin.ValueKind != JsonValueKind.String
                    || !string.Equals(origin.GetString(), name, StringComparison.OrdinalIgnoreCase)
                    || !package.TryGetProperty("pip_args", out var args) || args.ValueKind != JsonValueKind.Array
                    || args.GetArrayLength() != 0
                    || (package.TryGetProperty("lock_file", out var lockFile) && lockFile.ValueKind != JsonValueKind.Null))
                {
                    issues.Add(new(SourceIssueKind.Configuration, $"{environment.Name}: this pipx version cannot confirm a custom or constrained installation.",
                        "Upgrade pipx to a release with native outdated checks."));
                    continue;
                }
                installed.Add((environment.Name, name!, version!));
            }
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException)
        { return new([], [new(SourceIssueKind.Parsing, "pipx returned an unrecognized environment inventory.")]); }
        using var gate = new SemaphoreSlim(4, 4);
        var lookups = await Task.WhenAll(installed.Select(async package =>
        {
            await gate.WaitAsync(cancellationToken);
            try { return await LookupEnvironmentAsync(context, package.Environment, package.Name, package.Version, cancellationToken); }
            finally { gate.Release(); }
        }));
        var updates = new List<PackageInfo>();
        foreach (var lookup in lookups)
        {
            if (lookup.Update is not null) updates.Add(lookup.Update);
            if (lookup.Issue is not null) issues.Add(lookup.Issue);
        }
        return new(updates.OrderBy(x => x.Name, StringComparer.CurrentCultureIgnoreCase).ToList(), issues);
    }

    private async Task<(PackageInfo? Update, SourceIssue? Issue)> LookupEnvironmentAsync(
        ToolContext context, string environment, string name, string currentVersion, CancellationToken cancellationToken)
    {
        try
        {
            var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
                Arguments(context, "runpip", environment, "list", "--outdated", "--format", "json", "--disable-pip-version-check"),
                context.Environment, TimeSpan.FromMinutes(2)), cancellationToken: cancellationToken);
            if (!result.Success) return (null, new(SourceIssueKind.Command, $"{environment}: pipx environment check failed."));
            if (result.StdErr.Contains("ERROR", StringComparison.OrdinalIgnoreCase)
                || result.StdErr.Contains("WARNING: Retrying", StringComparison.OrdinalIgnoreCase))
                return (null, new(SourceIssueKind.Network, $"{environment}: pip reported an incomplete index check."));
            var entries = JsonSerializer.Deserialize<List<LegacyPipEntry>>(result.StdOut)
                ?? throw new JsonException("Expected outdated package array.");
            if (entries.Any(item => item is null || !PackageIdValidator.IsValid(item.Name) || !PackageVersions.IsPythonVersion(item.LatestVersion)))
                return (null, new(SourceIssueKind.Parsing, $"{environment}: pip returned an invalid package record."));
            var entry = entries.FirstOrDefault(item => NormalizeName(item.Name) == NormalizeName(name));
            if (entry is null) return (null, null);
            var comparison = PackageVersions.ComparePython(entry.LatestVersion, currentVersion);
            return comparison is > 0 ? (new(environment, name, currentVersion, entry.LatestVersion!), null)
                : comparison is null ? (null, new(SourceIssueKind.Parsing, $"{environment}: Python versions could not be compared."))
                : (null, null);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return (null, new(SourceIssueKind.Command, $"{environment}: pipx environment could not be checked.", "Check its configuration and retry."));
        }
    }

    private sealed class PipxEnvelope
    {
        [JsonPropertyName("data")] public PipxData? Data { get; set; }
        [JsonPropertyName("errors")] public List<PipxError>? Errors { get; set; }
        [JsonPropertyName("status")] public string? Status { get; set; }
    }
    private sealed class PipxData { [JsonPropertyName("packages")] public List<PipxPackage>? Packages { get; set; } }
    private sealed class PipxPackage
    {
        [JsonPropertyName("package")] public string? Package { get; set; }
        [JsonPropertyName("environment")] public string? Environment { get; set; }
        [JsonPropertyName("version")] public string? Version { get; set; }
        [JsonPropertyName("latest_version")] public string? LatestVersion { get; set; }
        [JsonPropertyName("injected")] public bool Injected { get; set; }
        [JsonPropertyName("pinned")] public bool Pinned { get; set; }
    }
    private sealed class PipxError
    {
        [JsonPropertyName("message")] public string? Message { get; set; }
        [JsonPropertyName("environment")] public string? Environment { get; set; }
        [JsonPropertyName("package")] public string? Package { get; set; }
    }
    private static string NormalizeName(string? name) =>
        System.Text.RegularExpressions.Regex.Replace(name ?? "", "[-_.]+", "-").ToLowerInvariant();
    private sealed class LegacyPipEntry
    {
        [JsonPropertyName("name")] public string? Name { get; set; }
        [JsonPropertyName("latest_version")] public string? LatestVersion { get; set; }
    }
}
