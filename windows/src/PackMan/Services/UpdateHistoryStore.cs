using System.Text.Json;
using System.Text.RegularExpressions;

namespace PackMan.Services;

public enum HistoryOutcome { Running, Updated, Failed, Cancelled, Unverified, NotStarted, Interrupted, Verified }

public sealed record UpdateHistoryEntry(
    Guid Id, Guid RunId, DateTimeOffset StartedAt, DateTimeOffset? FinishedAt,
    SourceId Source, string PackageId, string Name, string? Repository, string BeforeVersion,
    string TargetVersion, string? InstalledVersion, HistoryOutcome Outcome, RestartState Restart,
    string? Evidence, string? Message, string ToolPath, string Output)
{
    public string OutcomeText => Outcome + (Restart == RestartState.None ? "" : $" • restart {Restart.ToString().ToLowerInvariant()}");
    public string VersionText => $"{BeforeVersion} → {InstalledVersion ?? "not confirmed"} (requested {TargetVersion})";
    public string Details => $"{Name} ({PackageId})\n{Source} / {Repository ?? "default repository"}\n{VersionText}\n"
        + $"{OutcomeText}\n{StartedAt:g} — {FinishedAt:g}\n{ToolPath}\n{Evidence}\n{Message}\n\n{Output}";
}

public interface IUpdateHistoryStore
{
    string? LoadIssue { get; }
    IReadOnlyList<UpdateHistoryEntry> Read();
    void Save(UpdateHistoryEntry entry);
    Task SaveRangeAsync(IReadOnlyList<UpdateHistoryEntry> entries);
}

public sealed class UpdateHistoryStore : IUpdateHistoryStore
{
    private readonly string? _path;
    private readonly object _sync = new();
    private List<UpdateHistoryEntry> _entries = [];
    public string? LoadIssue { get; private set; }
    public static string DefaultPath => Path.Combine(Environment.GetFolderPath(
        Environment.SpecialFolder.LocalApplicationData), "PackMan", "update-history.json");

    public UpdateHistoryStore(string? path)
    {
        _path = path;
        if (path is null || !File.Exists(path)) return;
        try
        {
            _entries = (JsonSerializer.Deserialize<List<UpdateHistoryEntry>>(File.ReadAllText(path)) ?? [])
                .Take(500).Select(entry => entry.Outcome == HistoryOutcome.Running
                    ? entry with { Outcome = HistoryOutcome.Interrupted,
                        Message = "PackMan closed before the result was recorded. Scan or verify before retrying." }
                    : entry).ToList();
        }
        catch (Exception ex) { LoadIssue = $"Update history could not be loaded: {ex.Message}"; }
    }

    public IReadOnlyList<UpdateHistoryEntry> Read() { lock (_sync) return _entries.ToArray(); }

    public void Save(UpdateHistoryEntry entry) => SaveRange([entry]);

    public Task SaveRangeAsync(IReadOnlyList<UpdateHistoryEntry> entries)
    {
        if (_path is not null) return Task.Run(() => SaveRange(entries));
        SaveRange(entries);
        return Task.CompletedTask;
    }

    private void SaveRange(IReadOnlyList<UpdateHistoryEntry> entries)
    {
        if (entries.Count == 0) return;
        var changes = entries.Reverse().DistinctBy(entry => entry.Id).Select(entry => entry with {
            Output = DiagnosticRedactor.Redact(entry.Output), Message = DiagnosticRedactor.Redact(entry.Message),
            Evidence = DiagnosticRedactor.Redact(entry.Evidence) }).ToList();
        var ids = changes.Select(entry => entry.Id).ToHashSet();
        lock (_sync)
        {
            var next = changes.Concat(_entries.Where(e => !ids.Contains(e.Id))).Take(500).ToList();
            if (_path is not null)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
                var temporary = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                try
                {
                    File.WriteAllText(temporary, JsonSerializer.Serialize(next, new JsonSerializerOptions { WriteIndented = true }));
                    File.Move(temporary, _path, true);
                }
                finally { if (File.Exists(temporary)) File.Delete(temporary); }
            }
            _entries = next;
        }
    }
}

public static class DiagnosticRedactor
{
    // Diagnostic lines can be tens of thousands of characters. Use the linear-time
    // regex engine so ordinary long lines do not stall the history writer.
    private const RegexOptions SafeRegex = RegexOptions.NonBacktracking | RegexOptions.CultureInvariant;
    private static readonly Regex UrlCredentials = new(@"(?i)(https?://)[^\s/@]+:[^\s/@]+@", SafeRegex);
    private static readonly Regex Bearer = new(@"(?i)(Bearer\s+)\S+", SafeRegex);
    private static readonly Regex KeyValue = new(@"(?i)((?:[_a-z-]*(?:token|password|passwd|secret|apikey|api_key|api-key|authorization)[_a-z-]*)[""']?\s*[:=]\s*[""']?)[^\s,;""'&]+", SafeRegex);
    private static readonly Regex Query = new(@"([?&][^\s=&]+)=([^\s&#]+)", SafeRegex);

    public static string Redact(string? value)
    {
        if (string.IsNullOrEmpty(value)) return string.Empty;
        var text = UrlCredentials.Replace(value, "$1[redacted]@");
        text = Bearer.Replace(text, "$1[redacted]");
        text = KeyValue.Replace(text, "$1[redacted]");
        text = Query.Replace(text, "$1=[redacted]");
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!string.IsNullOrWhiteSpace(profile)) text = text.Replace(profile, "%USERPROFILE%", StringComparison.OrdinalIgnoreCase);
        return text;
    }
}
