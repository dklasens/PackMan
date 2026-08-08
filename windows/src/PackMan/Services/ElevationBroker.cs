using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

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
    private static readonly TimeSpan HelperConnectTimeout = TimeSpan.FromMinutes(5);
    private const long MaxHelperLogBytes = 256 * 1024;
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
                new BrokerMessage("run", Invocation: invocation), cancellationToken);
            using var registration = cancellationToken.Register(() =>
            {
                try { WriteAsync(session.Pipe, session.WriteLock, new BrokerMessage("cancel"), CancellationToken.None).GetAwaiter().GetResult(); }
                catch { }
            });
            while (await session.Reader.ReadLineAsync(CancellationToken.None) is { } line)
            {
                var message = JsonSerializer.Deserialize<BrokerMessage>(line, JsonOptions)
                    ?? throw new InvalidOperationException("The elevated helper returned an invalid response.");
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
        var executable = Environment.ProcessPath
            ?? throw new InvalidOperationException("PackMan executable path is unavailable.");
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        start.ArgumentList.Add("--elevated-helper");
        start.ArgumentList.Add(pipeName);
        Process helper;
        try
        {
            helper = Process.Start(start)
                ?? throw new InvalidOperationException("Could not start the elevated helper.");
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode is SourceSupport.ErrorCancelled)
        {
            throw new ElevationDeclinedException();
        }

        // The helper owns the pipe server and only exists after UAC approval, so poll until it
        // has created the pipe instead of assuming it is ready.
        var client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        try
        {
            var deadline = DateTime.UtcNow + HelperConnectTimeout;
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (helper.HasExited)
                    throw new SourceException(SourceIssueKind.Command,
                        "The elevated helper stopped before accepting a connection. Retry the update.");
                try
                {
                    await client.ConnectAsync(1000, cancellationToken);
                    break;
                }
                catch (TimeoutException)
                {
                    if (DateTime.UtcNow >= deadline)
                        throw new SourceException(SourceIssueKind.Command,
                            "Timed out waiting for the elevated helper to start. Retry the update.");
                }
                catch (Exception ex) when (ex is UnauthorizedAccessException or IOException)
                {
                    throw new SourceException(SourceIssueKind.Command,
                        $"Windows refused the connection to the elevated helper: {ex.Message} " +
                        "Report this if it persists; the update did not run.");
                }
            }
            return new Session(helper, client);
        }
        catch
        {
            client.Dispose();
            try { if (!helper.HasExited) helper.Kill(entireProcessTree: true); } catch { }
            helper.Dispose();
            throw;
        }
    }

    public static bool IsHelper(IReadOnlyList<string> args) =>
        args.Count == 2 && args[0] == "--elevated-helper" && SafePipeName.IsMatch(args[1]);

    public static async Task<int> RunHelperAsync(IReadOnlyList<string> args)
    {
        if (!IsHelper(args)) return 2;
        try
        {
            return await RunHelperCoreAsync(args[1]);
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
            var path = Path.Combine(directory, "helper-error.log");
            if (new FileInfo(path) is { Exists: true, Length: > MaxHelperLogBytes })
                File.WriteAllText(path, string.Empty);
            File.AppendAllText(path, $"[{DateTimeOffset.Now:O}] {ex}{Environment.NewLine}");
        }
        catch { }
    }

    internal static async Task<int> RunHelperCoreAsync(string pipeName)
    {
        // The helper is the pipe server. The pipe is ACL'd to this Windows account and carries
        // a Low mandatory label: without it the pipe inherits this process's High integrity and
        // MIC no-write-up rejects the unelevated PackMan client at connect time. The client is
        // additionally verified to be a PackMan process from this same executable.
        await using var server = CreateServerPipe(pipeName);
        using var connectTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        try { await server.WaitForConnectionAsync(connectTimeout.Token); }
        catch (OperationCanceledException) { return 0; }
        if (!IsTrustedClient(server)) return 3;

        using var reader = new StreamReader(server, Encoding.UTF8, false, 1024, leaveOpen: true);
        using var writeLock = new SemaphoreSlim(1, 1);
        var progress = new DelegateProgress<ProcessOutputEvent>(item =>
            WriteAsync(server, writeLock, new BrokerMessage("output", Output: item), CancellationToken.None)
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
                if (request?.Type != "run" || request.Invocation is null) continue;

                runCts = new CancellationTokenSource();
                runTask = RunAndRespondAsync(request.Invocation, progress, runCts);
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
                if (control?.Type == "cancel") runCts!.Cancel();
                continue;
            }

            await WriteAsync(server, writeLock, await runTask, CancellationToken.None);
            runCts!.Dispose();
            runCts = null;
            runTask = null;
        }
    }

    internal static NamedPipeServerStream CreateServerPipe(string pipeName)
    {
        var userSid = WindowsIdentity.GetCurrent().User?.Value
            ?? throw new InvalidOperationException("The elevated helper could not determine its user SID.");
        var security = new PipeSecurity();
        security.SetSecurityDescriptorSddlForm($"D:(A;;GA;;;{userSid})");
        var server = NamedPipeServerStreamAcl.Create(pipeName, PipeDirection.InOut, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 0, 0, security);
        try
        {
            ApplyIntegrityLabel(server.SafePipeHandle);
            return server;
        }
        catch
        {
            server.Dispose();
            throw;
        }
    }

    internal const int DaclSecurityInformation = 0x00000004;
    internal const int LabelSecurityInformation = 0x00000010;

    private static void ApplyIntegrityLabel(SafePipeHandle handle)
    {
        // Low mandatory label so the unelevated PackMan process can write to this elevated
        // server (MIC no-write-up would otherwise reject the connect). Setting the DACL on the
        // live handle needs a right the managed pipe handle does not have, so the DACL is
        // applied at creation and only the label is set here: LABEL_SECURITY_INFORMATION does
        // not require SeSecurityPrivilege, unlike the managed PipeSecurity SACL path.
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor("S:(ML;;NW;;;LW)", 1, out var descriptor, out _))
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "Could not build the elevated helper pipe security descriptor.");
        try
        {
            if (!SetKernelObjectSecurity(handle, LabelSecurityInformation, descriptor))
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Could not secure the elevated helper pipe.");
        }
        finally { Marshal.FreeHGlobal(descriptor); }
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(
        string stringSecurityDescriptor, uint stringSDRevision,
        out IntPtr securityDescriptor, out UIntPtr securityDescriptorSize);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetKernelObjectSecurity(
        SafeHandle handle, int securityInformation, IntPtr securityDescriptor);

    internal static bool IsTrustedClient(NamedPipeServerStream server)
    {
        try
        {
            if (!GetNamedPipeClientProcessId(server.SafePipeHandle, out var clientProcessId)) return false;
            using var client = Process.GetProcessById((int)clientProcessId);
            var clientPath = client.MainModule?.FileName;
            var ownPath = Environment.ProcessPath;
            if (string.IsNullOrWhiteSpace(clientPath) || string.IsNullOrWhiteSpace(ownPath)) return false;
            return string.Equals(Path.GetFullPath(clientPath), Path.GetFullPath(ownPath),
                StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipeHandle, out uint clientProcessId);

    private static async Task<BrokerMessage> RunAndRespondAsync(ProcessInvocation invocation,
        IProgress<ProcessOutputEvent> progress, CancellationTokenSource cts)
    {
        try
        {
            var result = await ProcessRunner.RunLocalAsync(invocation, progress, cts.Token);
            return new("complete", Result: result);
        }
        catch (OperationCanceledException) { return new("cancelled"); }
        catch (Exception ex) { return new("error", Error: ex.Message); }
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
        public Session(Process helper, NamedPipeClientStream pipe)
        {
            Helper = helper;
            Pipe = pipe;
            Reader = new StreamReader(pipe, Encoding.UTF8, false, 1024, leaveOpen: true);
        }

        public Process Helper { get; }
        public NamedPipeClientStream Pipe { get; }
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
        ProcessInvocation? Invocation = null,
        ProcessOutputEvent? Output = null,
        ProcessResult? Result = null,
        string? Error = null);
}
