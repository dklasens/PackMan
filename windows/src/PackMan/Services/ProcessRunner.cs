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
    bool Elevated = false,
    int? MaxCapturedOutputChars = null);

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
    public const int DiagnosticCaptureLimit = 64_000;

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
        cancellationToken.ThrowIfCancellationRequested();
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
            lock (sync) AppendCaptured(stdout, e.Data, invocation.MaxCapturedOutputChars);
            output?.Report(new ProcessOutputEvent(ProcessOutputStream.StandardOutput, e.Data));
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is null) { stderrClosed.TrySetResult(); return; }
            lock (sync) AppendCaptured(stderr, e.Data, invocation.MaxCapturedOutputChars);
            output?.Report(new ProcessOutputEvent(ProcessOutputStream.StandardError, e.Data));
        };

        try
        {
            if (!process.Start()) throw new InvalidOperationException($"Could not start '{invocation.FileName}'.");
        }
        catch (Win32Exception ex)
        {
            throw new SourceException(SourceIssueKind.ToolStart,
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
            await Task.WhenAll(stdoutClosed.Task, stderrClosed.Task).WaitAsync(linked.Token);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            try { await process.WaitForExitAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(10)); }
            catch { }
            if (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
                throw new TimeoutException($"'{Path.GetFileName(invocation.FileName)}' timed out after {timeout.TotalSeconds:0}s.");
            throw;
        }

        lock (sync)
            return new ProcessResult(process.ExitCode, stdout.ToString(), stderr.ToString());
    }

    private static void AppendCaptured(StringBuilder buffer, string line, int? limit)
    {
        buffer.AppendLine(line);
        if (limit is > 0 && buffer.Length > limit.Value)
            buffer.Remove(0, buffer.Length - limit.Value);
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

    internal static string QuoteForCmd(string value)
    {
        if (value.Any(c => c is '\r' or '\n' or '&' or '|' or '<' or '>' or '^' or '%' or '!'))
            throw new SourceException(SourceIssueKind.Configuration, "An unsafe command argument was rejected.");
        // Quote only when necessary: some .cmd shims (scoop) rewrite double quotes in %* to
        // single quotes, so unconditionally quoted arguments arrive corrupted.
        if (value.Length > 0 && !value.Any(c => char.IsWhiteSpace(c) || c is '"'))
            return value;
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

// Deliver command output in batches rather than posting one dispatcher operation per line.
// An explicit flush at operation completion records the last lines before history is saved.
internal sealed class BufferedProgress<T>(Action<T> callback) : IProgress<T>, IDisposable
{
    private readonly SynchronizationContext? _context = SynchronizationContext.Current;
    private readonly object _sync = new();
    private readonly Queue<T> _pending = new();
    private bool _scheduled;

    public void Report(T value)
    {
        lock (_sync)
        {
            if (_context is null) { callback(value); return; }
            _pending.Enqueue(value);
            if (_scheduled) return;
            _scheduled = true;
        }
        _context.Post(_ => Flush(), null);
    }

    public void Flush()
    {
        T[] items;
        lock (_sync)
        {
            items = _pending.ToArray();
            _pending.Clear();
            _scheduled = false;
        }
        foreach (var item in items) callback(item);
    }

    public void Dispose() => Flush();
}
