namespace PackMan.Services;

public static class SourceSupport
{
    public static string ErrorText(ProcessResult result)
    {
        var error = string.IsNullOrWhiteSpace(result.StdErr) ? result.StdOut : result.StdErr;
        error = error.Trim();
        return string.IsNullOrWhiteSpace(error) ? $"exit code {result.ExitCode}" : error;
    }

    public static SourceException CommandFailure(string command, ProcessResult result)
    {
        var text = ErrorText(result);
        var elevation = result.ExitCode is 5 or 740
            || text.Contains("access is denied", StringComparison.OrdinalIgnoreCase)
            || text.Contains("administrator", StringComparison.OrdinalIgnoreCase)
            || text.Contains("elevat", StringComparison.OrdinalIgnoreCase);
        return new SourceException(SourceIssueKind.Command,
            $"{command} failed ({result.ExitCode}): {text}", elevation);
    }
}
