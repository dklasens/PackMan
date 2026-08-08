namespace PackMan.Services;

public sealed record SourceInstallPlan(
    string Title,
    string Summary,
    bool RequiresElevation,
    IReadOnlyList<ProcessInvocation> Steps);

public interface ISourceInstaller
{
    bool HasPlan(SourceId id);
    Task<SourceInstallPlan?> BuildPlanAsync(SourceId id, CancellationToken cancellationToken = default);
    Task InstallAsync(SourceInstallPlan plan, IProgress<ProcessOutputEvent>? output,
        CancellationToken cancellationToken);
}

public sealed class SourceInstaller(IToolResolver resolver, IProcessRunner runner,
    IEnumerable<IPackageSource> sources) : ISourceInstaller
{
    private static readonly TimeSpan StepTimeout = TimeSpan.FromMinutes(10);

    public bool HasPlan(SourceId id) => id is SourceId.Winget or SourceId.Chocolatey or SourceId.Scoop
        or SourceId.Npm or SourceId.Pip or SourceId.Pipx or SourceId.Dotnet;

    public async Task<SourceInstallPlan?> BuildPlanAsync(SourceId id, CancellationToken cancellationToken = default)
    {
        switch (id)
        {
            case SourceId.Chocolatey:
                return new("Chocolatey",
                    "Downloads the official Chocolatey install script from community.chocolatey.org and runs it.",
                    RequiresElevation: true,
                    [PowerShell(
                        "[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; " +
                        "iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))",
                        elevated: true)]);

            case SourceId.Scoop:
                // Scoop explicitly refuses an administrator install, so this stays non-elevated.
                return new("Scoop",
                    "Downloads the official Scoop installer from get.scoop.sh and installs Scoop for your user account.",
                    RequiresElevation: false,
                    [PowerShell("irm get.scoop.sh | iex", elevated: false)]);

            case SourceId.Pipx:
                return await BuildPipxPlanAsync(cancellationToken);

            case SourceId.Pip:
                return await BuildWingetPlanAsync("Python", "Python.Python.3.13", "Python 3.13", cancellationToken);

            case SourceId.Npm:
                return await BuildWingetPlanAsync("Node.js", "OpenJS.NodeJS.LTS", "Node.js LTS", cancellationToken);

            case SourceId.Dotnet:
                return await BuildWingetPlanAsync(".NET SDK", "Microsoft.DotNet.SDK.10", "the .NET 10 SDK", cancellationToken);

            case SourceId.Winget:
                return new("WinGet",
                    "Downloads App Installer from aka.ms/getwinget and registers it for your user account.",
                    RequiresElevation: false,
                    [PowerShell(
                        "Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -OutFile \"$env:TEMP\\PackMan-winget.msixbundle\"; " +
                        "Add-AppxPackage -Path \"$env:TEMP\\PackMan-winget.msixbundle\"; " +
                        "Remove-Item \"$env:TEMP\\PackMan-winget.msixbundle\" -ErrorAction SilentlyContinue",
                        elevated: false)]);

            default:
                return null;
        }
    }

    public async Task InstallAsync(SourceInstallPlan plan, IProgress<ProcessOutputEvent>? output,
        CancellationToken cancellationToken)
    {
        foreach (var step in plan.Steps)
        {
            var result = await runner.RunAsync(step, output, cancellationToken);
            if (!result.Success) throw SourceSupport.CommandFailure($"{plan.Title} installer", result);
        }
    }

    private async Task<SourceInstallPlan?> BuildPipxPlanAsync(CancellationToken cancellationToken)
    {
        var python = await ResolvePythonAsync(cancellationToken);
        if (python is null) return null;
        var module = Path.GetFileNameWithoutExtension(python.Path).Equals("py", StringComparison.OrdinalIgnoreCase)
            ? new[] { "-3", "-m" } : new[] { "-m" };
        ProcessInvocation Step(params string[] arguments) => new(python.Path,
            module.Concat(arguments).ToArray(), BuildEnvironment(python.PathEntries), StepTimeout);
        return new("pipx",
            $"Uses the Python installation at {python.Path} to run 'pip install --user pipx' and 'pipx ensurepath'.",
            RequiresElevation: false,
            [Step("pip", "install", "--user", "pipx"), Step("pipx", "ensurepath")]);
    }

    private async Task<ResolvedTool?> ResolvePythonAsync(CancellationToken cancellationToken)
    {
        var pip = sources.FirstOrDefault(s => s.Id == SourceId.Pip)?.Descriptor
            ?? new SourceDescriptor(SourceId.Pip, "pip", ToolId.Python, "py", []);
        var py = await resolver.ResolveAsync(pip, cancellationToken);
        if (py.Tool is not null) return py.Tool;
        var python = await resolver.ResolveAsync(pip with { ExecutableName = "python" }, cancellationToken);
        return python.Tool;
    }

    private async Task<SourceInstallPlan?> BuildWingetPlanAsync(string title, string wingetId,
        string displayName, CancellationToken cancellationToken)
    {
        var winget = sources.FirstOrDefault(s => s.Id == SourceId.Winget)?.Descriptor;
        if (winget is null) return null;
        var resolution = await resolver.ResolveAsync(winget, cancellationToken);
        if (resolution.Tool is null) return null;
        return new(title,
            $"Uses WinGet to install {displayName} ({wingetId}).",
            RequiresElevation: true,
            [new ProcessInvocation(resolution.Tool.Path,
                ["install", "--id", wingetId, "--exact", "--silent",
                    "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity"],
                BuildEnvironment(resolution.Tool.PathEntries), StepTimeout, Elevated: true)]);
    }

    private static ProcessInvocation PowerShell(string command, bool elevated) => new(
        "powershell.exe",
        ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
        null, StepTimeout, elevated);

    private static IReadOnlyDictionary<string, string> BuildEnvironment(IReadOnlyList<string> entries)
    {
        var inherited = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["PATH"] = string.Join(Path.PathSeparator, entries.Distinct(StringComparer.OrdinalIgnoreCase))
                + Path.PathSeparator + inherited,
        };
    }
}
