using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using UpdateManager.Models;

namespace UpdateManager.Services;

public sealed class PipSource : IPackageSource
{
    private string? _pythonPath;
    private string? _pipPath;
    private bool _resolved;

    public string Name => "pip";

    public async Task<bool> IsAvailableAsync() => await ResolveToolAsync() is not null;

    public async Task<IReadOnlyList<PackageUpdate>> ScanAsync(CancellationToken cancellationToken = default)
    {
        var (tool, prefix) = await RequireToolAsync();
        var result = await ProcessRunner.RunToolAsync(
            tool,
            $"{prefix}list --outdated --format json --disable-pip-version-check",
            cancellationToken: cancellationToken);

        if (!result.Success)
            throw new InvalidOperationException($"pip list failed (exit {result.ExitCode}): {result.StdErr.Trim()}");

        if (string.IsNullOrWhiteSpace(result.StdOut))
            return [];

        var entries = JsonSerializer.Deserialize<List<PipOutdatedEntry>>(result.StdOut) ?? [];

        return entries
            .Where(e => PackageIdValidator.IsValid(e.Name))
            .Select(e => new PackageUpdate
            {
                Id = e.Name!,
                Name = e.Name!,
                Source = Name,
                CurrentVersion = e.Version ?? string.Empty,
                AvailableVersion = e.LatestVersion ?? string.Empty,
                SourceRef = this,
            }).ToList();
    }

    public async Task UpdateAsync(PackageUpdate package, IProgress<string>? progress = null, CancellationToken cancellationToken = default)
    {
        if (!PackageIdValidator.IsValid(package.Id))
            throw new InvalidOperationException($"Refusing to update package with invalid id '{package.Id}'.");

        var (tool, prefix) = await RequireToolAsync();

        if (prefix.Length == 0 && package.Id.Equals("pip", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("pip cannot upgrade itself via the pip wrapper; python -m pip is required.");

        var result = await ProcessRunner.RunToolAsync(
            tool,
            $"{prefix}install --upgrade {package.Id}",
            TimeSpan.FromMinutes(10),
            progress,
            cancellationToken);

        if (!result.Success)
            throw new InvalidOperationException($"pip install failed (exit {result.ExitCode}): {result.StdErr.Trim()}");
    }

    private async Task<(string Tool, string Prefix)> RequireToolAsync()
        => await ResolveToolAsync() ?? throw new InvalidOperationException("Neither python nor pip was found on PATH.");

    private async Task<(string Tool, string Prefix)?> ResolveToolAsync()
    {
        if (_resolved)
            return CurrentTool();

        _resolved = true;
        _pythonPath = ResolveFromKnownPaths();

        if (_pythonPath is null)
        {
            var where = await ProcessRunner.RunAsync("where.exe", "python", TimeSpan.FromSeconds(10));
            if (where.ExitCode == 0)
            {
                _pythonPath = where.StdOut
                    .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                    .Where(File.Exists)
                    .Where(p => !p.Contains("WindowsApps", StringComparison.OrdinalIgnoreCase))
                    .FirstOrDefault(p => p.EndsWith(".exe", StringComparison.OrdinalIgnoreCase));
            }
        }

        if (_pythonPath is null)
            _pipPath = await ProcessRunner.ResolveExecutableAsync("pip");

        return CurrentTool();
    }

    private static string? ResolveFromKnownPaths()
    {
        var roots = new List<string> { @"C:\" };
        var userPython = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Programs", "Python");
        roots.Add(userPython);

        foreach (var root in roots)
        {
            var candidate = Directory.EnumerateDirectories(root, "Python3*", new EnumerationOptions { IgnoreInaccessible = true })
                .OrderByDescending(d => d, StringComparer.OrdinalIgnoreCase)
                .Select(d => Path.Combine(d, "python.exe"))
                .FirstOrDefault(File.Exists);

            if (candidate is not null)
                return candidate;
        }

        return null;
    }

    private (string Tool, string Prefix)? CurrentTool()
        => _pythonPath is not null ? (_pythonPath, "-m pip ")
         : _pipPath is not null ? (_pipPath, "")
         : null;

    private sealed class PipOutdatedEntry
    {
        [JsonPropertyName("name")]
        public string? Name { get; set; }

        [JsonPropertyName("version")]
        public string? Version { get; set; }

        [JsonPropertyName("latest_version")]
        public string? LatestVersion { get; set; }
    }
}
