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
            await WriteAsync(session.Writer, session.WriteLock,
                new BrokerMessage("run", session.Token, Invocation: invocation), cancellationToken);
            using var registration = cancellationToken.Register(() =>
            {
                try { WriteAsync(session.Writer, session.WriteLock, new BrokerMessage("cancel", session.Token), CancellationToken.None).GetAwaiter().GetResult(); }
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
        var pipeName = args[1];
        var expectedToken = args[2];
        await using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await client.ConnectAsync(15_000);
        using var reader = new StreamReader(client, Encoding.UTF8, false, 1024, leaveOpen: true);
        using var writer = new StreamWriter(client, Encoding.UTF8, 1024, leaveOpen: true) { AutoFlush = true };
        var writeLock = new SemaphoreSlim(1, 1);
        var progress = new DelegateProgress<ProcessOutputEvent>(item =>
            WriteAsync(writer, writeLock, new BrokerMessage("output", expectedToken, Output: item), CancellationToken.None)
                .GetAwaiter().GetResult());

        while (true)
        {
            string? line;
            using (var idle = new CancellationTokenSource(HelperIdleTimeout))
            {
                try { line = await reader.ReadLineAsync(idle.Token); }
                catch (OperationCanceledException) { return 0; }
            }
            if (line is null) return 0;
            var request = JsonSerializer.Deserialize<BrokerMessage>(line, JsonOptions);
            if (request?.Type != "run" || request.Token != expectedToken || request.Invocation is null) continue;

            using var cts = new CancellationTokenSource();
            var runTask = RunAndRespondAsync(request.Invocation, progress, expectedToken, cts);
            while (!runTask.IsCompleted)
            {
                var readTask = reader.ReadLineAsync();
                var completed = await Task.WhenAny(runTask, readTask);
                if (completed == runTask) break;
                var controlLine = await readTask;
                if (controlLine is null)
                {
                    cts.Cancel();
                    try { await runTask; } catch { }
                    return 0;
                }
                var control = JsonSerializer.Deserialize<BrokerMessage>(controlLine, JsonOptions);
                if (control?.Type == "cancel" && control.Token == expectedToken) cts.Cancel();
            }
            await WriteAsync(writer, writeLock, await runTask, CancellationToken.None);
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

    private static async Task WriteAsync(StreamWriter writer, SemaphoreSlim writeLock,
        BrokerMessage message, CancellationToken cancellationToken)
    {
        await writeLock.WaitAsync(cancellationToken);
        try { await writer.WriteLineAsync(JsonSerializer.Serialize(message, JsonOptions)); }
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
            Writer = new StreamWriter(pipe, Encoding.UTF8, 1024, leaveOpen: true) { AutoFlush = true };
        }

        public Process Helper { get; }
        public NamedPipeServerStream Pipe { get; }
        public string Token { get; }
        public StreamReader Reader { get; }
        public StreamWriter Writer { get; }
        public SemaphoreSlim Gate { get; } = new(1, 1);
        public SemaphoreSlim WriteLock { get; } = new(1, 1);

        public void Dispose()
        {
            try { Writer.Dispose(); } catch { }
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
