using System.IO;
using UpdateManager.Models;

namespace UpdateManager.Services;

public sealed class ChocoSource : IPackageSource
{
    private string? _chocoPath;

    public string Name => "Choco";

    public async Task<bool> IsAvailableAsync() => await ResolveChocoAsync() is not null;

    public async Task<IReadOnlyList<PackageUpdate>> ScanAsync(CancellationToken cancellationToken = default)
    {
        var choco = await RequireChocoAsync();
        var result = await ProcessRunner.RunToolAsync(choco, "outdated -r --no-color", cancellationToken: cancellationToken);

        if (!result.Success)
            throw new InvalidOperationException($"choco outdated failed (exit {result.ExitCode}): {result.StdErr.Trim()}");

        var packages = new List<PackageUpdate>();
        foreach (var line in result.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = line.Split('|');
            if (parts.Length < 4)
                continue;

            var pinned = string.Equals(parts[3], "true", StringComparison.OrdinalIgnoreCase);
            if (pinned || !PackageIdValidator.IsValid(parts[0]))
                continue;

            packages.Add(new PackageUpdate
            {
                Id = parts[0],
                Name = parts[0],
                Source = Name,
                CurrentVersion = parts[1],
                AvailableVersion = parts[2],
                SourceRef = this,
            });
        }

        return packages;
    }

    public async Task UpdateAsync(PackageUpdate package, IProgress<string>? progress = null, CancellationToken cancellationToken = default)
    {
        if (!PackageIdValidator.IsValid(package.Id))
            throw new InvalidOperationException($"Refusing to update package with invalid id '{package.Id}'.");

        var choco = await RequireChocoAsync();
        var result = await ProcessRunner.RunToolAsync(choco, $"upgrade {package.Id} -y --no-progress", TimeSpan.FromMinutes(10), progress, cancellationToken);

        if (!result.Success)
            throw new InvalidOperationException($"choco upgrade failed (exit {result.ExitCode}): {result.StdErr.Trim()}");
    }

    private async Task<string> RequireChocoAsync()
        => await ResolveChocoAsync() ?? throw new InvalidOperationException("choco was not found on PATH.");

    private async Task<string?> ResolveChocoAsync()
        => _chocoPath ??= await ProcessRunner.ResolveExecutableAsync("choco", KnownPaths);

    private static readonly string[] KnownPaths =
    [
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "chocolatey", "bin", "choco.exe"),
    ];
}
