namespace PackMan.Services;

public sealed record ToolResolution(ResolvedTool? Tool, SourceIssue? Issue = null);

public interface IToolResolver
{
    Task<ToolResolution> ResolveAsync(SourceDescriptor descriptor, CancellationToken cancellationToken = default);
}

public sealed class ToolResolver(ISettingsService settings, IProcessRunner runner) : IToolResolver
{
    public async Task<ToolResolution> ResolveAsync(SourceDescriptor descriptor,
        CancellationToken cancellationToken = default)
    {
        var configured = settings.GetExecutableOverride(descriptor.ToolId);
        if (!string.IsNullOrWhiteSpace(configured))
        {
            var candidate = FindConfiguredExecutable(configured);
            return candidate is not null
                ? Found(candidate, ToolResolutionOrigin.Custom)
                : new(null, new SourceIssue(SourceIssueKind.Configuration,
                    $"The configured executable does not exist: {configured}", "Choose another executable or use automatic discovery."));
        }

        string? storeAliasStub = null;
        foreach (var directory in PathDirectories())
        {
            var candidate = FindInDirectory(directory, descriptor.ExecutableName);
            if (candidate is null) continue;
            // A missing Microsoft Store app leaves a 0-byte execution alias stub in WindowsApps
            // that intercepts launches and opens the Store instead of running a tool. Keep it
            // as a last resort only, behind any real installation on PATH.
            if (IsStoreAliasStub(descriptor.ExecutableName, directory, candidate))
            {
                storeAliasStub ??= candidate;
                continue;
            }
            return Found(candidate, ToolResolutionOrigin.Path);
        }
        if (storeAliasStub is not null) return Found(storeAliasStub, ToolResolutionOrigin.Path);
        foreach (var candidate in descriptor.KnownPaths.Where(File.Exists))
            return Found(candidate, ToolResolutionOrigin.KnownLocation);
        foreach (var directory in UserDirectories(descriptor.ToolId))
        {
            var candidate = FindInDirectory(directory, descriptor.ExecutableName);
            if (candidate is not null) return Found(candidate,
                descriptor.ToolId == ToolId.Npm ? ToolResolutionOrigin.VersionManager : ToolResolutionOrigin.UserLocation);
        }

        try
        {
            var result = await runner.RunAsync(new ProcessInvocation("where.exe", [descriptor.ExecutableName],
                Timeout: TimeSpan.FromSeconds(10)), cancellationToken: cancellationToken);
            var found = result.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Where(File.Exists)
                .OrderBy(ExecutablePreference)
                .FirstOrDefault();
            if (found is not null) return Found(found, ToolResolutionOrigin.Path);
        }
        catch when (!cancellationToken.IsCancellationRequested) { }
        return new(null, new SourceIssue(SourceIssueKind.Unavailable,
            $"{descriptor.ExecutableName} was not found.", "Install it or choose its executable in Sources."));
    }

    private static ToolResolution Found(string path, ToolResolutionOrigin origin,
        IReadOnlyList<string>? prefix = null) =>
        new(new ResolvedTool(Path.GetFullPath(path), origin, [Path.GetDirectoryName(Path.GetFullPath(path))!], prefix));

    private static IEnumerable<string> PathDirectories() =>
        (Environment.GetEnvironmentVariable("PATH") ?? string.Empty)
        .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
        .Distinct(StringComparer.OrdinalIgnoreCase);

    internal static string? FindInDirectory(string directory, string name)
    {
        if (!Directory.Exists(directory)) return null;
        var candidateNames = Path.HasExtension(name)
            ? [name]
            : new[] { $"{name}.exe", $"{name}.com", $"{name}.cmd", $"{name}.bat", name };
        foreach (var candidateName in candidateNames)
        {
            var candidate = Path.Combine(directory, candidateName);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    private static string? FindConfiguredExecutable(string path)
    {
        var fullPath = Path.GetFullPath(path);
        if (Path.HasExtension(fullPath)) return File.Exists(fullPath) ? fullPath : null;
        return FindInDirectory(Path.GetDirectoryName(fullPath)!, Path.GetFileName(fullPath));
    }

    internal static bool IsStoreAliasStub(string executableName, string directory, string path)
    {
        if (!executableName.Equals("python", StringComparison.OrdinalIgnoreCase)
            && !executableName.Equals("python3", StringComparison.OrdinalIgnoreCase)) return false;
        var aliasDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps");
        if (!string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(directory)), aliasDirectory,
                StringComparison.OrdinalIgnoreCase)) return false;
        try { return new FileInfo(path).Length == 0; } catch { return false; }
    }

    private static int ExecutablePreference(string path) =>
        Path.GetExtension(path).ToLowerInvariant() switch
        {
            ".exe" => 0,
            ".com" => 1,
            ".cmd" => 2,
            ".bat" => 3,
            _ => 4,
        };

    private static IEnumerable<string> UserDirectories(ToolId id)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        yield return Path.Combine(home, "scoop", "shims");
        yield return Path.Combine(roaming, "Python", "Scripts");
        foreach (var scripts in EnumeratePythonUserScripts(roaming)) yield return scripts;
        yield return Path.Combine(local, "Programs", "Python");
        if (id == ToolId.Npm)
        {
            var nvmHome = Environment.GetEnvironmentVariable("NVM_HOME");
            if (!string.IsNullOrWhiteSpace(nvmHome)) yield return nvmHome;
            yield return Path.Combine(roaming, "nvm");
            yield return Path.Combine(home, ".volta", "bin");
        }
    }

    private static IEnumerable<string> EnumeratePythonUserScripts(string roaming)
    {
        // pip --user installs entry points under %APPDATA%\Python\Python3xx\Scripts (pipx lands here).
        var root = Path.Combine(roaming, "Python");
        if (!Directory.Exists(root)) yield break;
        IEnumerable<string> matches;
        try { matches = Directory.EnumerateDirectories(root, "Python3*").OrderDescending().ToList(); }
        catch { yield break; }
        foreach (var match in matches) yield return Path.Combine(match, "Scripts");
    }
}
