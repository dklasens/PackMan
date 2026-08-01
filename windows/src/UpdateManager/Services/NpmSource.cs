using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using UpdateManager.Models;

namespace UpdateManager.Services;

public sealed class NpmSource : IPackageSource
{
    private string? _npmPath;

    public string Name => "NPM";

    public async Task<bool> IsAvailableAsync() => await ResolveNpmAsync() is not null;

    public async Task<IReadOnlyList<PackageUpdate>> ScanAsync(CancellationToken cancellationToken = default)
    {
        var npm = await RequireNpmAsync();
        var result = await ProcessRunner.RunToolAsync(npm, "outdated -g --json", cancellationToken: cancellationToken);

        if (result.ExitCode is not (0 or 1))
            throw new InvalidOperationException($"npm outdated failed (exit {result.ExitCode}): {result.StdErr.Trim()}");

        if (string.IsNullOrWhiteSpace(result.StdOut))
            return [];

        var entries = JsonSerializer.Deserialize<Dictionary<string, NpmOutdatedEntry>>(result.StdOut) ?? [];

        return entries
            .Where(kvp => PackageIdValidator.IsValid(kvp.Key))
            .Select(kvp => new PackageUpdate
            {
                Id = kvp.Key,
                Name = kvp.Key,
                Source = Name,
                CurrentVersion = kvp.Value.Current ?? string.Empty,
                AvailableVersion = kvp.Value.Wanted ?? kvp.Value.Latest ?? string.Empty,
                SourceRef = this,
            }).ToList();
    }

    public async Task UpdateAsync(PackageUpdate package, IProgress<string>? progress = null, CancellationToken cancellationToken = default)
    {
        if (!PackageIdValidator.IsValid(package.Id))
            throw new InvalidOperationException($"Refusing to update package with invalid id '{package.Id}'.");

        var npm = await RequireNpmAsync();
        var result = await ProcessRunner.RunToolAsync(npm, $"install -g {package.Id}@latest", TimeSpan.FromMinutes(10), progress, cancellationToken);

        if (!result.Success)
            throw new InvalidOperationException($"npm install failed (exit {result.ExitCode}): {result.StdErr.Trim()}");
    }

    private async Task<string> RequireNpmAsync()
        => await ResolveNpmAsync() ?? throw new InvalidOperationException("npm was not found on PATH.");

    private async Task<string?> ResolveNpmAsync()
        => _npmPath ??= await ProcessRunner.ResolveExecutableAsync("npm", KnownPaths);

    private static readonly string[] KnownPaths =
    [
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "nodejs", "npm.cmd"),
    ];

    private sealed class NpmOutdatedEntry
    {
        [JsonPropertyName("current")]
        public string? Current { get; set; }

        [JsonPropertyName("wanted")]
        public string? Wanted { get; set; }

        [JsonPropertyName("latest")]
        public string? Latest { get; set; }
    }
}
