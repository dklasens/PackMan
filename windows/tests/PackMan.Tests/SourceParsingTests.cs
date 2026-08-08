using System.Net;
using System.Text;
using PackMan.Services;

namespace PackMan.Tests;

public sealed class SourceParsingTests
{
    [Fact]
    public void WingetParserReadsTableAndFlagsTruncation()
    {
        const string output = "Name              Id                 Version  Available  Source\n" +
                              "---------------------------------------------------------------\n" +
                              "Example App       Vendor.Example     1.0.0    2.0.0      winget\n" +
                              "Long App…         Vendor.Long…        3.0      4.0        winget\n\n";
        var result = WingetUpgradeParser.Parse(output);
        Assert.Equal(2, result.Rows.Count);
        Assert.Equal("Vendor.Example", result.Rows[0].Id);
        Assert.True(result.Rows[1].Truncated);
    }

    [Fact]
    public void WingetParserStopsAtSummaryFooterWithoutBlankLine()
    {
        const string output = "Name         Id                      Version Available    Source\n" +
                              "----------------------------------------------------------------\n" +
                              "Geekbench 6  PrimateLabs.Geekbench.6 Unknown 6.4.0        winget\n" +
                              "Sublime Text SublimeHQ.SublimeText.4 Unknown 4.0.0.420000 winget\n" +
                              "2 upgrades available.\n";
        var result = WingetUpgradeParser.Parse(output);
        Assert.Equal(2, result.Rows.Count);
        Assert.Equal(0, result.RejectedRows);
    }

    [Fact]
    public void WingetParserStopsAtProseFooterSpanningColumns()
    {
        const string output = "Name         Id                      Version Available    Source\n" +
                              "----------------------------------------------------------------\n" +
                              "Geekbench 6  PrimateLabs.Geekbench.6 Unknown 6.4.0        winget\n" +
                              "1 package(s) have pins that prevent upgrade. Use the 'winget pin' command to manage pins.\n";
        var result = WingetUpgradeParser.Parse(output);
        Assert.Single(result.Rows);
        Assert.Equal(0, result.RejectedRows);
    }

    [Fact]
    public void WingetParserAcceptsIdsWithPlusSigns()
    {
        const string output = "Name                 Id                            Version  Available  Source\n" +
                              "------------------------------------------------------------------------------\n" +
                              "VC++ Redist          Microsoft.VCRedist.2015+.x64  14.40    14.44      winget\n\n";
        var result = WingetUpgradeParser.Parse(output);
        Assert.Equal(0, result.RejectedRows);
        Assert.Equal("Microsoft.VCRedist.2015+.x64", Assert.Single(result.Rows).Id);
    }

    [Fact]
    public void ScoopParserSkipsHeldAndReportsMalformedRows()
    {
        const string output = "Name      Installed Version  Latest Version  Missing Dependencies  Info\n" +
                              "-----------------------------------------------------------------------\n" +
                              "ripgrep   14.0.0             14.1.0\n" +
                              "held      1.0                2.0                              Hold package\n" +
                              "bad row\n";
        var result = ScoopStatusParser.Parse(output);
        Assert.Single(result.Updates);
        Assert.Equal("ripgrep", result.Updates[0].Id);
        Assert.Single(result.Issues);
    }

