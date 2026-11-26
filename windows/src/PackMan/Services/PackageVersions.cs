using System.Text.RegularExpressions;

namespace PackMan.Services;

internal static class PackageVersions
{
    // PEP 440 public version ordering, including epochs, pre/post/dev releases and local labels.
    // Unknown schemes deliberately return null rather than claiming a successful verification.
    private static readonly Regex PythonPattern = new(
        @"^v?(?:(?<epoch>[0-9]+)!)?(?<release>[0-9]+(?:\.[0-9]+)*)(?:[-_.]?(?<pre>a|b|rc|alpha|beta|pre|preview|c)[-_.]?(?<preN>[0-9]*))?(?:(?:-(?<postN1>[0-9]+))|(?:[-_.]?(?:post|rev|r)[-_.]?(?<postN2>[0-9]*)))?(?:[-_.]?(?<dev>dev)[-_.]?(?<devN>[0-9]*))?(?:\+(?<local>[a-z0-9]+(?:[-_.][a-z0-9]+)*))?$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private sealed record PythonVersion(long Epoch, long[] Release, int Pre, long PreNumber, long Post, long Dev, string[] Local);
    internal static bool IsPythonVersion(string? version) => TryPython(version, out _);

    internal static int? ComparePython(string? left, string? right)
    {
        if (!TryPython(left, out var a) || !TryPython(right, out var b)) return null;
        var comparison = a.Epoch.CompareTo(b.Epoch);
        if (comparison != 0) return comparison;
        comparison = CompareNumbers(a.Release, b.Release);
        if (comparison != 0) return comparison;
        comparison = a.Pre.CompareTo(b.Pre);
        if (comparison != 0) return comparison;
        comparison = a.PreNumber.CompareTo(b.PreNumber);
        if (comparison != 0) return comparison;
        comparison = a.Post.CompareTo(b.Post);
        if (comparison != 0) return comparison;
        comparison = a.Dev.CompareTo(b.Dev);
        if (comparison != 0) return comparison;
        for (int i = 0; i < Math.Min(a.Local.Length, b.Local.Length); i++)
        {
            bool aNumeric = long.TryParse(a.Local[i], out long x), bNumeric = long.TryParse(b.Local[i], out long y);
            comparison = aNumeric && bNumeric ? x.CompareTo(y)
                : aNumeric != bNumeric ? (aNumeric ? 1 : -1) : string.CompareOrdinal(a.Local[i], b.Local[i]);
            if (comparison != 0) return comparison;
        }
        return a.Local.Length.CompareTo(b.Local.Length);
    }

    private static bool TryPython(string? value, out PythonVersion version)
    {
        version = null!;
        if (string.IsNullOrWhiteSpace(value) || value.Length > 128) return false;
        var match = PythonPattern.Match(value.Trim());
        if (!match.Success) return false;
        long Number(string name, long absent = 0) => !match.Groups[name].Success ? absent
            : match.Groups[name].Value.Length == 0 ? 0 : long.Parse(match.Groups[name].Value, System.Globalization.CultureInfo.InvariantCulture);
        try
        {
            var release = match.Groups["release"].Value.Split('.').Select(v => long.Parse(v, System.Globalization.CultureInfo.InvariantCulture)).ToArray();
            var post = Number("postN1", Number("postN2", -1));
            var dev = Number("devN", long.MaxValue);
            var pre = match.Groups["pre"].Value.ToLowerInvariant() switch
            {
                "a" or "alpha" => 0, "b" or "beta" => 1, "rc" or "c" or "pre" or "preview" => 2,
                _ => post < 0 && match.Groups["dev"].Success ? -1 : 3,
            };
            var local = match.Groups["local"].Success
                ? Regex.Split(match.Groups["local"].Value.ToLowerInvariant(), "[-_.]") : [];
            version = new(Number("epoch"), release, pre, Number("preN"), post, dev, local);
            return true;
        }
        catch (OverflowException) { return false; }
    }

    // NuGet additionally supports a fourth numeric revision; prerelease ordering is SemVer-like.
    internal static int? CompareNuGet(string? left, string? right)
    {
        if (!TryNuGet(left, out var a, out var aPre) || !TryNuGet(right, out var b, out var bPre)) return null;
        var core = CompareNumbers(a, b);
        return core != 0 ? core : SemanticVersion.Compare("0.0.0" + aPre.ToLowerInvariant(), "0.0.0" + bPre.ToLowerInvariant());
    }

    // WinGet uses a broader set of version conventions than SemVer. Compare only numeric
    // dotted versions when their ordering is unambiguous; exact strings still verify.
    internal static int? CompareWinget(string? left, string? right)
    {
        return TryNumbers(left, out var a) && TryNumbers(right, out var b) ? CompareNumbers(a, b) : null;
    }

    private static bool TryNuGet(string? value, out long[] release, out string pre)
    {
        release = []; pre = "";
        if (string.IsNullOrWhiteSpace(value)) return false;
        var text = value.Trim().Split('+')[0];
        var separator = text.IndexOf('-');
        if (separator >= 0)
        {
            pre = text[separator..];
            text = text[..separator];
            if (!Regex.IsMatch(pre, @"^-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*$")) return false;
        }
        return TryNumbers(text, out release) && release.Length <= 4;
    }

    private static bool TryNumbers(string? text, out long[] values)
    {
        values = [];
        if (string.IsNullOrWhiteSpace(text) || text.Length > 128) return false;
        var parts = text.Trim().Split('.');
        values = new long[parts.Length];
        for (int i = 0; i < parts.Length; i++)
            if (!long.TryParse(parts[i], System.Globalization.NumberStyles.None,
                System.Globalization.CultureInfo.InvariantCulture, out values[i])) return false;
        return true;
    }

    private static int CompareNumbers(long[] left, long[] right)
    {
        for (int i = 0; i < Math.Max(left.Length, right.Length); i++)
        {
            var result = (i < left.Length ? left[i] : 0).CompareTo(i < right.Length ? right[i] : 0);
            if (result != 0) return result;
        }
        return 0;
    }
}
