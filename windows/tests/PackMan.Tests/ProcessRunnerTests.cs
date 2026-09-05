using System.Collections.Concurrent;
using PackMan.Services;

namespace PackMan.Tests;

public sealed class ProcessRunnerTests
{
    [Fact]
    public async Task CapturesBothStreamsAndPublishesTypedEvents()
    {
        var runner = new ProcessRunner(new StubElevationBroker());
        var events = new ConcurrentQueue<ProcessOutputEvent>();
        var result = await runner.RunAsync(new ProcessInvocation("cmd.exe",
            ["/d", "/s", "/c", "echo standard & echo problem 1>&2"]),
            new SynchronousProgress<ProcessOutputEvent>(events.Enqueue));
        Assert.True(result.Success);
        Assert.Contains("standard", result.StdOut);
        Assert.Contains("problem", result.StdErr);
        Assert.Contains(events, e => e.Stream == ProcessOutputStream.StandardOutput);
        Assert.Contains(events, e => e.Stream == ProcessOutputStream.StandardError);
    }

    [Fact]
    public async Task CmdScriptWithSpaceInPathRunsThroughCmd()
    {
        var directory = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(),
            "PackMan Tests " + Guid.NewGuid().ToString("N")));
        try
        {
            var script = Path.Combine(directory.FullName, "echo first.cmd");
            await File.WriteAllTextAsync(script, "@echo off\r\necho %~1\r\n");
            var runner = new ProcessRunner(new StubElevationBroker());
            var result = await runner.RunAsync(new ProcessInvocation(script, ["hello world"]));
            Assert.True(result.Success);
            Assert.Contains("hello world", result.StdOut);
        }
        finally
        {
            Directory.Delete(directory.FullName, true);
        }
    }

    [Fact]
    public async Task CancellationTerminatesProcess()
    {
        var runner = new ProcessRunner(new StubElevationBroker());
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(150));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => runner.RunAsync(new ProcessInvocation(
            "powershell.exe", ["-NoProfile", "-Command", "Start-Sleep -Seconds 10"]), cancellationToken: cts.Token));
    }

    [Fact]
    public async Task TimeoutStopsACommandAndReportsTimeoutRatherThanSuccess()
    {
        var runner = new ProcessRunner(new StubElevationBroker());
        await Assert.ThrowsAsync<TimeoutException>(() => runner.RunAsync(new ProcessInvocation(
            "powershell.exe", ["-NoProfile", "-Command", "Start-Sleep -Seconds 10"],
            Timeout: TimeSpan.FromMilliseconds(250))).WaitAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task CmdScriptReceivesSimpleArgumentsUnquoted()
    {
        // Scoop's .cmd shim rewrites double quotes in %* to single quotes; a simple argument
        // must therefore arrive raw. %1 preserves any surrounding quotes, exposing them here.
        var directory = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(),
            "PackMan Tests " + Guid.NewGuid().ToString("N")));
        try
        {
            var script = Path.Combine(directory.FullName, "echo.cmd");
            await File.WriteAllTextAsync(script, "@echo off\r\necho %1\r\n");
            var runner = new ProcessRunner(new StubElevationBroker());
            var result = await runner.RunAsync(new ProcessInvocation(script, ["--version"]));
            Assert.True(result.Success);
            Assert.Equal("--version", result.StdOut.Trim());
        }
        finally
        {
            Directory.Delete(directory.FullName, true);
        }
    }

    [Theory]
    [InlineData("--version", "--version")]
    [InlineData("plain", "plain")]
    [InlineData("with space", "\"with space\"")]
    [InlineData("", "\"\"")]
    public void QuoteForCmdQuotesOnlyWhenNeeded(string value, string expected) =>
        Assert.Equal(expected, ProcessRunner.QuoteForCmd(value));

    [Theory]
    [InlineData("a&b")]
    [InlineData("a|b")]
    [InlineData("a%b")]
    [InlineData("a!b")]
    public void QuoteForCmdRejectsUnsafeArguments(string value) =>
        Assert.Throws<SourceException>(() => ProcessRunner.QuoteForCmd(value));

    private sealed class SynchronousProgress<T>(Action<T> action) : IProgress<T>
    {
        public void Report(T value) => action(value);
    }
}
