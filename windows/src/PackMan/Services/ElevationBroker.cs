using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace PackMan.Services;

public interface IElevationBroker
{
    Task<ProcessResult> RunAsync(ProcessInvocation invocation,
        IProgress<ProcessOutputEvent>? output, CancellationToken cancellationToken);
}

public sealed class ElevationBroker : IElevationBroker, IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private static readonly Regex SafePipeName = new("^[a-zA-Z0-9-]{1,80}$", RegexOptions.Compiled);
    private static readonly TimeSpan HelperIdleTimeout = TimeSpan.FromMinutes(10);
    private readonly SemaphoreSlim _sessionLock = new(1, 1);
    private Session? _session;

    public async Task<ProcessResult> RunAsync(ProcessInvocation invocation,
        IProgress<ProcessOutputEvent>? output, CancellationToken cancellationToken)
    {
        var session = await GetSessionAsync(cancellationToken);
        await session.Gate.WaitAsync(cancellationToken);
        try
        {
            await WriteAsync(session.Pipe, session.WriteLock,
                new BrokerMessage("run", session.Token, Invocation: invocation), cancellationToken);
            using var registration = cancellationToken.Register(() =>
            {
                try { WriteAsync(session.Pipe, session.WriteLock, new BrokerMessage("cancel", session.Token), CancellationToken.None).GetAwaiter().GetResult(); }
                catch { }
            });
            while (await session.Reader.ReadLineAsync(CancellationToken.None) is { } line)
            {
                var message = JsonSerializer.Deserialize<BrokerMessage>(line, JsonOptions)
                    ?? throw new InvalidOperationException("The elevated helper returned an invalid response.");
                if (!string.Equals(message.Token, session.Token, StringComparison.Ordinal)) continue;
                if (message.Type == "output" && message.Output is not null) output?.Report(message.Output);
                if (message.Type == "complete" && message.Result is not null) return message.Result;
                if (message.Type == "cancelled") throw new OperationCanceledException(cancellationToken);
                if (message.Type == "error") throw new SourceException(SourceIssueKind.Command,
                    message.Error ?? "The elevated command failed.");
            }
            throw new SourceException(SourceIssueKind.Command,
                "The elevated helper stopped unexpectedly. Retry the update.");
        }
        finally { session.Gate.Release(); }
    }

    public void Dispose()
    {
        _session?.Dispose();
        _session = null;
        _sessionLock.Dispose();
    }

    private async Task<Session> GetSessionAsync(CancellationToken cancellationToken)
    {
        await _sessionLock.WaitAsync(cancellationToken);
        try
        {
            if (_session is { } current && !current.Helper.HasExited && current.Pipe.IsConnected)
                return current;
            _session?.Dispose();
            _session = await StartSessionAsync(cancellationToken);
            return _session;
        }
        finally { _sessionLock.Release(); }
    }

    private static async Task<Session> StartSessionAsync(CancellationToken cancellationToken)
    {
        var pipeName = $"packman-{Guid.NewGuid():N}";
        var token = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(24));
        var server = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        try
        {
            var executable = Environment.ProcessPath ?? throw new InvalidOperationException("PackMan executable path is unavailable.");
            var start = new ProcessStartInfo(executable)
            {
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            start.ArgumentList.Add("--elevated-helper");
            start.ArgumentList.Add(pipeName);
            start.ArgumentList.Add(token);
            Process helper;
            try
            {
                helper = Process.Start(start) ?? throw new InvalidOperationException("Could not start the elevated helper.");
            }
            catch (Win32Exception ex) when (ex.NativeErrorCode is 1223)
            {
                throw new SourceException(SourceIssueKind.Command,
                    "Administrator approval was declined; the update did not run.", canRetryElevated: true);
            }
            await server.WaitForConnectionAsync(cancellationToken);
            return new Session(helper, server, token);
        }
        catch
        {
            server.Dispose();
            throw;
        }
    }

    public static bool IsHelper(IReadOnlyList<string> args) =>
        args.Count == 3 && args[0] == "--elevated-helper" && SafePipeName.IsMatch(args[1]);

    public static async Task<int> RunHelperAsync(IReadOnlyList<string> args)
    {
        if (!IsHelper(args)) return 2;
        try
        {
            return await RunHelperCoreAsync(args);
        }
        catch (Exception ex)
        {
            LogHelperFailure(ex);
            return 1;
        }
    }

    internal static void LogHelperFailure(Exception ex)
    {
        try
        {
            var directory = Path.Combine(Path.GetTempPath(), "PackMan");
            Directory.CreateDirectory(directory);
            File.AppendAllText(Path.Combine(directory, "helper-error.log"),
                $"[{DateTimeOffset.Now:O}] {ex}{Environment.NewLine}");
        }
        catch { }
    }

    private static async Task<int> RunHelperCoreAsync(IReadOnlyList<string> args)
    {
        var pipeName = args[1];
        var expectedToken = args[2];
        // The server retains CurrentUserOnly so other Windows users cannot connect. Do not use
        // CurrentUserOnly on this client: on Windows its owner check also requires the server and
        // client to have the same elevation level, while this helper is intentionally elevated.
        await using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut,
            PipeOptions.Asynchronous);
        await client.ConnectAsync(15_000);
        using var reader = new StreamReader(client, Encoding.UTF8, false, 1024, leaveOpen: true);
        using var writeLock = new SemaphoreSlim(1, 1);
        var progress = new DelegateProgress<ProcessOutputEvent>(item =>
            WriteAsync(client, writeLock, new BrokerMessage("output", expectedToken, Output: item), CancellationToken.None)
                .GetAwaiter().GetResult());

        // Keep exactly one read pending for the lifetime of the pipe. Starting a new idle read
        // after a command won the WhenAny race used to overlap the still-pending control read and
        // terminate the helper with "The stream is currently in use" after its first command.
        var readTask = reader.ReadLineAsync();
        Task<BrokerMessage>? runTask = null;
        CancellationTokenSource? runCts = null;
        while (true)
        {
            if (runTask is null)
            {
                string? line;
                try { line = await readTask.WaitAsync(HelperIdleTimeout); }
                catch (TimeoutException) { return 0; }
                if (line is null) return 0;
                readTask = reader.ReadLineAsync();

                var request = JsonSerializer.Deserialize<BrokerMessage>(line, JsonOptions);
                if (request?.Type != "run" || request.Token != expectedToken || request.Invocation is null) continue;

                runCts = new CancellationTokenSource();
                runTask = RunAndRespondAsync(request.Invocation, progress, expectedToken, runCts);
                continue;
            }

            var completed = await Task.WhenAny(runTask, readTask);
            if (completed == readTask)
            {
                var controlLine = await readTask;
                if (controlLine is null)
                {
                    runCts!.Cancel();
                    try { await runTask; } catch { }
                    return 0;
                }
                readTask = reader.ReadLineAsync();
                var control = JsonSerializer.Deserialize<BrokerMessage>(controlLine, JsonOptions);
                if (control?.Type == "cancel" && control.Token == expectedToken) runCts!.Cancel();
                continue;
            }

            await WriteAsync(client, writeLock, await runTask, CancellationToken.None);
            runCts!.Dispose();
            runCts = null;
            runTask = null;
        }
    }

    private static async Task<BrokerMessage> RunAndRespondAsync(ProcessInvocation invocation,
        IProgress<ProcessOutputEvent> progress, string token, CancellationTokenSource cts)
    {
        try
        {
            var result = await ProcessRunner.RunLocalAsync(invocation, progress, cts.Token);
            return new("complete", token, Result: result);
        }
        catch (OperationCanceledException) { return new("cancelled", token); }
        catch (Exception ex) { return new("error", token, Error: ex.Message); }
    }

    private static async Task WriteAsync(Stream stream, SemaphoreSlim writeLock,
        BrokerMessage message, CancellationToken cancellationToken)
    {
        await writeLock.WaitAsync(cancellationToken);
        try
        {
            var payload = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(message, JsonOptions) + "\n");
            await stream.WriteAsync(payload, cancellationToken);
        }
        finally { writeLock.Release(); }
    }

    private sealed class Session : IDisposable
    {
        public Session(Process helper, NamedPipeServerStream pipe, string token)
        {
            Helper = helper;
            Pipe = pipe;
            Token = token;
            Reader = new StreamReader(pipe, Encoding.UTF8, false, 1024, leaveOpen: true);
        }

        public Process Helper { get; }
        public NamedPipeServerStream Pipe { get; }
        public string Token { get; }
        public StreamReader Reader { get; }
        public SemaphoreSlim Gate { get; } = new(1, 1);
        public SemaphoreSlim WriteLock { get; } = new(1, 1);

        public void Dispose()
        {
            try { Reader.Dispose(); } catch { }
            try { Pipe.Dispose(); } catch { }
            Helper.Dispose();
        }
    }

    private sealed record BrokerMessage(
        string Type,
        string Token,
        ProcessInvocation? Invocation = null,
        ProcessOutputEvent? Output = null,
        ProcessResult? Result = null,
        string? Error = null);
}
