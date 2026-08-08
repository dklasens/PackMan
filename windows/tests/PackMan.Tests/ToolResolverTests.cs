using PackMan.Services;

namespace PackMan.Tests;

public sealed class ToolResolverTests
{
    [Fact]
    public void FindInDirectoryPrefersNpmCmdOverExtensionlessShim()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"PackMan-nodejs-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            File.WriteAllText(Path.Combine(directory, "npm"), "#!/bin/sh");
            File.WriteAllText(Path.Combine(directory, "npm.cmd"), "@echo off");

            var result = ToolResolver.FindInDirectory(directory, "npm");

            Assert.Equal(Path.Combine(directory, "npm.cmd"), result);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void StoreAliasStubDetectionOnlyFlagsZeroBytePythonAliases()
    {
        var aliasDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps");
        var directory = Path.Combine(Path.GetTempPath(), $"PackMan-alias-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            var stub = Path.Combine(directory, "python.exe");
            File.WriteAllBytes(stub, []);
            var real = Path.Combine(directory, "python-real.exe");
            File.WriteAllText(real, "not empty");

            Assert.True(ToolResolver.IsStoreAliasStub("python", aliasDirectory, stub));
            Assert.True(ToolResolver.IsStoreAliasStub("python3", aliasDirectory, stub));
            Assert.False(ToolResolver.IsStoreAliasStub("python", aliasDirectory, real));
            Assert.False(ToolResolver.IsStoreAliasStub("winget", aliasDirectory, stub));
            Assert.False(ToolResolver.IsStoreAliasStub("python", directory, stub));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}