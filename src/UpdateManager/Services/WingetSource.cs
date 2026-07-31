using System.IO;
using System.Text.RegularExpressions;
using UpdateManager.Models;

namespace UpdateManager.Services;

public sealed class WingetSource : IPackageSource
{
    private static readonly TimeSpan UpdateTimeout = TimeSpan.FromMinutes(10);

    private string? _wingetPath;

    public string Name => "WinGet";

    public async Task<bool> IsAvailableAsync() => await ResolveWingetAsync() is not null;

    public async Task<IReadOnlyList<PackageUpdate>> ScanAsync(CancellationToken cancellationToken = default)
    {
        var winget = await RequireWingetAsync();
        var result = await ProcessRunner.RunToolAsync(
            winget,
            "upgrade --disable-interactivity --accept-source-agreements --include-unknown",
            cancellationToken: cancellationToken);

        if (!result.Success)
            throw new InvalidOperationException($"winget upgrade failed (exit {result.ExitCode}): {result.StdErr.Trim()}");

        return WingetUpgradeParser.Parse(result.StdOut)
            .Where(r => PackageIdValidator.IsValid(r.Id))
            .Select(r => new PackageUpdate
            {
                Id = r.Id,
                Name = r.Name,
                Source = Name,
                CurrentVersion = r.Version,
                AvailableVersion = r.Available,
                SourceRef = this,
                SourceDetail = r.Source,
                StatusMessage = r.Truncated ? "Output truncated by winget; update may fail." : null,
            })
            .ToList();
    }

    public async Task UpdateAsync(PackageUpdate package, IProgress<string>? progress = null, CancellationToken cancellationToken = default)
    {
        if (!PackageIdValidator.IsValid(package.Id))
            throw new InvalidOperationException($"Refusing to update package with invalid id '{package.Id}'.");

        var winget = await RequireWingetAsync();
        var sourceArg = PackageIdValidator.IsValid(package.SourceDetail) ? $"--source {package.SourceDetail} " : "";
        var args = $"upgrade --id {package.Id} --exact {sourceArg}--silent " +
                   "--accept-package-agreements --accept-source-agreements --disable-interactivity";

        var result = await ProcessRunner.RunToolAsync(winget, args, UpdateTimeout, progress, cancellationToken);

        if (!result.Success)
            throw new InvalidOperationException($"winget upgrade failed (exit {result.ExitCode}): {result.StdErr.Trim()}");
    }

    private async Task<string> RequireWingetAsync()
        => await ResolveWingetAsync() ?? throw new InvalidOperationException("winget was not found on PATH.");

    private async Task<string?> ResolveWingetAsync()
        => _wingetPath ??= await ProcessRunner.ResolveExecutableAsync("winget", KnownPaths);

    private static readonly string[] KnownPaths =
    [
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "winget.exe"),
    ];
}

public static class WingetUpgradeParser
{
    private static readonly Regex AnsiPattern = new(@"\x1B\[[0-9;]*[A-Za-z]", RegexOptions.Compiled);

    public static IReadOnlyList<WingetUpgradeRow> Parse(string output)
    {
        var lines = output.Split('\n')
            .Select(l => AnsiPattern.Replace(l, string.Empty).TrimEnd('\r'))
            .ToList();

        var rows = new List<WingetUpgradeRow>();
        var dashIndex = FindDashLine(lines);
        if (dashIndex < 1)
            return rows;

        var header = lines[dashIndex - 1];
        var columns = GetColumnStarts(header);
        if (columns is null)
            return rows;

        var (nameStart, idStart, versionStart, availableStart, sourceStart) = columns.Value;

        for (var i = dashIndex + 1; i < lines.Count; i++)
        {
            var line = lines[i];
            if (string.IsNullOrWhiteSpace(line))
                break;

            if (line.Length < availableStart)
                break;

            var id = Slice(line, idStart, versionStart);
            if (string.IsNullOrWhiteSpace(id) || id.Contains(' '))
                continue;

            var name = Slice(line, nameStart, idStart);
            var version = Slice(line, versionStart, availableStart);
            var available = Slice(line, availableStart, sourceStart);
            var source = line.Length > sourceStart ? line[sourceStart..].Trim() : string.Empty;
            var truncated = name.Contains('…') || id.Contains('…');

            rows.Add(new WingetUpgradeRow(name, id.TrimEnd('…'), version, available, source, truncated));
        }

        return rows;
    }

    private static int FindDashLine(IReadOnlyList<string> lines)
    {
        for (var i = 0; i < lines.Count; i++)
        {
            var line = lines[i].Trim();
            if (line.Length >= 10 && line.All(c => c == '-'))
                return i;
        }
        return -1;
    }

    private static (int Name, int Id, int Version, int Available, int Source)? GetColumnStarts(string header)
    {
        var name = header.IndexOf("Name", StringComparison.Ordinal);
        var id = header.IndexOf("Id", StringComparison.Ordinal);
        var version = header.IndexOf("Version", StringComparison.Ordinal);
        var available = header.IndexOf("Available", StringComparison.Ordinal);
        var source = header.IndexOf("Source", StringComparison.Ordinal);

        if (name < 0 || id <= name || version <= id || available <= version || source <= available)
            return null;

        return (name, id, version, available, source);
    }

    private static string Slice(string line, int start, int end)
        => line.Length <= start ? string.Empty : line[start..Math.Min(end, line.Length)].Trim();
}

public sealed record WingetUpgradeRow(
    string Name,
    string Id,
    string Version,
    string Available,
    string Source,
    bool Truncated);
