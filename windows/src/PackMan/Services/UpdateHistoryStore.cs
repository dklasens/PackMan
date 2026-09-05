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

    public void Save(UpdateHistoryEntry entry)
    {
        entry = entry with { Output = DiagnosticRedactor.Redact(entry.Output),
            Message = DiagnosticRedactor.Redact(entry.Message), Evidence = DiagnosticRedactor.Redact(entry.Evidence) };
        lock (_sync)
        {
            var next = _entries.Where(e => e.Id != entry.Id).Prepend(entry).Take(500).ToList();
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
    public static string Redact(string? value)
    {
        if (string.IsNullOrEmpty(value)) return string.Empty;
        var text = Regex.Replace(value, @"(?i)(https?://)[^\s/@]+:[^\s/@]+@", "$1[redacted]@");
        text = Regex.Replace(text, @"(?i)(Bearer\s+)\S+", "$1[redacted]");
        text = Regex.Replace(text, @"(?i)((?:[_a-z-]*(?:token|password|passwd|secret|apikey|api_key|api-key|authorization)[_a-z-]*)[\""']?\s*[:=]\s*[\""']?)[^\s,;\""'&]+", "$1[redacted]");
        text = Regex.Replace(text, @"([?&][^\s=&]+)=([^\s&#]+)", "$1=[redacted]");
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!string.IsNullOrWhiteSpace(profile)) text = text.Replace(profile, "%USERPROFILE%", StringComparison.OrdinalIgnoreCase);
        return text;
    }
}
