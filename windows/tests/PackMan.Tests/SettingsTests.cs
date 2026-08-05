using PackMan.Services;

namespace PackMan.Tests;

public sealed class SettingsTests
{
    [Fact]
    public void MigratesLegacyNamesAndPersistsOverrides()
    {
        var root = Path.Combine(Path.GetTempPath(), "PackMan.Tests", Guid.NewGuid().ToString("N"));
        var current = Path.Combine(root, "PackMan", "settings.json");
        var legacy = Path.Combine(root, "UpdateManager", "settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(legacy)!);
        File.WriteAllText(legacy, "{\"DisabledSources\":[\"Choco\",\"npm\"]}");
        try
        {
            var settings = new SettingsService(current, legacy);
            Assert.False(settings.IsSourceEnabled(SourceId.Chocolatey));
            Assert.False(settings.IsSourceEnabled(SourceId.Npm));
            settings.SetExecutableOverride(ToolId.Scoop, "C:\\tools\\scoop.cmd");
            var reloaded = new SettingsService(current, legacy);
            Assert.Equal("C:\\tools\\scoop.cmd", reloaded.GetExecutableOverride(ToolId.Scoop));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public void CorruptSettingsProduceVisibleLoadIssue()
    {
        var root = Path.Combine(Path.GetTempPath(), "PackMan.Tests", Guid.NewGuid().ToString("N"));
        var current = Path.Combine(root, "settings.json");
        Directory.CreateDirectory(root);
        File.WriteAllText(current, "not json");
        try { Assert.NotNull(new SettingsService(current).LoadIssue); }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public void CachedContextRoundTripsAndDropsMissingExecutables()
    {
        var root = Path.Combine(Path.GetTempPath(), "PackMan.Tests", Guid.NewGuid().ToString("N"));
        var current = Path.Combine(root, "settings.json");
        Directory.CreateDirectory(root);
        var executable = Path.Combine(root, "tool.exe");
        File.WriteAllText(executable, "");
        try
        {
            var settings = new SettingsService(current);
            Assert.Null(settings.GetCachedContext(SourceId.Npm));
            settings.SetCachedContext(SourceId.Npm, new ToolContext(executable, "10.2", ToolResolutionOrigin.Path,
                [root], ["-g"]));
            var reloaded = new SettingsService(current);
            var cached = reloaded.GetCachedContext(SourceId.Npm);
            Assert.NotNull(cached);
            Assert.Equal(executable, cached!.ExecutablePath);
            Assert.Equal("10.2", cached.Version);
            Assert.Equal(ToolResolutionOrigin.Path, cached.Origin);
            Assert.Equal(["-g"], cached.PrefixArguments);
            File.Delete(executable);
            Assert.Null(new SettingsService(current).GetCachedContext(SourceId.Npm));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public void IgnoredUpdatesRoundTrip()
    {
        var root = Path.Combine(Path.GetTempPath(), "PackMan.Tests", Guid.NewGuid().ToString("N"));
        var current = Path.Combine(root, "settings.json");
        Directory.CreateDirectory(root);
        try
        {
            var settings = new SettingsService(current);
            Assert.Empty(settings.GetIgnoredUpdates());
            settings.SetUpdateIgnored("Chocolatey:ripgrep@14.1.1", true);
            settings.SetUpdateIgnored("Npm:typescript", true);
            settings.SetUpdateIgnored("Npm:typescript", true);
            var reloaded = new SettingsService(current);
            Assert.Equal(2, reloaded.GetIgnoredUpdates().Count);
            Assert.Contains("Chocolatey:ripgrep@14.1.1", reloaded.GetIgnoredUpdates());
            reloaded.SetUpdateIgnored("Chocolatey:ripgrep@14.1.1", false);
            Assert.Equal(["Npm:typescript"], new SettingsService(current).GetIgnoredUpdates().ToArray());
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }
}