    [Fact]
    public async Task NpmUsesLatestAndInstallsExactDisplayedVersion()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(1, "{\"typescript\":{\"current\":\"5.4.0\",\"wanted\":\"5.4.0\",\"latest\":\"6.0.1\"}}", ""));
        runner.Enqueue(new(0, "updated", ""));
        var source = new NpmSource(new StubResolver(), runner);
        var context = new ToolContext("npm.cmd", "10", ToolResolutionOrigin.Custom, []);
        var report = await source.ScanAsync(context);
        Assert.Equal("6.0.1", Assert.Single(report.Updates).AvailableVersion);
        await source.UpdateAsync(new("typescript", "typescript", "6.0.1"), context);
        Assert.Contains("typescript@6.0.1", runner.Invocations.Last().Arguments);
    }

    [Fact]
    public async Task NpmTreatsMissingEmptyGlobalPrefixAsNoUpdates()
    {
        const string missingPrefix = @"Z:\PackMan-tests\missing-npm-prefix";
        var runner = new StubRunner();
        runner.Enqueue(new(-4058, "", $"npm error code ENOENT\nnpm error syscall lstat\nnpm error path {missingPrefix}"));
        runner.Enqueue(new(0, missingPrefix + "\n", ""));
        var source = new NpmSource(new StubResolver(), runner);
        var context = new ToolContext("npm.cmd", "11", ToolResolutionOrigin.Custom, []);

        var report = await source.ScanAsync(context);

        Assert.Empty(report.Updates);
        Assert.Empty(report.Issues);
        Assert.Contains("prefix", runner.Invocations.Last().Arguments);
        Assert.Contains("-g", runner.Invocations.Last().Arguments);
    }

    [Fact]
    public async Task NpmMissingPrefixIsDetectedWithCrlfProcessOutput()
    {
        // ProcessRunner rebuilds captured output with Environment.NewLine, so real runs arrive
        // with \r\n line endings. Regression test for the \r before the path end anchor.
        const string missingPrefix = @"Z:\PackMan-tests\missing-npm-prefix-crlf";
        var runner = new StubRunner();
        runner.Enqueue(new(-4058, "",
            $"npm error code ENOENT\r\nnpm error syscall lstat\r\nnpm error path {missingPrefix}\r\nnpm error errno -4058\r\n"));
        runner.Enqueue(new(0, missingPrefix + "\r\n", ""));
        var source = new NpmSource(new StubResolver(), runner);
        var context = new ToolContext("npm.cmd", "11", ToolResolutionOrigin.Custom, []);

        var report = await source.ScanAsync(context);

        Assert.Empty(report.Updates);
        Assert.Empty(report.Issues);
    }

    [Fact]
    public async Task ScoopProbeFallsBackToHelpWhenVersionIsUnsupported()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(1, "", "WARN  scoop: '--version' isn't a scoop command. See 'scoop help'."));
        runner.Enqueue(new(0, "Usage: scoop <command> [<args>]", ""));
        var source = new ScoopSource(new StubResolver(), runner);

        var probe = await source.ProbeAsync();

        Assert.True(probe.IsAvailable);
        Assert.Equal("Available", probe.Context!.Version);
        Assert.Equal("help", runner.Invocations.Last().Arguments.Last());
    }

    [Fact]
    public async Task PipParsesStructuredOutputAndPinsTarget()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "[{\"name\":\"ruff\",\"version\":\"0.9\",\"latest_version\":\"0.11\"}]", ""));
        runner.Enqueue(new(0, "[]", ""));
        runner.Enqueue(new(0, "ok", ""));
        var source = new PipSource(new StubResolver(), runner);
        var context = new ToolContext("python.exe", "pip 25", ToolResolutionOrigin.Custom, [], ["-m", "pip"]);
        var report = await source.ScanAsync(context);
        Assert.Equal("ruff", Assert.Single(report.Updates).Id);
        await source.UpdateAsync(new("ruff", "ruff", "0.11"), context);
        Assert.Contains("-c", runner.Invocations[^2].Arguments);
        Assert.Contains("ruff==0.11", runner.Invocations.Last().Arguments);
    }

    [Fact]
    public async Task PipPinsInstalledDependentsInUpdateTransaction()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "[{\"name\":\"streamlit\",\"version\":\"1.61.1\"}]", ""));
        runner.Enqueue(new(0, "ok", ""));
        var source = new PipSource(new StubResolver(), runner);
        var context = new ToolContext("py.exe", "pip 26", ToolResolutionOrigin.Custom, [], ["-3", "-m", "pip"]);

        await source.UpdateAsync(new("starlette", "starlette", "1.4.1"), context);

        Assert.Equal(["-3", "-c"], runner.Invocations[0].Arguments.Take(2));
        Assert.Contains("starlette==1.4.1", runner.Invocations[1].Arguments);
        Assert.Contains("streamlit==1.61.1", runner.Invocations[1].Arguments);
    }

    [Fact]
    public async Task PipDoesNotInstallWhenDependencyInspectionFails()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(1, "", "metadata unavailable"));
        var source = new PipSource(new StubResolver(), runner);
        var context = new ToolContext("python.exe", "pip 26", ToolResolutionOrigin.Custom, [], ["-m", "pip"]);

        var error = await Assert.ThrowsAsync<SourceException>(() =>
            source.UpdateAsync(new("starlette", "starlette", "1.4.1"), context));

        Assert.Contains("update was not attempted", error.Message);
        Assert.Single(runner.Invocations);
    }

    [Fact]
    public async Task PipDoesNotInstallWithInvalidDependencyMetadata()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "[{\"name\":\"--index-url\",\"version\":\"1.0\"}]", ""));
        var source = new PipSource(new StubResolver(), runner);
        var context = new ToolContext("python.exe", "pip 26", ToolResolutionOrigin.Custom, [], ["-m", "pip"]);

        var error = await Assert.ThrowsAsync<SourceException>(() =>
            source.UpdateAsync(new("starlette", "starlette", "1.4.1"), context));

        Assert.Contains("invalid name or version", error.Message);
        Assert.Single(runner.Invocations);
    }

    [Fact]
    public async Task PipExplainsDependencyResolutionConflict()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "[{\"name\":\"streamlit\",\"version\":\"1.61.1\"}]", ""));
        runner.Enqueue(new(1, "", "ERROR: ResolutionImpossible"));
        var source = new PipSource(new StubResolver(), runner);
        var context = new ToolContext("python.exe", "pip 26", ToolResolutionOrigin.Custom, [], ["-m", "pip"]);

        var error = await Assert.ThrowsAsync<SourceException>(() =>
            source.UpdateAsync(new("starlette", "starlette", "1.4.1"), context));

        Assert.Contains("streamlit 1.61.1", error.Message);
        Assert.Contains("No packages were changed", error.Message);
    }

    [Fact]
    public async Task PipxNativePartialResultKeepsUpdateAndIssue()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "--outdated --output", ""));
        runner.Enqueue(new(1, """
            {"status":"partial","data":{"packages":[{"package":"ruff","version":"0.9","latest_version":"0.11","injected":false,"pinned":false}]},
             "errors":[{"message":"index unavailable","environment":"black"}]}
            """, ""));
        var source = new PipxSource(new StubResolver(), runner, new HttpClient(new NeverCalledHandler()));
        var report = await source.ScanAsync(new ToolContext("pipx.exe", "1.16", ToolResolutionOrigin.Custom, []));
        Assert.Equal("ruff", Assert.Single(report.Updates).Id);
        Assert.Single(report.Issues);
    }

    [Fact]
    public async Task ChocoUpdateAlwaysRunsElevated()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "upgraded", ""));
        var source = new ChocoSource(new StubResolver(), runner);
        var context = new ToolContext("choco.exe", "2.7.3", ToolResolutionOrigin.Custom, []);
        await source.UpdateAsync(new("ripgrep", "ripgrep", "14.1.1"), context);
        var invocation = Assert.Single(runner.Invocations);
        Assert.True(invocation.Elevated);
        Assert.Contains("ripgrep", invocation.Arguments);
    }

    [Fact]
    public async Task WingetReportsInstallerCancellationWithoutACommandFailure()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(unchecked((int)0x8A15010C), "You cancelled the installation.", ""));
        var source = new WingetSource(new StubResolver(), runner);
        var context = new ToolContext("winget.exe", "1.29", ToolResolutionOrigin.Custom, []);

        var error = await Assert.ThrowsAsync<PackageUpdateCanceledException>(() =>
            source.UpdateAsync(new("AntibodySoftware.WizTree", "WizTree", "4.32"), context));

        Assert.Contains("cancelled", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task WingetInstallTechnologyMismatchIsActionableAndNotElevationRetryable()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(unchecked((int)0x8A15002B), "",
            "The install technology of the newer version specified is different from the current version installed."));
        var source = new WingetSource(new StubResolver(), runner);
        var context = new ToolContext("winget.exe", "1.29", ToolResolutionOrigin.Custom, []);

        var error = await Assert.ThrowsAsync<SourceException>(() =>
            source.UpdateAsync(new("Microsoft.Edge", "Microsoft Edge", "139.0"), context));

        Assert.False(error.CanRetryElevated);
        Assert.Contains("different install technology", error.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("ignore this update", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task WingetInstallerUacCancellationIsElevationRetryable()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(unchecked((int)0x8A150006), "", "Installer failed with exit code: 1223"));
        var source = new WingetSource(new StubResolver(), runner);
        var context = new ToolContext("winget.exe", "1.29", ToolResolutionOrigin.Custom, []);

        var error = await Assert.ThrowsAsync<SourceException>(() =>
            source.UpdateAsync(new("Bitwarden.Bitwarden", "Bitwarden", "2026.7.0"), context));

        Assert.True(error.CanRetryElevated);
    }

    [Fact]
    public async Task WingetInstallerFileNotFoundIsGuidanceNotElevation()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(unchecked((int)0x80070002), "",
            "Installer failed with exit code: 0x80070002 : The system cannot find the file specified."));
        var source = new WingetSource(new StubResolver(), runner);
        var context = new ToolContext("winget.exe", "1.29", ToolResolutionOrigin.Custom, []);

        var error = await Assert.ThrowsAsync<SourceException>(() =>
            source.UpdateAsync(new("Anthropic.Claude", "Claude", "1.25927.0"), context));

        Assert.False(error.CanRetryElevated);
        Assert.Contains("reinstall Claude", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task PipProbeFallsThroughBrokenInterpreterToWorkingOne()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(1, "", "Python was not found; run without arguments to install from the Microsoft Store."));
        runner.Enqueue(new(0, "pip 25.0 from C:\\real\\lib\\site-packages\\pip (python 3.13)", ""));
        var source = new PipSource(new DescriptorResolver(d => d.ExecutableName == "py"
            ? new ResolvedTool("C:\\stubs\\py.exe", ToolResolutionOrigin.Path, ["C:\\stubs"])
            : new ResolvedTool("C:\\real\\python.exe", ToolResolutionOrigin.Path, ["C:\\real"])), runner);

        var probe = await source.ProbeAsync();

        Assert.True(probe.IsAvailable);
        Assert.Equal("C:\\real\\python.exe", probe.Context!.ExecutablePath);
        Assert.Equal(["-m", "pip"], probe.Context.PrefixArguments);
        Assert.Equal(2, runner.Invocations.Count);
    }

    [Fact]
    public async Task PipProbeReportsLastIssueWhenEveryInterpreterFails()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(1, "", "no pip for py"));
        runner.Enqueue(new(1, "", "no pip for python"));
        var source = new PipSource(new DescriptorResolver(d => d.ExecutableName == "py"
            ? new ResolvedTool("C:\\stubs\\py.exe", ToolResolutionOrigin.Path, ["C:\\stubs"])
            : new ResolvedTool("C:\\stubs\\python.exe", ToolResolutionOrigin.Path, ["C:\\stubs"])), runner);

        var probe = await source.ProbeAsync();

        Assert.False(probe.IsAvailable);
        Assert.NotNull(probe.Issue);
    }

    [Fact]
    public void DotnetToolListParsesTableAndFlagsBadRows()
    {
        const string output = "Package Id      Version      Commands\n" +
                              "--------------------------------------\n" +
                              "dotnet-ef       8.0.0        dotnet-ef\n" +
                              "badrow\n";
        var result = DotnetToolListParser.Parse(output);
        Assert.Single(result.Tools);
        Assert.Equal("dotnet-ef", result.Tools[0].Id);
        Assert.Equal("8.0.0", result.Tools[0].Version);
        Assert.Single(result.Issues);
    }

    [Fact]
    public async Task DotnetProbeRequiresAnInstalledSdk()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "", ""));
        var source = new DotnetSource(new StubResolver(new ResolvedTool(
            "dotnet.exe", ToolResolutionOrigin.Custom, [])), runner,
            new HttpClient(new NeverCalledHandler()));

        var probe = await source.ProbeAsync();

        Assert.False(probe.IsAvailable);
        Assert.Contains("no .NET SDK", probe.Issue?.Message);
        Assert.Contains("--list-sdks", Assert.Single(runner.Invocations).Arguments);
    }

    [Fact]
    public async Task DotnetFindsUpdatesFromNuGetIndexAndPinsTarget()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "Package Id      Version    Commands\n" +
                              "-----------------------------------\n" +
                              "newer-local     9.0.0      newer\n" +
                              "old-tool        1.0.0      old\n", ""));
        runner.Enqueue(new(0, "updated", ""));
        var source = new DotnetSource(new StubResolver(), runner,
            StubHttpHandler.JsonClient("{\"versions\":[\"1.0.0\",\"1.1.0\",\"2.0.0-preview.1\"]}"));
        var context = new ToolContext("dotnet.exe", "8", ToolResolutionOrigin.Custom, []);
        var report = await source.ScanAsync(context);
        var update = Assert.Single(report.Updates);
        Assert.Equal("old-tool", update.Id);
        Assert.Equal("1.1.0", update.AvailableVersion);
        await source.UpdateAsync(new("old-tool", "old-tool", "1.1.0"), context);
        var invocation = runner.Invocations.Last();
        Assert.Contains("update", invocation.Arguments);
        Assert.Contains("old-tool", invocation.Arguments);
        Assert.Contains("1.1.0", invocation.Arguments);
    }

    [Fact]
    public async Task PipxCapabilityIsProbedOncePerSession()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "--outdated --output", ""));
        runner.Enqueue(new(0, "", ""));
        runner.Enqueue(new(0, "", ""));
        var source = new PipxSource(new StubResolver(), runner, new HttpClient(new NeverCalledHandler()));
        var context = new ToolContext("pipx.exe", "1.16", ToolResolutionOrigin.Custom, []);
        await source.ScanAsync(context);
        await source.ScanAsync(context);
        Assert.Equal(3, runner.Invocations.Count);
        Assert.Contains("--outdated", runner.Invocations[^1].Arguments);
    }

    [Fact]
    public async Task PackageSourcesUseTheirNativeCachePurgeCommands()
    {
        static ToolContext Context(string executable, params string[] prefix) =>
            new(executable, "1", ToolResolutionOrigin.Custom, [], prefix);

        var npmRunner = new StubRunner();
        npmRunner.Enqueue(new(0, "", ""));
        await new NpmSource(new StubResolver(), npmRunner)
            .ClearCacheAsync(Context("npm.cmd"));
        Assert.Equal(["cache", "clean", "--force"], npmRunner.Invocations.Single().Arguments);

        var pipRunner = new StubRunner();
        pipRunner.Enqueue(new(0, "", ""));
        await new PipSource(new StubResolver(), pipRunner)
            .ClearCacheAsync(Context("python.exe", "-m", "pip"));
        Assert.Equal(["-m", "pip", "cache", "purge"], pipRunner.Invocations.Single().Arguments);

        var scoopRunner = new StubRunner();
        scoopRunner.Enqueue(new(0, "", ""));
        await new ScoopSource(new StubResolver(), scoopRunner)
            .ClearCacheAsync(Context("scoop.cmd"));
        Assert.Equal(["cache", "rm", "--all"], scoopRunner.Invocations.Single().Arguments);

        var dotnetRunner = new StubRunner();
        dotnetRunner.Enqueue(new(0, "", ""));
        await new DotnetSource(new StubResolver(), dotnetRunner, new HttpClient(new NeverCalledHandler()))
            .ClearCacheAsync(Context("dotnet.exe"));
        Assert.Equal(["nuget", "locals", "all", "--clear"], dotnetRunner.Invocations.Single().Arguments);
    }

    [Fact]
    public async Task PipxPurgesThePipCacheForEveryManagedEnvironment()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "black 25.1.0, installed using Python 3.13\nruff 0.12.0, installed using Python 3.13\n", ""));
        runner.Enqueue(new(0, "Files removed: 4", ""));
        runner.Enqueue(new(0, "Files removed: 0", ""));
        var source = new PipxSource(new StubResolver(), runner, new HttpClient(new NeverCalledHandler()));

        var message = await source.ClearCacheAsync(
            new ToolContext("pipx.exe", "1.8", ToolResolutionOrigin.Custom, []));

        Assert.Equal(3, runner.Invocations.Count);
        Assert.Equal(["runpip", "black", "cache", "purge"], runner.Invocations[1].Arguments);
        Assert.Equal(["runpip", "ruff", "cache", "purge"], runner.Invocations[2].Arguments);
        Assert.Contains("2 pipx environments", message);
    }

    [Theory]
    [InlineData("C:\\cache\\choco", "C:\\cache\\choco")]
    [InlineData("cacheLocation|C:\\cache\\choco", "C:\\cache\\choco")]
    [InlineData("cacheLocation = C:\\cache\\choco", "C:\\cache\\choco")]
    public void ChocolateyCacheLocationParsingHandlesSupportedOutput(string output, string expected) =>
        Assert.Equal(expected, ChocoSource.ParseCacheLocation(output));

    [Fact]
    public async Task ChocolateyPassesConfiguredCachePathWithoutShellInterpolation()
    {
        var directory = Path.Combine(Path.GetTempPath(), "PackMan-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var runner = new StubRunner();
            runner.Enqueue(new(0, directory, ""));
            runner.Enqueue(new(0, "", ""));
            var source = new ChocoSource(new StubResolver(), runner, []);

            await source.ClearCacheAsync(new ToolContext("choco.exe", "2.5", ToolResolutionOrigin.Custom, []));

            Assert.Equal(2, runner.Invocations.Count);
            var discovery = runner.Invocations[0];
            Assert.True(discovery.Elevated);
            Assert.Contains("--yes", discovery.Arguments);
            Assert.Equal(TimeSpan.FromSeconds(15), discovery.Timeout);
            var purge = runner.Invocations[1];
            Assert.True(purge.Elevated);
            Assert.Contains(directory, purge.Environment!["PACKMAN_CHOCO_CACHE_PATHS"]);
            Assert.DoesNotContain(directory, purge.Arguments.Last());
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ChocolateyDiscoveryTimeoutStillClearsKnownCaches()
    {
        var directory = Path.Combine(Path.GetTempPath(), "PackMan-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var runner = new StubRunner();
            runner.EnqueueException(new TimeoutException("'choco.exe' timed out after 15s."));
            runner.Enqueue(new ProcessResult(0, "", ""));
            var output = new List<ProcessOutputEvent>();
            var source = new ChocoSource(new StubResolver(), runner, [directory]);

            var message = await source.ClearCacheAsync(
                new ToolContext("choco.exe", "2.5", ToolResolutionOrigin.Custom, []),
                new DelegateProgress<ProcessOutputEvent>(output.Add));

            Assert.Equal(2, runner.Invocations.Count);
            Assert.Contains(directory, runner.Invocations[1].Environment!["PACKMAN_CHOCO_CACHE_PATHS"]);
            Assert.Contains(output, item => item.Stream == ProcessOutputStream.StandardError
                && item.Line.Contains("clearing known locations", StringComparison.OrdinalIgnoreCase));
            Assert.Contains("Cleared 1 Chocolatey cache location", message);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private sealed class NeverCalledHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.InternalServerError)
            { Content = new StringContent("", Encoding.UTF8) });
    }
}
