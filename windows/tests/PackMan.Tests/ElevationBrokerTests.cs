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
        var helperTask = ElevationBroker.RunHelperCoreAsync(pipeName);
        await using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut,
            PipeOptions.Asynchronous);
        await client.ConnectAsync(5_000);
        using var reader = new StreamReader(client, Encoding.UTF8, false, 1024, leaveOpen: true);

        Assert.Equal("first", await RunCommandAsync(client, reader, "first"));
        Assert.Equal("second", await RunCommandAsync(client, reader, "second"));

        client.Dispose();
        Assert.Equal(0, await helperTask.WaitAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public void ServerPipeGrantsCurrentUserWithLowIntegrityLabel()
    {
        // The elevated helper's pipe must stay writable by the unelevated PackMan process:
        // a Low mandatory label opts out of MIC no-write-up, and the DACL limits access to
        // this Windows account. Regression guard for "Access to the path is denied" on connect.
        var pipeName = $"packman-{Guid.NewGuid():N}";
        using var server = ElevationBroker.CreateServerPipe(pipeName);
        var sddl = ReadSecurityDescriptor(server.SafePipeHandle,
            ElevationBroker.DaclSecurityInformation | ElevationBroker.LabelSecurityInformation);

        var userSid = System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value;
        var match = System.Text.RegularExpressions.Regex.Match(sddl,
            @"^D:\(A;;FA;;;(?<trustee>[^)]+)\)S:\(ML;;NW;;;LW\)$");
        Assert.True(match.Success, $"SDDL was: {sddl}");
        // Windows serializes well-known account SIDs as mnemonics (LA on CI runners), so
        // compare against the same round-trip of the current user's SID.
        var expected = new System.Security.AccessControl.RawSecurityDescriptor($"D:(A;;FA;;;{userSid})")
            .GetSddlForm(System.Security.AccessControl.AccessControlSections.Access);
        var expectedTrustee = System.Text.RegularExpressions.Regex.Match(expected,
            @"^D:\(A;;FA;;;(?<trustee>[^)]+)\)$").Groups["trustee"].Value;
        Assert.Equal(expectedTrustee, match.Groups["trustee"].Value);
    }

    private static string ReadSecurityDescriptor(System.Runtime.InteropServices.SafeHandle handle, int sections)
    {
        const uint revision = 1;
        GetKernelObjectSecurity(handle, sections, null, 0, out var needed);
        var buffer = new byte[needed];
        if (!GetKernelObjectSecurity(handle, sections, buffer, needed, out _))
            throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
        var pinned = System.Runtime.InteropServices.GCHandle.Alloc(buffer, System.Runtime.InteropServices.GCHandleType.Pinned);
        try
        {
            if (!ConvertSecurityDescriptorToStringSecurityDescriptor(pinned.AddrOfPinnedObject(),
                    revision, sections, out var sddl, out _))
                throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
            var text = System.Runtime.InteropServices.Marshal.PtrToStringUni(sddl);
            System.Runtime.InteropServices.Marshal.FreeHGlobal(sddl);
            return text ?? string.Empty;
        }
        finally { pinned.Free(); }
    }

    [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool GetKernelObjectSecurity(System.Runtime.InteropServices.SafeHandle handle,
        int securityInformation, byte[]? resultantSecurityDescriptor, uint descriptorLength, out uint returnLength);

    [System.Runtime.InteropServices.DllImport("advapi32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool ConvertSecurityDescriptorToStringSecurityDescriptor(
        System.IntPtr securityDescriptor, uint requestedStringSDRevision, int securityInformation,
        out System.IntPtr stringSecurityDescriptor, out System.UIntPtr stringSecurityDescriptorLen);

    [Theory]
    [InlineData(new[] { "--elevated-helper", "packman-abc123" }, true)]
    [InlineData(new[] { "--elevated-helper", "packman-abc123", "legacy-token" }, false)]
    [InlineData(new[] { "--elevated-helper", "bad name!" }, false)]
    [InlineData(new[] { "--other" }, false)]
    public void HelperArgumentsAreValidated(string[] args, bool expected) =>
        Assert.Equal(expected, ElevationBroker.IsHelper(args));

    private static async Task<string> RunCommandAsync(Stream stream, StreamReader reader, string value)
    {
        var request = JsonSerializer.Serialize(new
        {
            type = "run",
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
