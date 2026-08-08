using System.Diagnostics;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.UIA3;
using Xunit;

namespace PackMan.UiTests;

[CollectionDefinition("PackMan UI", DisableParallelization = true)]
public sealed class PackManUiCollection;

[Collection("PackMan UI")]
public sealed class PackManUiTests
{
    [Fact]
    [Trait("Category", "UI")]
    public void InitialStateIsCleanAndDoesNotAutoScan()
    {
        using var session = Launch("initial");
        Assert.NotNull(session.Window.FindFirstDescendant(cf => cf.ByText("Ready to Scan")));
        Assert.True(session.Button("scanCancelButton").IsEnabled);
        Assert.False(session.Button("updateSelectedButton").IsEnabled);
    }

    [Fact]
    [Trait("Category", "UI")]
    public void PartialScanKeepsUpdatesAndShowsWarning()
    {
        using var session = Launch("partial");
        session.Button("scanCancelButton").Invoke();
        Assert.True(WaitFor(() => session.Window.FindFirstDescendant(cf => cf.ByText("Alpha Tool")) is not null));
        Assert.True(WaitFor(() => session.Window.FindFirstDescendant(
            cf => cf.ByText("Scan completed with issues; 1 update found.")) is not null));
        Assert.Null(session.Window.FindFirstDescendant(cf => cf.ByText("System is Up to Date")));
    }

    [Fact]
    [Trait("Category", "UI")]
    public void ActiveScanProgressRemainsResponsive()
    {
        using var session = Launch("slowScan");
        session.Button("scanCancelButton").Invoke();
        Assert.True(WaitFor(() => session.Window.FindAllDescendants()
            .Any(element => element.Name.StartsWith("Scanning", StringComparison.OrdinalIgnoreCase))));
        Assert.False(session.Application.HasExited);
        session.Button("scanCancelButton").Invoke();
        Assert.True(WaitFor(() => session.Window.FindFirstDescendant(cf => cf.ByText("Scan Cancelled")) is not null));
    }

    [Fact]
    [Trait("Category", "UI")]
    public void SuccessfulUpdatesAreRemovedAndSummarized()
    {
        using var session = Launch("updates");
        session.Button("scanCancelButton").Invoke();
        Assert.True(WaitFor(() => session.Window.FindFirstDescendant(cf => cf.ByText("Alpha Tool")) is not null));
        session.Button("updateSelectedButton").Invoke();
        Assert.True(WaitFor(() => session.Window.FindFirstDescendant(cf => cf.ByText("Updates Completed")) is not null));
        Assert.Null(session.Window.FindFirstDescendant(cf => cf.ByText("Alpha Tool")));
    }

    [Fact]
    [Trait("Category", "UI")]
    public void SourcesDialogShowsResolvedExecutable()
    {
        using var session = Launch("updates");
        session.Button("scanCancelButton").Invoke();
        Assert.True(WaitFor(() => session.Window.FindFirstDescendant(cf => cf.ByText("Alpha Tool")) is not null));
        session.Button("sourcesButton").Invoke();
        Window? sources = null;
        Assert.True(WaitFor(() =>
        {
            sources = session.Application.GetAllTopLevelWindows(session.Automation)
                .FirstOrDefault(window => window.FindFirstDescendant(cf => cf.ByText("Choose package managers and the executables PackMan should use.")) is not null);
            return sources is not null;
        }));
        Assert.NotNull(sources);
        Assert.NotNull(sources!.FindFirstDescendant(cf => cf.ByText("C:\\ui-test\\npm.cmd")));
        Assert.NotNull(sources.FindFirstDescendant(cf => cf.ByAutomationId("clearCacheButton")));
    }

    private static UiSession Launch(string scenario)
    {
        var executable = Environment.GetEnvironmentVariable("PACKMAN_UI_TEST_EXE");
        if (string.IsNullOrWhiteSpace(executable))
            executable = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
                "..", "..", "..", "..", "..", "src", "PackMan", "bin", "Release", "net8.0-windows", "win-x64", "PackMan.exe"));
        Assert.True(File.Exists(executable), $"PackMan executable was not found at {executable}");
        var start = new ProcessStartInfo(executable);
        start.ArgumentList.Add("--ui-test-scenario");
        start.ArgumentList.Add(scenario);
        var application = Application.Launch(start);
        var automation = new UIA3Automation();
        Window? window = null;
        Assert.True(WaitFor(() =>
        {
            window = application.GetAllTopLevelWindows(automation)
                .FirstOrDefault(candidate => candidate.FindFirstDescendant(cf => cf.ByText("Ready to Scan")) is not null);
            return window is not null;
        }, 10_000), "PackMan did not expose its ready-state automation tree.");
        window!.Focus();
        return new(application, automation, window);
    }

    private static bool WaitFor(Func<bool> predicate, int timeoutMs = 5000)
    {
        var deadline = Environment.TickCount64 + timeoutMs;
        while (Environment.TickCount64 < deadline)
        {
            if (predicate()) return true;
            Thread.Sleep(50);
        }
        return false;
    }

    private sealed class UiSession(Application application, UIA3Automation automation, Window window) : IDisposable
    {
        public Application Application { get; } = application;
        public UIA3Automation Automation { get; } = automation;
        public Window Window { get; } = window;
        public Button Button(string automationId)
        {
            AutomationElement? element = null;
            if (!WaitFor(() =>
                {
                    element = Window.FindFirstDescendant(cf => cf.ByAutomationId(automationId));
                    if (element is not null) return true;
                    var prefix = automationId switch
                    {
                        "scanCancelButton" => "Scan",
                        "updateSelectedButton" => "Update",
                        "sourcesButton" => "Sources",
                        _ => automationId,
                    };
                    element = Window.FindAllDescendants()
                        .FirstOrDefault(candidate => candidate.ControlType == FlaUI.Core.Definitions.ControlType.Button
                            && candidate.Name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase));
                    return element is not null;
                }))
                throw new Xunit.Sdk.XunitException($"Button '{automationId}' was not found.");
            return element!.AsButton();
        }
        public void Dispose()
        {
            try { Application.Close(); } catch { }
            Thread.Sleep(150);
            try { Application.Kill(); } catch { }
            Automation.Dispose();
            Application.Dispose();
        }
    }
}
