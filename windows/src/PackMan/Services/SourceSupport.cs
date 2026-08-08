namespace PackMan.Services;

public static class SourceSupport
{
    public const int ErrorAccessDenied = 5;
    public const int ErrorCancelled = 1223;
    public const int ErrorElevationRequired = 740;
    public const int HResultAccessDenied = unchecked((int)0x80070005);
    public const int HResultFileNotFound = unchecked((int)0x80070002);

    public static string ErrorText(ProcessResult result)
    {
        var error = string.IsNullOrWhiteSpace(result.StdErr) ? result.StdOut : result.StdErr;
        error = error.Trim();
        return string.IsNullOrWhiteSpace(error) ? $"exit code {result.ExitCode}" : error;
    }

    public static bool IsElevationSignature(ProcessResult result, string text) =>
        result.ExitCode is ErrorAccessDenied or ErrorCancelled or ErrorElevationRequired
            or HResultAccessDenied or HResultFileNotFound
        || text.Contains("access is denied", StringComparison.OrdinalIgnoreCase)
        || text.Contains("administrator", StringComparison.OrdinalIgnoreCase)
        || text.Contains("elevat", StringComparison.OrdinalIgnoreCase)
        // WinGet wraps installer failures: the outer exit code is 0x8A150006 and the inner
        // installer code (1223 = the installer spawned its own UAC prompt that was dismissed)
        // only appears in the output text.
        || text.Contains("exit code: 1223", StringComparison.OrdinalIgnoreCase)
        || text.Contains("exit code: 0x80070005", StringComparison.OrdinalIgnoreCase)
        || text.Contains("exit code: 0x80070002", StringComparison.OrdinalIgnoreCase);

    public static SourceException CommandFailure(string command, ProcessResult result)
    {
        var text = ErrorText(result);
        return new SourceException(SourceIssueKind.Command,
            $"{command} failed ({result.ExitCode}): {text}", IsElevationSignature(result, text));
    }
}
