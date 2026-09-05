using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PackMan.Services;

public sealed class DotnetSource(IToolResolver resolver, IProcessRunner runner, HttpClient httpClient)
    : PackageSourceBase(resolver, runner)
{
    public override SourceDescriptor Descriptor { get; } = new(
        SourceId.Dotnet, ".NET Tools", ToolId.Dotnet, "dotnet",
        [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "dotnet", "dotnet.exe")],
        "https://dotnet.microsoft.com/download");

    public override async Task<SourceProbe> ProbeAsync(CancellationToken cancellationToken = default)
    {
        var resolution = await Resolver.ResolveAsync(Descriptor, cancellationToken);
        if (resolution.Tool is null)
            return SourceProbe.Unavailable(resolution.Issue ?? new SourceIssue(
                SourceIssueKind.Unavailable, "dotnet was not found.",
                "Install a .NET SDK or choose dotnet.exe in Sources."));

        try
        {
            var arguments = (resolution.Tool.PrefixArguments ?? []).Concat(["--list-sdks"]).ToArray();
            var result = await Runner.RunAsync(new ProcessInvocation(resolution.Tool.Path, arguments,
                BuildEnvironment(resolution.Tool.PathEntries), TimeSpan.FromSeconds(15)),
                cancellationToken: cancellationToken);
            if (!result.Success)
                return SourceProbe.Unavailable(new SourceIssue(SourceIssueKind.Configuration,
                    $"dotnet was found, but its installed SDKs could not be checked: {SourceSupport.ErrorText(result)}",
                    "Install or repair a .NET SDK, then retry."));

            var sdkLine = result.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries)
                .Select(line => line.Trim()).LastOrDefault();
            if (string.IsNullOrWhiteSpace(sdkLine))
                return SourceProbe.Unavailable(new SourceIssue(SourceIssueKind.Configuration,
                    "The .NET runtime is installed, but no .NET SDK is installed for global tool management.",
                    "Install a .NET SDK or disable .NET Tools in Sources."));

            var version = sdkLine.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "Available";
            return SourceProbe.Available(new ToolContext(resolution.Tool.Path, version,
                resolution.Tool.Origin, resolution.Tool.PathEntries, resolution.Tool.PrefixArguments));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return SourceProbe.Unavailable(new SourceIssue(SourceIssueKind.Configuration,
                $"dotnet could not be started: {ex.Message}", "Install or repair a .NET SDK, then retry."));
        }
    }

    public override async Task<SourceScanReport> ScanAsync(ToolContext context,
        IProgress<SourcePhase>? progress = null, CancellationToken cancellationToken = default)
    {
        progress?.Report(SourcePhase.Scanning);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "tool", "list", "--global"), InventoryEnvironment(context), TimeSpan.FromMinutes(1)),
            cancellationToken: cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("dotnet tool list", result);
        var parsed = DotnetToolListParser.Parse(result.StdOut);
        var updates = new List<PackageInfo>();
        var issues = new List<SourceIssue>(parsed.Issues);
        using var gate = new SemaphoreSlim(4, 4);
        var lookups = await Task.WhenAll(parsed.Tools.Select(async tool =>
        {
            await gate.WaitAsync(cancellationToken);
            try { return await LookupNuGetAsync(tool.Id, tool.Version, cancellationToken); }
            finally { gate.Release(); }
        }));
        foreach (var lookup in lookups)
        {
            if (lookup.Update is not null) updates.Add(lookup.Update);
            if (lookup.Issue is not null) issues.Add(lookup.Issue);
        }
        return new(updates.OrderBy(x => x.Name, StringComparer.CurrentCultureIgnoreCase).ToList(), issues);
    }

    public override bool SupportsCacheClear => true;

    private static IReadOnlyDictionary<string, string> InventoryEnvironment(ToolContext context) =>
        new Dictionary<string, string>(context.Environment) { ["DOTNET_CLI_UI_LANGUAGE"] = "en-US" };

    public override async Task<IReadOnlyDictionary<string, UpdateVerification>> VerifyAsync(
        IReadOnlyList<UpdateRequest> requests, ToolContext context, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "tool", "list", "--global"), InventoryEnvironment(context), TimeSpan.FromMinutes(1)),
            cancellationToken: cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("dotnet installed inventory", result);
        var parsed = DotnetToolListParser.Parse(result.StdOut);
        if (parsed.Issues.Count > 0)
            throw new SourceException(SourceIssueKind.Verification, string.Join("; ", parsed.Issues.Select(i => i.Message)));
        return requests.ToDictionary(r => r.Identity, r => VerifyInstalled(parsed.Tools.FirstOrDefault(p =>
            p.Id.Equals(r.PackageId, StringComparison.OrdinalIgnoreCase)).Version, r), StringComparer.OrdinalIgnoreCase);
    }

    public override async Task<string> ClearCacheAsync(ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "nuget", "locals", "all", "--clear"), context.Environment, TimeSpan.FromMinutes(3)),
            output, cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("dotnet nuget locals", result);
        return "Cleared the NuGet caches (global packages, HTTP, temp, plugins).";
    }

    public override async Task<UpdateResult> UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        Validate(request);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "tool", "update", "--global", request.PackageId, "--version", request.TargetVersion),
            context.Environment, TimeSpan.FromMinutes(15), request.Elevated), output, cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("dotnet tool update", result);
        return new();
    }

    private async Task<(PackageInfo? Update, SourceIssue? Issue)> LookupNuGetAsync(
        string id, string currentVersion, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await httpClient.GetAsync(
                $"https://api.nuget.org/v3-flatcontainer/{Uri.EscapeDataString(id.ToLowerInvariant())}/index.json", cancellationToken);
            if (response.StatusCode == HttpStatusCode.NotFound)
                return (null, new(SourceIssueKind.Network, $"{id}: the package was not found on nuget.org."));
            if (response.StatusCode != HttpStatusCode.OK)
                return (null, new(SourceIssueKind.Network, $"{id}: nuget.org returned HTTP {(int)response.StatusCode}."));
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            var payload = await JsonSerializer.DeserializeAsync<NuGetVersionIndex>(stream, cancellationToken: cancellationToken);
            var versions = payload?.Versions ?? [];
            var latest = versions.LastOrDefault(v => !v.Contains('-')) ?? versions.LastOrDefault();
            if (string.IsNullOrWhiteSpace(latest)) return (null, new(SourceIssueKind.Parsing, $"{id}: nuget.org returned no versions."));
            if (string.Equals(latest, currentVersion, StringComparison.OrdinalIgnoreCase)) return (null, null);
            if (System.Version.TryParse(latest, out var latestParsed)
                && System.Version.TryParse(currentVersion, out var currentParsed)
                && latestParsed <= currentParsed) return (null, null);
            return (new(id, id, currentVersion, latest), null);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return (null, new(SourceIssueKind.Network, $"{id}: {ex.Message}", "Check the network and retry."));
        }
    }

    private sealed class NuGetVersionIndex { [JsonPropertyName("versions")] public List<string>? Versions { get; set; } }
}

public static class DotnetToolListParser
{
    public sealed record ParseResult(IReadOnlyList<(string Id, string Version)> Tools, IReadOnlyList<SourceIssue> Issues);

    public static ParseResult Parse(string output)
    {
        var tools = new List<(string Id, string Version)>();
        var issues = new List<SourceIssue>();
        var inTable = false;
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.TrimEnd('\r').Trim();
            if (string.IsNullOrWhiteSpace(line)) continue;
            if (line.StartsWith("Package Id", StringComparison.OrdinalIgnoreCase)) { inTable = true; continue; }
            if (line.All(c => c is '-' or ' ')) continue;
            if (!inTable) continue;
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2 || !PackageIdValidator.IsValid(parts[0]))
            {
                issues.Add(new(SourceIssueKind.Parsing, "dotnet tool list returned a record that could not be parsed."));
                continue;
            }
            tools.Add((parts[0], parts[1]));
        }
        if (!inTable) issues.Add(new(SourceIssueKind.Parsing,
            "The .NET installed-tool table was not recognized. No empty result can be confirmed."));
        return new(tools, issues.DistinctBy(i => i.Id).ToList());
    }
}
