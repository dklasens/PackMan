namespace PackMan.Services;

/// <summary>
/// Just enough of semver 2.0.0 to decide whether an offered version really moves a package
/// forward. npm dist-tags are mutable and a globally installed package can sit on a
/// prerelease channel that runs ahead of "latest", so npm outdated happily reports a
/// "latest" that is older than what is installed.
/// </summary>
public static class SemanticVersion
{
    /// <summary>
    /// True when <paramref name="candidate"/> is newer than <paramref name="installed"/>, or
    /// when either side cannot be parsed. Unparseable versions stay visible on purpose: an
    /// unfamiliar versioning scheme should not silently hide an update, and the comparison is
    /// only here to suppress moves that are provably backwards.
    /// </summary>
    public static bool IsUpgrade(string? installed, string? candidate)
    {
        if (string.IsNullOrWhiteSpace(candidate)) return false;
        if (string.IsNullOrWhiteSpace(installed)) return true;
        if (string.Equals(installed.Trim(), candidate.Trim(), StringComparison.Ordinal)) return false;
        return Compare(candidate, installed) is null or > 0;
    }

    /// <summary>
    /// Negative when <paramref name="left"/> sorts before <paramref name="right"/>, positive
    /// when after, zero when equal, and null when either side is not a semver version.
    /// </summary>
    public static int? Compare(string? left, string? right)
    {
        if (!TryParse(left, out var a) || !TryParse(right, out var b)) return null;
        for (var i = 0; i < a.Core.Length; i++)
        {
            var core = a.Core[i].CompareTo(b.Core[i]);
            if (core != 0) return core;
        }
        return ComparePrerelease(a.Prerelease, b.Prerelease);
    }

    private static bool TryParse(string? value, out (long[] Core, string Prerelease) parsed)
    {
        parsed = default;
        if (string.IsNullOrWhiteSpace(value)) return false;
        var text = value.Trim();
        if (text.StartsWith('v') || text.StartsWith('=')) text = text[1..];

        // Build metadata never participates in precedence.
        var build = text.IndexOf('+');
        if (build >= 0) text = text[..build];

        // The version core is digits and dots only, so the first hyphen starts the prerelease.
        var hyphen = text.IndexOf('-');
        var prerelease = hyphen >= 0 ? text[(hyphen + 1)..] : string.Empty;
        var core = hyphen >= 0 ? text[..hyphen] : text;

        var parts = core.Split('.');
        if (parts.Length is 0 or > 3) return false;
        var numbers = new long[3];
        for (var i = 0; i < parts.Length; i++)
        {
            if (!long.TryParse(parts[i], System.Globalization.NumberStyles.None,
                    System.Globalization.CultureInfo.InvariantCulture, out numbers[i])) return false;
        }
        parsed = (numbers, prerelease);
        return true;
    }

    private static int ComparePrerelease(string left, string right)
    {
        // A release outranks any prerelease of the same core version.
        if (left.Length == 0 && right.Length == 0) return 0;
        if (left.Length == 0) return 1;
        if (right.Length == 0) return -1;

        var leftParts = left.Split('.');
        var rightParts = right.Split('.');
        for (var i = 0; i < Math.Max(leftParts.Length, rightParts.Length); i++)
        {
            if (i >= leftParts.Length) return -1;
            if (i >= rightParts.Length) return 1;
            var comparison = CompareIdentifier(leftParts[i], rightParts[i]);
            if (comparison != 0) return comparison;
        }
        return 0;
    }

    private static int CompareIdentifier(string left, string right)
    {
        var leftNumeric = IsNumeric(left);
        var rightNumeric = IsNumeric(right);
        if (leftNumeric && rightNumeric) return CompareNumeric(left, right);
        // Numeric identifiers always have lower precedence than alphanumeric ones.
        if (leftNumeric) return -1;
        if (rightNumeric) return 1;
        return Math.Sign(string.CompareOrdinal(left, right));
    }

    private static bool IsNumeric(string value) => value.Length > 0 && value.All(char.IsAsciiDigit);

    // Compared without parsing so arbitrarily long build counters cannot overflow.
    private static int CompareNumeric(string left, string right)
    {
        var a = left.TrimStart('0');
        var b = right.TrimStart('0');
        return a.Length != b.Length ? a.Length.CompareTo(b.Length) : Math.Sign(string.CompareOrdinal(a, b));
    }
}
