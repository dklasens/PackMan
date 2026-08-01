using System.Text.RegularExpressions;

namespace UpdateManager.Services;

public static class PackageIdValidator
{
    private static readonly Regex ValidId = new(@"^[A-Za-z0-9@._/\-]+$", RegexOptions.Compiled);

    public static bool IsValid(string? id)
    {
        if (string.IsNullOrWhiteSpace(id) || id.Length > 256)
            return false;

        if (id[0] == '-')
            return false;

        return ValidId.IsMatch(id);
    }
}
