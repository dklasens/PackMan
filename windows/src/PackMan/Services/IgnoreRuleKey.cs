namespace PackMan.Services;

internal static class IgnoreRuleKey
{
    // Versioned, escaped fields prevent collisions between repository, ID and version.
    // Legacy rules deliberately remain repository-wide until the user removes them.
    internal static string Create(SourceId source, string? repository, string packageId, string? version = null) =>
        $"v2|{source}|{Uri.EscapeDataString(repository ?? "")}|{Uri.EscapeDataString(CanonicalId(source, packageId))}|{Uri.EscapeDataString(version ?? "")}";

    private static string CanonicalId(SourceId source, string id) => source == SourceId.Pip
        ? System.Text.RegularExpressions.Regex.Replace(id, "[-_.]+", "-").ToLowerInvariant() : id;

    internal static bool IsIgnored(IReadOnlySet<string> rules, SourceId source, PackageInfo package) =>
        rules.Contains(Create(source, package.Repository, package.Id))
        || rules.Contains(Create(source, package.Repository, package.Id, package.AvailableVersion))
        || rules.Contains($"{source}:{package.Id}")
        || rules.Contains($"{source}:{package.Id}@{package.AvailableVersion}");

    internal static bool TryGetSource(string rule, out SourceId source)
    {
        var name = rule.StartsWith("v2|", StringComparison.OrdinalIgnoreCase)
            ? rule.Split('|').ElementAtOrDefault(1) : rule.Split(':')[0];
        return Enum.TryParse(name, true, out source) && Enum.IsDefined(source);
    }

    internal static string Display(string rule)
    {
        var parts = rule.Split('|');
        if (parts.Length != 5 || !parts[0].Equals("v2", StringComparison.OrdinalIgnoreCase))
            return rule + " (legacy rule, all repositories)";
        var repository = Uri.UnescapeDataString(parts[2]);
        var package = Uri.UnescapeDataString(parts[3]);
        var version = Uri.UnescapeDataString(parts[4]);
        return $"{parts[1]} / {(repository.Length == 0 ? "default" : repository)}: {package}"
            + (version.Length == 0 ? " (all versions)" : $" @ {version}");
    }
}
