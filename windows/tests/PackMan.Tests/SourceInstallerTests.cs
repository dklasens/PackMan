using PackMan.Services;

namespace PackMan.Tests;

public sealed class SourceInstallerTests
{
    [Fact]
    public async Task ChocolateyPlanRunsOfficialScriptElevated()
    {
        var installer = new SourceInstaller(new DescriptorResolver(_ => null), new StubRunner(), []);

        var plan = await installer.BuildPlanAsync(SourceId.Chocolatey);

        Assert.NotNull(plan);
        Assert.True(plan.RequiresElevation);
        var step = Assert.Single(plan.Steps);
        Assert.True(step.Elevated);
        Assert.Equal("powershell.exe", step.FileName);
        Assert.Contains("community.chocolatey.org/install.ps1", string.Join(' ', step.Arguments));
    }

    [Fact]
    public async Task ScoopPlanStaysNonElevated()
    {
        var installer = new SourceInstaller(new DescriptorResolver(_ => null), new StubRunner(), []);

        var plan = await installer.BuildPlanAsync(SourceId.Scoop);

        Assert.NotNull(plan);
        Assert.False(plan.RequiresElevation);
        var step = Assert.Single(plan.Steps);
        Assert.False(step.Elevated);
        Assert.Contains("get.scoop.sh", string.Join(' ', step.Arguments));
    }

    [Fact]
    public async Task WingetPlanRegistersAppInstallerForUser()
    {
        var installer = new SourceInstaller(new DescriptorResolver(_ => null), new StubRunner(), []);

        var plan = await installer.BuildPlanAsync(SourceId.Winget);

        Assert.NotNull(plan);
        Assert.False(plan.RequiresElevation);
        var args = string.Join(' ', Assert.Single(plan.Steps).Arguments);
        Assert.Contains("getwinget", args);
        Assert.Contains("Add-AppxPackage", args);
    }

    [Fact]
    public async Task PipxPlanRequiresPython()
    {
        var installer = new SourceInstaller(new DescriptorResolver(_ => null), new StubRunner(), []);

        Assert.Null(await installer.BuildPlanAsync(SourceId.Pipx));
    }

    [Fact]
    public async Task PipxPlanUsesResolvedPythonForBothSteps()
    {
        var python = new ResolvedTool("C:\\py\\py.exe", ToolResolutionOrigin.Path, ["C:\\py"]);
        var installer = new SourceInstaller(
            new DescriptorResolver(d => d.ExecutableName == "py" ? python : null), new StubRunner(), []);

        var plan = await installer.BuildPlanAsync(SourceId.Pipx);

        Assert.NotNull(plan);
        Assert.False(plan.RequiresElevation);
        Assert.Equal(2, plan.Steps.Count);
        Assert.All(plan.Steps, step => Assert.Equal("C:\\py\\py.exe", step.FileName));
        Assert.Contains("pipx", string.Join(' ', plan.Steps[0].Arguments));
        Assert.Contains("ensurepath", string.Join(' ', plan.Steps[1].Arguments));
    }

    [Fact]
    public async Task NodePlanRequiresWinget()
    {
        var sources = new IPackageSource[] { new StubSource(SourceId.Winget, SourceScanReport.Empty) };
        var installer = new SourceInstaller(new DescriptorResolver(_ => null), new StubRunner(), sources);

        Assert.Null(await installer.BuildPlanAsync(SourceId.Npm));
    }

    [Fact]
    public async Task NodePlanInstallsLtsPackageElevatedThroughWinget()
    {
        var winget = new ResolvedTool("C:\\winget\\winget.exe", ToolResolutionOrigin.Path, ["C:\\winget"]);
        var sources = new IPackageSource[] { new StubSource(SourceId.Winget, SourceScanReport.Empty) };
        var installer = new SourceInstaller(new DescriptorResolver(_ => winget), new StubRunner(), sources);

        var plan = await installer.BuildPlanAsync(SourceId.Npm);

        Assert.NotNull(plan);
        Assert.True(plan.RequiresElevation);
        var step = Assert.Single(plan.Steps);
        Assert.True(step.Elevated);
        var args = string.Join(' ', step.Arguments);
        Assert.Contains("OpenJS.NodeJS.LTS", args);
        Assert.Contains("--silent", args);
    }

    [Fact]
    public async Task InstallRunsAllStepsInOrder()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(0, "one", ""));
        runner.Enqueue(new(0, "two", ""));
        var installer = new SourceInstaller(new StubResolver(), runner, []);
        var plan = new SourceInstallPlan("Test", "summary", false,
        [
            new ProcessInvocation("cmd.exe", ["/d", "/c", "first"]),
            new ProcessInvocation("cmd.exe", ["/d", "/c", "second"]),
        ]);

        await installer.InstallAsync(plan, null, CancellationToken.None);

        Assert.Equal(2, runner.Invocations.Count);
        Assert.Contains("first", runner.Invocations[0].Arguments);
        Assert.Contains("second", runner.Invocations[1].Arguments);
    }

    [Fact]
    public async Task InstallStopsOnFirstFailure()
    {
        var runner = new StubRunner();
        runner.Enqueue(new(1, "", "boom"));
        var installer = new SourceInstaller(new StubResolver(), runner, []);
        var plan = new SourceInstallPlan("Test", "summary", false,
        [
            new ProcessInvocation("cmd.exe", ["/d", "/c", "first"]),
            new ProcessInvocation("cmd.exe", ["/d", "/c", "second"]),
        ]);

        var error = await Assert.ThrowsAsync<SourceException>(() =>
            installer.InstallAsync(plan, null, CancellationToken.None));

        Assert.Contains("boom", error.Message);
        Assert.Single(runner.Invocations);
    }
}
