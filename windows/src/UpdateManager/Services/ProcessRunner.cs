using System.Diagnostics;
using System.IO;
using System.Text;

namespace UpdateManager.Services;

public sealed record ProcessResult(int ExitCode, string StdOut, string StdErr)
{
    public bool Success => ExitCode == 0;
}

public static class ProcessRunner
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromMinutes(3);

    public static async Task<ProcessResult> RunAsync(
        string fileName,
        string arguments,
        TimeSpan? timeout = null,
        IProgress<string>? outputLines = null,
        CancellationToken cancellationToken = default)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };

        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();

        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            stdout.AppendLine(e.Data);
            outputLines?.Report(e.Data);
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            stderr.AppendLine(e.Data);
        };

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        var effectiveTimeout = timeout ?? DefaultTimeout;
        using var timeoutCts = new CancellationTokenSource(effectiveTimeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);

        try
        {
            await process.WaitForExitAsync(linked.Token);
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); }
            catch { /* best effort */ }

            if (!cancellationToken.IsCancellationRequested)
                throw new TimeoutException($"'{fileName} {arguments}' timed out after {effectiveTimeout}.");
            throw;
        }

        return new ProcessResult(process.ExitCode, stdout.ToString(), stderr.ToString());
    }

    public static async Task<string?> ResolveExecutableAsync(string name, IEnumerable<string>? knownPaths = null)
    {
        if (knownPaths is not null)
        {
            foreach (var path in knownPaths)
            {
                if (File.Exists(path))
                    return path;
            }
        }

        var result = await RunAsync("where.exe", name, TimeSpan.FromSeconds(10));
        if (result.ExitCode != 0)
            return null;

        return result.StdOut
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(File.Exists)
            .OrderBy(p => ExtensionRank(Path.GetExtension(p)))
            .FirstOrDefault();

        static int ExtensionRank(string? extension) => extension?.ToLowerInvariant() switch
        {
            ".exe" => 0,
            ".cmd" => 1,
            ".bat" => 2,
            _ => 3,
        };
    }

    public static Task<ProcessResult> RunToolAsync(
        string toolPath,
        string arguments,
        TimeSpan? timeout = null,
        IProgress<string>? outputLines = null,
        CancellationToken cancellationToken = default)
    {
        var needsCmdHost = toolPath.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase)
            || toolPath.EndsWith(".bat", StringComparison.OrdinalIgnoreCase);

        return needsCmdHost
            ? ProcessRunner.RunAsync("cmd.exe", $"/c \"\"{toolPath}\" {arguments}\"", timeout, outputLines, cancellationToken)
            : ProcessRunner.RunAsync(toolPath, arguments, timeout, outputLines, cancellationToken);
    }
}
