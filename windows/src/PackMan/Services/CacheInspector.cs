namespace PackMan.Services;

public sealed record CachePreview(string Scope, IReadOnlyList<string> Paths, long? Bytes,
    bool Complete = true, string? Note = null)
{
    public string SizeText => Bytes is not { } bytes ? "Size unavailable" :
        $"{(Complete ? "About" : "At least")} {bytes / 1048576d:N1} MB";
}

public interface ICacheInspector
{
    Task<CachePreview> PreviewAsync(IPackageSource source, ToolContext context, CancellationToken cancellationToken);
}

public sealed class CacheInspector(IProcessRunner runner) : ICacheInspector
{
    public static string ScopeFor(SourceId id) => id switch
    {
        SourceId.Winget => "Downloaded WinGet installers in the current user's temporary folder.",
        SourceId.Chocolatey => "Chocolatey installer and HTTP caches, including the configured cache. Cleanup may request administrator approval.",
        SourceId.Scoop => "Scoop's downloaded installation archives.",
        SourceId.Npm => "The configured npm download cache.",
        SourceId.Pip => "The selected Python environment's configured pip cache.",
        SourceId.Pipx => "Configured pip caches used by pipx environments; shared caches are counted once per source.",
        SourceId.Dotnet => "All NuGet caches, including global packages. Projects will need to restore those packages again.",
        _ => "Package-manager download caches.",
    };

    public async Task<CachePreview> PreviewAsync(IPackageSource source, ToolContext context, CancellationToken cancellationToken)
    {
        async Task<string> Query(params string[] arguments)
        {
            var result = await runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
                (context.PrefixArguments ?? []).Concat(arguments).ToArray(), context.Environment,
                TimeSpan.FromSeconds(20)), cancellationToken: cancellationToken);
            if (!result.Success) throw SourceSupport.CommandFailure("Cache location lookup", result);
            return result.StdOut;
        }
        var paths = new List<string>();
        switch (source.Id)
        {
            case SourceId.Winget:
                paths.Add(Path.Combine(Path.GetTempPath(), "WinGet"));
                break;
            case SourceId.Chocolatey:
                paths.AddRange([
                    Path.Combine(Path.GetTempPath(), "chocolatey"),
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".chocolatey", "http-cache"),
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "ChocolateyHttpCache"),
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "chocolatey", "cache")]);
                try
                {
                    if (ChocoSource.ParseCacheLocation(await Query("config", "get", "cacheLocation", "--limit-output", "--yes")) is { } configured)
                        paths.Add(configured);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    var partial = await MeasureAsync(paths, cancellationToken);
                    return new(ScopeFor(source.Id), paths, partial.Bytes, false,
                        $"Configured cache could not be inspected; showing known caches only. {ex.Message}");
                }
                break;
            case SourceId.Npm:
                paths.AddRange(ParsePaths(await Query("config", "get", "cache")));
                break;
            case SourceId.Pip:
                paths.AddRange(ParsePaths(await Query("cache", "dir")));
                break;
            case SourceId.Dotnet:
                paths.AddRange(ParsePaths(await Query("nuget", "locals", "all", "--list")));
                break;
            case SourceId.Scoop:
                paths.AddRange(ParsePaths(await Query("config", "cache_path")));
                if (paths.Count == 0)
                {
                    var root = Environment.GetEnvironmentVariable("SCOOP")
                        ?? Path.GetDirectoryName(Path.GetDirectoryName(context.ExecutablePath))!;
                    paths.Add(Path.Combine(root, "cache"));
                }
                break;
            case SourceId.Pipx:
                var packages = (await Query("list", "--short")).Split('\n', StringSplitOptions.RemoveEmptyEntries)
                    .Select(line => line.Trim().Split(' ')[0]).Where(PackageIdValidator.IsValid).Distinct().ToList();
                if (packages.Count == 0) return new(ScopeFor(source.Id), [], 0);
                foreach (var package in packages)
                    paths.AddRange(ParsePaths(await Query("runpip", package, "cache", "dir")));
                break;
        }
        if (paths.Count == 0) return new(ScopeFor(source.Id), [], null, false, "The manager did not return a cache location.");
        paths = paths.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var measurement = await MeasureAsync(paths, cancellationToken);
        return new(ScopeFor(source.Id), paths, measurement.Bytes, measurement.Complete,
            measurement.Complete ? "Estimate of file sizes; locked files and shared caches can affect space actually freed."
                : "Some paths could not be measured. Links are not followed; this is a partial estimate.");
    }

    internal static IEnumerable<string> ParsePaths(string text)
    {
        foreach (var raw in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var line = raw.Trim().Trim('"');
            var separator = line.IndexOf(": ", StringComparison.Ordinal);
            if (separator >= 0) line = line[(separator + 2)..].Trim().Trim('"');
            if (Path.IsPathFullyQualified(line)) yield return line;
        }
    }

    internal static Task<(long Bytes, bool Complete)> MeasureAsync(IEnumerable<string> paths, CancellationToken cancellationToken) => Task.Run(() =>
    {
        long bytes = 0;
        var complete = true;
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var pending = new Stack<string>(paths);
        var count = 0;
        while (pending.TryPop(out var path))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (++count > 200000) { complete = false; break; }
            try
            {
                var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
                if (!visited.Add(full)) continue;
                if (full == Path.TrimEndingDirectorySeparator(Path.GetPathRoot(full)!)) { complete = false; continue; }
                var attributes = File.GetAttributes(full);
                if (attributes.HasFlag(FileAttributes.ReparsePoint)) { complete = false; continue; }
                if (attributes.HasFlag(FileAttributes.Directory))
                    foreach (var child in Directory.EnumerateFileSystemEntries(full)) pending.Push(child);
                else bytes += new FileInfo(full).Length;
            }
            catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException) { }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
            { complete = false; }
        }
        return (bytes, complete);
    }, cancellationToken);
}
