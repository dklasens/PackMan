using System.Text.RegularExpressions;

namespace PackMan.Services;

public static class PackageIdValidator
{
    private static readonly Regex ValidId = new(@"^[A-Za-z0-9@._/+\-]+$", RegexOptions.Compiled);

    public static bool IsValid(string? id)
    {
        if (string.IsNullOrWhiteSpace(id) || id.Length > 256)
            return false;

        if (id[0] == '-')
            return false;

        return ValidId.IsMatch(id);
    }

    public static bool IsValidVersion(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 128)
            return false;
        return value.All(c => char.IsLetterOrDigit(c) || c is '.' or '-' or '+' or '_' or ':' or '~');
    }
}
