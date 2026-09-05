using System.Text.RegularExpressions;
using System.Text.Json;

namespace PackMan.Services;

public sealed class WingetSource(IToolResolver resolver, IProcessRunner runner, ISettingsService? settings = null) : PackageSourceBase(resolver, runner)
{
    private const int InstallCancelledByUser = unchecked((int)0x8A15010C);
    private const int InstallTechnologyChanged = unchecked((int)0x8A15002B);

    public override SourceDescriptor Descriptor { get; } = new(
        SourceId.Winget, "WinGet", ToolId.Winget, "winget",
        [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Microsoft", "WindowsApps", "winget.exe")],
        "https://learn.microsoft.com/windows/package-manager/winget/");

    public override async Task<SourceScanReport> ScanAsync(ToolContext context,
        IProgress<SourcePhase>? progress = null, CancellationToken cancellationToken = default)
    {
        progress?.Report(SourcePhase.Scanning);
        var scanArguments = new List<string> { "upgrade", "--disable-interactivity", "--accept-source-agreements" };
        if (settings?.IncludeUnknownVersions == true) scanArguments.Add("--include-unknown");
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, [.. scanArguments]),
            context.Environment, TimeSpan.FromMinutes(5)), cancellationToken: cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("winget upgrade", result);
        var parsed = WingetUpgradeParser.Parse(result.StdOut);
        var rows = parsed.Rows;
        if (rows.Any(row => row.IdentityTruncated))
        {
            try { rows = ResolveTruncated(rows, await ReadInventoryAsync(context, cancellationToken)); }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // Keep the incomplete row visible and disabled if native identity lookup is unavailable.
                rows = parsed.Rows;
            }
        }
        var issues = parsed.RejectedRows == 0 ? [] : new[]
        {
            new SourceIssue(SourceIssueKind.Parsing,
                $"WinGet returned {parsed.RejectedRows} record(s) that could not be parsed.",
                "Review the command log and retry after updating App Installer."),
        };
        if (rows.Any(row => row.IdentityTruncated))
            issues = [.. issues, new SourceIssue(SourceIssueKind.Parsing,
                "Some WinGet package IDs are incomplete and could not be resolved uniquely. Those updates are disabled.",
                "Retry the source after refreshing App Installer, or use the application's own updater.")];
        return new SourceScanReport(rows
            .Where(row => PackageIdValidator.IsValid(row.Id))
            .Select(row => new PackageInfo(row.Id, row.Name, row.Version, row.Available,
                row.IdentityTruncated ? "WinGet truncated the package ID. Update is disabled until a scan returns the full identity."
                    : row.Truncated ? "WinGet shortened the display name; the package ID is complete." : null,
                string.IsNullOrWhiteSpace(row.Source) ? null : row.Source,
                !row.IdentityTruncated, row.Version.Equals("Unknown", StringComparison.OrdinalIgnoreCase))).ToList(), issues);
    }

    public override bool SupportsCacheClear => true;

    public override async Task<string> ClearCacheAsync(ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        // WinGet downloads installers to %TEMP%\WinGet; deleting the folder forces clean downloads.
        var directory = Path.Combine(Path.GetTempPath(), "WinGet");
        if (!Directory.Exists(directory)) return "WinGet's download cache was already empty.";
        await Task.Run(() => Directory.Delete(directory, recursive: true), cancellationToken);
        return "Cleared the WinGet download cache.";
    }

    public override async Task<UpdateResult> UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        Validate(request);
        var args = new List<string> { "upgrade", "--id", request.PackageId, "--exact", "--version", request.TargetVersion,
            request.Interactive ? "--interactive" : "--silent", "--accept-package-agreements", "--accept-source-agreements",
            "--disable-interactivity" };
        if (request.Repository is not null) args.AddRange(["--source", request.Repository]);
        if (request.AllowUnknownVersion) args.Add("--include-unknown");
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, [.. args]),
            context.Environment, TimeSpan.FromMinutes(15), request.Elevated), output, cancellationToken);
        if (result.ExitCode == InstallCancelledByUser)
            throw new PackageUpdateCanceledException("The installer was cancelled by the user.");
        if (result.ExitCode == InstallTechnologyChanged)
            throw new SourceException(SourceIssueKind.Configuration,
                "WinGet cannot upgrade this package because the new version uses a different install technology. " +
                "Uninstall and reinstall the package, or ignore this update.");
        // A missing-file installer failure is a broken package or existing installation, not a
        // permissions problem: elevation does not change file lookup, so do not retry elevated.
        if (result.ExitCode == SourceSupport.HResultFileNotFound
            || SourceSupport.ErrorText(result).Contains("exit code: 0x80070002", StringComparison.OrdinalIgnoreCase))
            throw new SourceException(SourceIssueKind.Configuration,
                $"{request.Name}'s installer could not find a file it needs. The existing installation is " +
                $"likely broken; reinstall {request.Name}, or update it from within the app.");
        if (!result.Success) throw SourceSupport.CommandFailure("winget upgrade", result);
        return new();
    }

    public override async Task<IReadOnlyDictionary<string, UpdateVerification>> VerifyAsync(
        IReadOnlyList<UpdateRequest> requests, ToolContext context, CancellationToken cancellationToken = default)
    {
        var inventory = await ReadInventoryAsync(context, cancellationToken);
        var results = new Dictionary<string, UpdateVerification>(StringComparer.OrdinalIgnoreCase);
        foreach (var request in requests)
        {
            var matches = inventory.Where(row => row.Id.Equals(request.PackageId, StringComparison.OrdinalIgnoreCase)
                && (request.Repository is null || row.Repository.Equals(request.Repository, StringComparison.OrdinalIgnoreCase))).ToList();
            results[request.Identity] = matches.Count == 1 ? VerifyInstalled(matches[0].Version, request)
                : new(false, Evidence: "WinGet did not return one unambiguous installed package.");
        }
        return results;
    }

    private async Task<IReadOnlyList<WingetInstalledPackage>> ReadInventoryAsync(ToolContext context, CancellationToken cancellationToken)
    {
        var folder = Path.Combine(Path.GetTempPath(), "PackMan", "inventory");
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
                Arguments(context, "export", "--output", path, "--include-versions", "--accept-source-agreements", "--disable-interactivity"),
                context.Environment, TimeSpan.FromMinutes(3)), cancellationToken: cancellationToken);
            if (!result.Success) throw SourceSupport.CommandFailure("WinGet installed inventory", result);
            return ParseInventory(await File.ReadAllTextAsync(path, cancellationToken));
        }
        catch (Exception ex) when (ex is IOException or JsonException or InvalidOperationException or KeyNotFoundException)
        { throw new SourceException(SourceIssueKind.Verification, $"WinGet's installed inventory could not be read: {ex.Message}"); }
        finally { try { File.Delete(path); } catch (IOException) { } }
    }

    internal static IReadOnlyList<WingetInstalledPackage> ParseInventory(string json)
    {
        using var document = JsonDocument.Parse(json);
        if (!document.RootElement.TryGetProperty("Sources", out var sources) || sources.ValueKind != JsonValueKind.Array)
            throw new JsonException("The export does not contain a Sources array.");
        var installed = new List<WingetInstalledPackage>();
        foreach (var source in sources.EnumerateArray())
        {
            var repository = source.GetProperty("SourceDetails").GetProperty("Name").GetString()
                ?? throw new JsonException("Repository name is missing.");
            foreach (var package in source.GetProperty("Packages").EnumerateArray())
            {
                var id = package.GetProperty("PackageIdentifier").GetString();
                if (!PackageIdValidator.IsValid(id)) throw new JsonException("Package identifier is invalid.");
                installed.Add(new(id!, repository, package.TryGetProperty("Version", out var version) ? version.GetString() : null));
            }
        }
        return installed;
    }

    internal static IReadOnlyList<WingetUpgradeRow> ResolveTruncated(IReadOnlyList<WingetUpgradeRow> rows,
        IReadOnlyList<WingetInstalledPackage> inventory) => rows.Select(row =>
    {
        if (!row.IdentityTruncated) return row;
        var matches = inventory.Where(p => p.Id.StartsWith(row.Id, StringComparison.OrdinalIgnoreCase)
            && p.Repository.Equals(row.Source, StringComparison.OrdinalIgnoreCase)
            && (row.Version.Equals("Unknown", StringComparison.OrdinalIgnoreCase) || p.Version == row.Version)).ToList();
        return matches.Count == 1 ? row with { Id = matches[0].Id, IdentityTruncated = false,
            Truncated = row.Name.Contains('…') } : row;
    }).ToList();
}

