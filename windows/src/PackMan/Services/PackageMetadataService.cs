using System.Text.Json;
using System.Text.RegularExpressions;

namespace PackMan.Services;

public sealed record PackageLinks(string? PublisherUrl = null, string? ReleaseNotesUrl = null);

public interface IPackageMetadataService
{
    Task<PackageLinks> GetAsync(SourceId source, UpdateRequest request, ToolContext context, CancellationToken cancellationToken);
}

public sealed class PackageMetadataService(IProcessRunner runner) : IPackageMetadataService
{
    public async Task<PackageLinks> GetAsync(SourceId source, UpdateRequest request, ToolContext context, CancellationToken cancellationToken)
    {
        if (!PackageIdValidator.IsValid(request.PackageId) || !PackageIdValidator.IsValidVersion(request.TargetVersion))
            throw new SourceException(SourceIssueKind.Configuration, "Package identity is incomplete.");
        List<string> args;
        if (source == SourceId.Winget)
        {
            args = ["show", "--id", request.PackageId, "--exact", "--version", request.TargetVersion,
                "--disable-interactivity", "--accept-source-agreements"];
            if (request.Repository is not null) args.AddRange(["--source", request.Repository]);
        }
        else if (source == SourceId.Npm) args = ["view", $"{request.PackageId}@{request.TargetVersion}", "homepage", "--json"];
        else return new();
        var result = await runner.RunAsync(new ProcessInvocation(context.ExecutablePath,
            (context.PrefixArguments ?? []).Concat(args).ToArray(), context.Environment, TimeSpan.FromSeconds(30)),
            cancellationToken: cancellationToken);
        if (!result.Success) throw SourceSupport.CommandFailure("Package metadata lookup", result);
        if (source == SourceId.Npm)
        {
            if (string.IsNullOrWhiteSpace(result.StdOut)) return new();
            using var json = JsonDocument.Parse(result.StdOut);
            return new(json.RootElement.ValueKind == JsonValueKind.String ? SafeUrl(json.RootElement.GetString()) : null);
        }
        return ParseWinget(result.StdOut);
    }

    internal static PackageLinks ParseWinget(string text)
    {
        string? Read(string label) => SafeUrl(Regex.Match(text, $@"(?im)^\s*{Regex.Escape(label)}\s*:\s*(https?://\S+)").Groups[1].Value);
        return new(Read("Publisher Url") ?? Read("Homepage"), Read("Release Notes Url"));
    }

    internal static string? SafeUrl(string? url) => Uri.TryCreate(url, UriKind.Absolute, out var uri)
        && uri.Scheme is "https" or "http" && string.IsNullOrEmpty(uri.UserInfo) ? uri.AbsoluteUri : null;
}
