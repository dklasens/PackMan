using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PackMan.Services;

public sealed class PipxSource(IToolResolver resolver, IProcessRunner runner, HttpClient httpClient)
    : PackageSourceBase(resolver, runner)
{
    public override SourceDescriptor Descriptor { get; } = new(
        SourceId.Pipx, "pipx", ToolId.Pipx, "pipx",
        [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Python", "Scripts", "pipx.exe")],
        "https://pipx.pypa.io/stable/installation/");

    public override async Task<SourceScanReport> ScanAsync(ToolContext context,
        IProgress<SourcePhase>? progress = null, CancellationToken cancellationToken = default)
    {
        progress?.Report(SourcePhase.Scanning);
        var help = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "list", "--help"), context.Environment, TimeSpan.FromSeconds(20)),
            cancellationToken: cancellationToken);
        return help.Success && help.StdOut.Contains("--outdated") && help.StdOut.Contains("--output")
            ? await ScanNativeAsync(context, cancellationToken)
            : await ScanLegacyAsync(context, cancellationToken);
    }

    public override async Task UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        Validate(request);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "upgrade", request.PackageId), context.Environment, TimeSpan.FromMinutes(15), request.Elevated),
            output, cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("pipx upgrade", result);
    }

    private async Task<SourceScanReport> ScanNativeAsync(ToolContext context, CancellationToken cancellationToken)
    {
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "list", "--outdated", "--output", "json"), context.Environment, TimeSpan.FromMinutes(3)),
            cancellationToken: cancellationToken);
        if (string.IsNullOrWhiteSpace(result.StdOut))
        {
            if (result.Success) return SourceScanReport.Empty;
            throw SourceSupport.CommandFailure("pipx list --outdated", result);
        }
        PipxEnvelope envelope;
        try { envelope = JsonSerializer.Deserialize<PipxEnvelope>(result.StdOut) ?? new(); }
        catch (JsonException ex) { throw new SourceException(SourceIssueKind.Parsing, $"pipx JSON could not be parsed: {ex.Message}"); }
        var updates = (envelope.Data?.Packages ?? [])
            .Where(p => !p.Injected && !p.Pinned && PackageIdValidator.IsValid(p.Package))
            .Select(p => new PackageInfo(p.Package!, p.Package!, p.Version ?? string.Empty, p.LatestVersion ?? string.Empty)).ToList();
        var issues = (envelope.Errors ?? []).Select(error => new SourceIssue(SourceIssueKind.Network,
            $"{error.Environment ?? error.Package ?? "pipx"}: {error.Message ?? "outdated check failed"}",
            "Check the package index configuration and retry.")).ToList();
        if (!result.Success && issues.Count == 0)
            issues.Add(new(SourceIssueKind.Command, "pipx reported an unsuccessful outdated check.", SourceSupport.ErrorText(result)));
        return new(updates, issues);
    }

    private async Task<SourceScanReport> ScanLegacyAsync(ToolContext context, CancellationToken cancellationToken)
    {
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "list", "--short"), context.Environment, TimeSpan.FromMinutes(1)),
            cancellationToken: cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("pipx list", result);
        var installed = new List<(string Name, string Version)>();
        var issues = new List<SourceIssue>();
        foreach (var line in result.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2 || !PackageIdValidator.IsValid(parts[0]))
                issues.Add(new(SourceIssueKind.Parsing, "Could not parse a pipx package record."));
            else installed.Add((parts[0], parts[1]));
        }
        using var gate = new SemaphoreSlim(4, 4);
        var lookups = await Task.WhenAll(installed.Select(async package =>
        {
            await gate.WaitAsync(cancellationToken);
            try { return await LookupPyPiAsync(package.Name, package.Version, cancellationToken); }
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

    private async Task<(PackageInfo? Update, SourceIssue? Issue)> LookupPyPiAsync(
        string name, string currentVersion, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await httpClient.GetAsync($"https://pypi.org/pypi/{Uri.EscapeDataString(name)}/json", cancellationToken);
            if (response.StatusCode != HttpStatusCode.OK)
                return (null, new(SourceIssueKind.Network, $"{name}: PyPI returned HTTP {(int)response.StatusCode}."));
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            var payload = await JsonSerializer.DeserializeAsync<PyPiResponse>(stream, cancellationToken: cancellationToken);
            var latest = payload?.Info?.Version;
            if (string.IsNullOrWhiteSpace(latest)) return (null, new(SourceIssueKind.Parsing, $"{name}: PyPI returned no version."));
            return latest == currentVersion ? (null, null) : (new(name, name, currentVersion, latest), null);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return (null, new(SourceIssueKind.Network, $"{name}: {ex.Message}", "Check the network and retry."));
        }
    }

    private sealed class PipxEnvelope
    {
        [JsonPropertyName("data")] public PipxData? Data { get; set; }
        [JsonPropertyName("errors")] public List<PipxError>? Errors { get; set; }
    }
    private sealed class PipxData { [JsonPropertyName("packages")] public List<PipxPackage>? Packages { get; set; } }
    private sealed class PipxPackage
    {
        [JsonPropertyName("package")] public string? Package { get; set; }
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
    private sealed class PyPiResponse { [JsonPropertyName("info")] public PyPiInfo? Info { get; set; } }
    private sealed class PyPiInfo { [JsonPropertyName("version")] public string? Version { get; set; } }
}
