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
}
