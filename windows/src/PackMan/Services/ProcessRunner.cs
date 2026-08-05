using System.ComponentModel;
using System.Diagnostics;
using System.Security.Principal;
using System.Text;

namespace PackMan.Services;

public enum ProcessOutputStream { StandardOutput, StandardError }
public sealed record ProcessOutputEvent(ProcessOutputStream Stream, string Line);
public sealed record ProcessResult(int ExitCode, string StdOut, string StdErr)
{
    public bool Success => ExitCode == 0;
}

public sealed record ProcessInvocation(
    string FileName,
    IReadOnlyList<string> Arguments,
    IReadOnlyDictionary<string, string>? Environment = null,
    TimeSpan? Timeout = null,
    bool Elevated = false);

public interface IProcessRunner
{
    Task<ProcessResult> RunAsync(
        ProcessInvocation invocation,
        IProgress<ProcessOutputEvent>? output = null,
        CancellationToken cancellationToken = default);
}

public sealed class ProcessRunner(IElevationBroker elevationBroker) : IProcessRunner
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromMinutes(3);

    public Task<ProcessResult> RunAsync(ProcessInvocation invocation,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default) =>
        invocation.Elevated && !IsCurrentProcessElevated
            ? elevationBroker.RunAsync(invocation with { Elevated = false }, output, cancellationToken)
            : RunLocalAsync(invocation, output, cancellationToken);

    internal static bool IsCurrentProcessElevated { get; } = CheckElevation();

    private static bool CheckElevation()
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch { return false; }
    }

    internal static async Task<ProcessResult> RunLocalAsync(ProcessInvocation invocation,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        var startInfo = CreateStartInfo(invocation);
        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        var stdoutClosed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var stderrClosed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var sync = new object();

        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is null) { stdoutClosed.TrySetResult(); return; }
            lock (sync) stdout.AppendLine(e.Data);
            output?.Report(new ProcessOutputEvent(ProcessOutputStream.StandardOutput, e.Data));
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is null) { stderrClosed.TrySetResult(); return; }
            lock (sync) stderr.AppendLine(e.Data);
            output?.Report(new ProcessOutputEvent(ProcessOutputStream.StandardError, e.Data));
        };

        try
        {
            if (!process.Start()) throw new InvalidOperationException($"Could not start '{invocation.FileName}'.");
        }
        catch (Win32Exception ex)
        {
            throw new SourceException(SourceIssueKind.Command,
                $"Could not start '{Path.GetFileName(invocation.FileName)}': {ex.Message}",
                ex.NativeErrorCode is 5 or 740);
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        var timeout = invocation.Timeout ?? DefaultTimeout;
        using var timeoutCts = new CancellationTokenSource(timeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
        try
        {
            await process.WaitForExitAsync(linked.Token);
            await Task.WhenAll(stdoutClosed.Task, stderrClosed.Task);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            try { await process.WaitForExitAsync(CancellationToken.None); } catch { }
            if (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
                throw new TimeoutException($"'{Path.GetFileName(invocation.FileName)}' timed out after {timeout.TotalSeconds:0}s.");
            throw;
        }

        lock (sync)
            return new ProcessResult(process.ExitCode, stdout.ToString(), stderr.ToString());
    }

    private static ProcessStartInfo CreateStartInfo(ProcessInvocation invocation)
    {
        var extension = Path.GetExtension(invocation.FileName);
        var shellScript = extension.Equals(".cmd", StringComparison.OrdinalIgnoreCase)
            || extension.Equals(".bat", StringComparison.OrdinalIgnoreCase);
        var info = new ProcessStartInfo
        {
            FileName = shellScript ? "cmd.exe" : invocation.FileName,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        if (shellScript)
        {
            info.Arguments = "/d /s /c \"" + BuildCmdCommand(invocation.FileName, invocation.Arguments) + "\"";
        }
        else
        {
            foreach (var argument in invocation.Arguments) info.ArgumentList.Add(argument);
        }
        if (invocation.Environment is not null)
            foreach (var pair in invocation.Environment) info.Environment[pair.Key] = pair.Value;
        return info;
    }

    private static string BuildCmdCommand(string fileName, IReadOnlyList<string> arguments) =>
        QuoteForCmd(fileName) + (arguments.Count == 0 ? "" : " " + string.Join(" ", arguments.Select(QuoteForCmd)));

    private static string QuoteForCmd(string value)
    {
        if (value.Any(c => c is '\r' or '\n' or '&' or '|' or '<' or '>' or '^' or '%' or '!'))
            throw new SourceException(SourceIssueKind.Configuration, "An unsafe command argument was rejected.");
        return '"' + value.Replace("\"", "\"\"") + '"';
    }

    private static void TryKill(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch { }
    }
}

internal sealed class DelegateProgress<T>(Action<T> callback) : IProgress<T>
{
    public void Report(T value) => callback(value);
}
