using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using PackMan.Services;

namespace PackMan.Tests;

public sealed class ElevationBrokerTests
{
    [Fact]
    public async Task HelperProcessesMultipleCommandsOnOneConnection()
    {
        var pipeName = $"packman-{Guid.NewGuid():N}";
        var token = Convert.ToHexString(Guid.NewGuid().ToByteArray());
        await using var server = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);

        var helperTask = ElevationBroker.RunHelperAsync(["--elevated-helper", pipeName, token]);
        await server.WaitForConnectionAsync().WaitAsync(TimeSpan.FromSeconds(5));
        using var reader = new StreamReader(server, Encoding.UTF8, false, 1024, leaveOpen: true);

        Assert.Equal("first", await RunCommandAsync(server, reader, token, "first"));
        Assert.Equal("second", await RunCommandAsync(server, reader, token, "second"));

        server.Disconnect();
        Assert.Equal(0, await helperTask.WaitAsync(TimeSpan.FromSeconds(5)));
    }

    private static async Task<string> RunCommandAsync(Stream stream, StreamReader reader,
        string token, string value)
    {
        var request = JsonSerializer.Serialize(new
        {
            type = "run",
            token,
            invocation = new
            {
                fileName = "cmd.exe",
                arguments = new[] { "/d", "/c", $"echo {value}" },
                timeout = TimeSpan.FromSeconds(10),
                elevated = false,
            },
        });
        await stream.WriteAsync(Encoding.UTF8.GetBytes(request + "\n")).AsTask()
            .WaitAsync(TimeSpan.FromSeconds(5));

        while (await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10)) is { } line)
        {
            using var response = JsonDocument.Parse(line);
            if (response.RootElement.GetProperty("token").GetString() != token) continue;
            var type = response.RootElement.GetProperty("type").GetString();
            if (type == "error")
                throw new InvalidOperationException(response.RootElement.GetProperty("error").GetString());
            if (type != "complete") continue;

            var result = response.RootElement.GetProperty("result");
            Assert.Equal(0, result.GetProperty("exitCode").GetInt32());
            return result.GetProperty("stdOut").GetString()!.Trim();
        }

        throw new EndOfStreamException("The helper disconnected before returning a result.");
    }
}
