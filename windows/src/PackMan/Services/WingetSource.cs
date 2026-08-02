using System.Text.RegularExpressions;

namespace PackMan.Services;

public sealed class WingetSource(IToolResolver resolver, IProcessRunner runner) : PackageSourceBase(resolver, runner)
{
    public override SourceDescriptor Descriptor { get; } = new(
        SourceId.Winget, "WinGet", ToolId.Winget, "winget",
        [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Microsoft", "WindowsApps", "winget.exe")],
        "https://learn.microsoft.com/windows/package-manager/winget/");

    public override async Task<SourceScanReport> ScanAsync(ToolContext context,
        IProgress<SourcePhase>? progress = null, CancellationToken cancellationToken = default)
    {
        progress?.Report(SourcePhase.Scanning);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "upgrade", "--disable-interactivity", "--accept-source-agreements", "--include-unknown"),
            context.Environment, TimeSpan.FromMinutes(5)), cancellationToken: cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("winget upgrade", result);
        var parsed = WingetUpgradeParser.Parse(result.StdOut);
        var issues = parsed.RejectedRows == 0 ? [] : new[]
        {
            new SourceIssue(SourceIssueKind.Parsing,
                $"WinGet returned {parsed.RejectedRows} record(s) that could not be parsed.",
                "Review the command log and retry after updating App Installer."),
        };
        return new SourceScanReport(parsed.Rows
            .Where(row => PackageIdValidator.IsValid(row.Id))
            .Select(row => new PackageInfo(row.Id, row.Name, row.Version, row.Available,
                row.Truncated ? "WinGet truncated this record; the exact update may fail." : null)).ToList(), issues);
    }

    public override async Task UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        Validate(request);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "upgrade", "--id", request.PackageId, "--exact", "--version", request.TargetVersion,
                "--silent", "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity"),
            context.Environment, TimeSpan.FromMinutes(15), request.Elevated), output, cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("winget upgrade", result);
    }
}

public static class WingetUpgradeParser
{
    private static readonly Regex AnsiPattern = new(@"\x1B\[[0-9;?]*[A-Za-z]", RegexOptions.Compiled);
    public sealed record ParseResult(IReadOnlyList<WingetUpgradeRow> Rows, int RejectedRows);

    public static ParseResult Parse(string output)
    {
        var lines = output.Split('\n').Select(l => AnsiPattern.Replace(l, string.Empty).TrimEnd('\r')).ToList();
        var dashIndex = lines.FindIndex(line => line.Trim().Length >= 10 && line.Trim().All(c => c == '-'));
        if (dashIndex < 1) return new([], 0);
        var header = lines[dashIndex - 1];
        var starts = Regex.Matches(header, @"\S+(?:\s\S+)*?(?=\s{2,}|$)").Select(m => m.Index).ToArray();
        if (starts.Length < 5) starts = EnglishColumnStarts(header);
        if (starts.Length < 5) return new([], 1);
        var rows = new List<WingetUpgradeRow>();
        var rejected = 0;
        foreach (var line in lines.Skip(dashIndex + 1))
        {
            if (string.IsNullOrWhiteSpace(line)) break;
            if (line.TrimStart().StartsWith("-")) continue;
            if (line.Length <= starts[3]) break;
            var name = Slice(line, starts[0], starts[1]);
            var id = Slice(line, starts[1], starts[2]);
            var version = Slice(line, starts[2], starts[3]);
            var available = Slice(line, starts[3], starts[4]);
            var source = Slice(line, starts[4], line.Length);
            if (id.Any(char.IsWhiteSpace)) break;
            if (!PackageIdValidator.IsValid(id.TrimEnd('…')) || string.IsNullOrWhiteSpace(available))
            {
                rejected++;
                continue;
            }
            rows.Add(new(name, id.TrimEnd('…'), version, available, source,
                name.Contains('…') || id.Contains('…')));
        }
        return new(rows, rejected);
    }

    private static int[] EnglishColumnStarts(string header)
    {
        var labels = new[] { "Name", "Id", "Version", "Available", "Source" };
        var starts = labels.Select(label => header.IndexOf(label, StringComparison.OrdinalIgnoreCase)).ToArray();
        return starts.All(x => x >= 0) ? starts : [];
    }

    private static string Slice(string line, int start, int end) =>
        line.Length <= start ? string.Empty : line[start..Math.Min(end, line.Length)].Trim();
}

public sealed record WingetUpgradeRow(string Name, string Id, string Version,
    string Available, string Source, bool Truncated);