public sealed record WingetInstalledPackage(string Id, string Repository, string? Version);

public static class WingetUpgradeParser
{
    private static readonly Regex AnsiPattern = new(@"\x1B\[[0-9;?]*[A-Za-z]", RegexOptions.Compiled);
    public sealed record ParseResult(IReadOnlyList<WingetUpgradeRow> Rows, int RejectedRows);

    public static ParseResult Parse(string output, bool installed = false)
    {
        var lines = output.Split('\n').Select(l => AnsiPattern.Replace(l, string.Empty).TrimEnd('\r')).ToList();
        var dashIndex = lines.FindIndex(line => line.Trim().Length >= 10 && line.Trim().All(c => c == '-'));
        if (dashIndex < 1)
        {
            var empty = lines.Any(line => line.Trim() is "No installed package found matching input criteria."
                or "No available upgrade found." or "No applicable upgrade found.");
            return new([], empty ? 0 : 1);
        }
        var header = lines[dashIndex - 1];
        var starts = Regex.Matches(header, @"\S+(?:\s\S+)*?(?=\s{2,}|$)").Select(m => m.Index).ToArray();
        if (starts.Length < (installed ? 3 : 5)) starts = EnglishColumnStarts(header, installed);
        if (starts.Length < (installed ? 3 : 5)) return new([], 1);
        var rows = new List<WingetUpgradeRow>();
        var rejected = 0;
        foreach (var line in lines.Skip(dashIndex + 1))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            if (line.TrimStart().StartsWith("-")) continue;
            if (Regex.IsMatch(line.Trim(), @"^\d+ (upgrades? available\.|package\(s\) have pins.*)$")) continue;
            if (line.Length <= starts[2]) { rejected++; continue; }
            var name = Slice(line, starts[0], starts[1]);
            var id = Slice(line, starts[1], starts[2]);
            var version = Slice(line, starts[2], starts.Length > 3 ? starts[3] : line.Length);
            var available = installed ? string.Empty : Slice(line, starts[3], starts[4]);
            var source = starts.Length >= 5 ? Slice(line, starts[4], line.Length)
                : installed && starts.Length == 4 ? Slice(line, starts[3], line.Length) : string.Empty;
            if (id.Any(char.IsWhiteSpace) || !PackageIdValidator.IsValid(id.TrimEnd('…'))
                || string.IsNullOrWhiteSpace(version) || (!installed && string.IsNullOrWhiteSpace(available)))
            {
                rejected++;
                continue;
            }
            rows.Add(new(name, id.TrimEnd('…'), version, available, source,
                name.Contains('…') || id.Contains('…'), id.Contains('…')));
        }
        return new(rows, rejected);
    }

    private static int[] EnglishColumnStarts(string header, bool installed)
    {
        var labels = installed ? new[] { "Name", "Id", "Version", "Available", "Source" }
            .Where(label => header.Contains(label, StringComparison.OrdinalIgnoreCase)).ToArray()
            : ["Name", "Id", "Version", "Available", "Source"];
        var starts = labels.Select(label => header.IndexOf(label, StringComparison.OrdinalIgnoreCase)).ToArray();
        return starts.All(x => x >= 0) ? starts : [];
    }

    private static string Slice(string line, int start, int end) =>
        line.Length <= start ? string.Empty : line[start..Math.Min(end, line.Length)].Trim();
}

public sealed record WingetUpgradeRow(string Name, string Id, string Version,
    string Available, string Source, bool Truncated, bool IdentityTruncated = false);
