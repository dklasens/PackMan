namespace PackMan.Services;

public sealed class ChocoSource(IToolResolver resolver, IProcessRunner runner) : PackageSourceBase(resolver, runner)
{
    public override SourceDescriptor Descriptor { get; } = new(
        SourceId.Chocolatey, "Chocolatey", ToolId.Chocolatey, "choco",
        [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "chocolatey", "bin", "choco.exe")], "https://chocolatey.org/install");

    public override async Task<SourceScanReport> ScanAsync(ToolContext context,
        IProgress<SourcePhase>? progress = null, CancellationToken cancellationToken = default)
    {
        progress?.Report(SourcePhase.Scanning);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "outdated", "-r", "--no-color"), context.Environment, TimeSpan.FromMinutes(5)),
            cancellationToken: cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("choco outdated", result);
        var updates = new List<PackageInfo>();
        var issues = new List<SourceIssue>();
        foreach (var line in result.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = line.Split('|');
            if (parts.Length < 4 || !PackageIdValidator.IsValid(parts[0]))
            {
                if (line.Contains('|')) issues.Add(new(SourceIssueKind.Parsing, "Chocolatey returned an invalid package record."));
                continue;
            }
            if (string.Equals(parts[3], "true", StringComparison.OrdinalIgnoreCase)) continue;
            updates.Add(new(parts[0], parts[0], parts[1], parts[2]));
        }
        return new(updates, issues.DistinctBy(i => i.Id).ToList());
    }

    public override async Task UpdateAsync(UpdateRequest request, ToolContext context,
        IProgress<ProcessOutputEvent>? output = null, CancellationToken cancellationToken = default)
    {
        Validate(request);
        var result = await Runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            Arguments(context, "upgrade", request.PackageId, "--version", request.TargetVersion, "-y", "--no-progress"),
            context.Environment, TimeSpan.FromMinutes(15), request.Elevated), output, cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("choco upgrade", result);
    }
}
