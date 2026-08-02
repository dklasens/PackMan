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

public sealed class ElevationBroker : IElevationBroker
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private static readonly Regex SafePipeName = new("^[a-zA-Z0-9-]{1,80}$", RegexOptions.Compiled);

    public async Task<ProcessResult> RunAsync(ProcessInvocation invocation,
        IProgress<ProcessOutputEvent>? output, CancellationToken cancellationToken)
    {
        var pipeName = $"packman-{Guid.NewGuid():N}";
        var token = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(24));
        await using var server = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
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
        using var helper = Process.Start(start) ?? throw new InvalidOperationException("Could not start the elevated helper.");

        await server.WaitForConnectionAsync(cancellationToken);
        using var reader = new StreamReader(server, Encoding.UTF8, false, 1024, leaveOpen: true);
        using var writer = new StreamWriter(server, Encoding.UTF8, 1024, leaveOpen: true) { AutoFlush = true };
        var writeLock = new SemaphoreSlim(1, 1);
        await WriteAsync(writer, writeLock, new BrokerMessage("run", token, Invocation: invocation), cancellationToken);
        using var registration = cancellationToken.Register(() =>
        {
            try { WriteAsync(writer, writeLock, new BrokerMessage("cancel", token), CancellationToken.None).GetAwaiter().GetResult(); }
            catch { }
        });

        while (await reader.ReadLineAsync(CancellationToken.None) is { } line)
        {
            var message = JsonSerializer.Deserialize<BrokerMessage>(line, JsonOptions)
                ?? throw new InvalidOperationException("The elevated helper returned an invalid response.");
            if (!string.Equals(message.Token, token, StringComparison.Ordinal)) continue;
            if (message.Type == "output" && message.Output is not null) output?.Report(message.Output);
            if (message.Type == "complete" && message.Result is not null) return message.Result;
            if (message.Type == "cancelled") throw new OperationCanceledException(cancellationToken);
            if (message.Type == "error") throw new SourceException(SourceIssueKind.Command,
                message.Error ?? "The elevated command failed.");
        }
        throw new InvalidOperationException("The elevated helper disconnected unexpectedly.");
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
        var line = await reader.ReadLineAsync();
        var request = line is null ? null : JsonSerializer.Deserialize<BrokerMessage>(line, JsonOptions);
        if (request?.Type != "run" || request.Token != expectedToken || request.Invocation is null) return 3;

        using var cts = new CancellationTokenSource();
        var writeLock = new SemaphoreSlim(1, 1);
        var listenForCancel = Task.Run(async () =>
        {
            while (await reader.ReadLineAsync() is { } controlLine)
            {
                var control = JsonSerializer.Deserialize<BrokerMessage>(controlLine, JsonOptions);
                if (control?.Type == "cancel" && control.Token == expectedToken) { cts.Cancel(); return; }
            }
        });
        var progress = new DelegateProgress<ProcessOutputEvent>(item =>
            WriteAsync(writer, writeLock, new BrokerMessage("output", expectedToken, Output: item), CancellationToken.None)
                .GetAwaiter().GetResult());
        try
        {
            var result = await ProcessRunner.RunLocalAsync(request.Invocation, progress, cts.Token);
            await WriteAsync(writer, writeLock, new BrokerMessage("complete", expectedToken, Result: result), CancellationToken.None);
            return 0;
        }
        catch (OperationCanceledException)
        {
            await WriteAsync(writer, writeLock, new BrokerMessage("cancelled", expectedToken), CancellationToken.None);
            return 4;
        }
        catch (Exception ex)
        {
            await WriteAsync(writer, writeLock, new BrokerMessage("error", expectedToken, Error: ex.Message), CancellationToken.None);
            return 1;
        }
        finally
        {
            cts.Cancel();
            _ = listenForCancel;
        }
    }

    private static async Task WriteAsync(StreamWriter writer, SemaphoreSlim writeLock,
        BrokerMessage message, CancellationToken cancellationToken)
    {
        await writeLock.WaitAsync(cancellationToken);
        try { await writer.WriteLineAsync(JsonSerializer.Serialize(message, JsonOptions)); }
        finally { writeLock.Release(); }
    }

    private sealed record BrokerMessage(
        string Type,
        string Token,
        ProcessInvocation? Invocation = null,
        ProcessOutputEvent? Output = null,
        ProcessResult? Result = null,
        string? Error = null);
}
