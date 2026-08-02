using System.Text.Json;

namespace PackMan.Services;

public interface ISettingsService
{
    string? LoadIssue { get; }
    bool IsSourceEnabled(SourceId id);
    void SetSourceEnabled(SourceId id, bool enabled);
    string? GetExecutableOverride(ToolId id);
    void SetExecutableOverride(ToolId id, string? path);
}

public sealed class SettingsService : ISettingsService
{
    private readonly object _sync = new();
    private readonly string _settingsPath;
    private SettingsData _data = new();
    public string? LoadIssue { get; private set; }

    public SettingsService() : this(DefaultSettingsPath, LegacySettingsPath) { }

    internal SettingsService(string settingsPath, string? legacySettingsPath = null)
    {
        _settingsPath = settingsPath;
        Load(legacySettingsPath);
    }

    public bool IsSourceEnabled(SourceId id)
    {
        lock (_sync) return !_data.DisabledSources.Contains(id.ToString(), StringComparer.OrdinalIgnoreCase);
    }

    public void SetSourceEnabled(SourceId id, bool enabled)
    {
        lock (_sync)
        {
            _data.DisabledSources.RemoveAll(x => x.Equals(id.ToString(), StringComparison.OrdinalIgnoreCase));
            if (!enabled) _data.DisabledSources.Add(id.ToString());
            _data.DisabledSources.Sort(StringComparer.OrdinalIgnoreCase);
            SaveLocked();
        }
    }

    public string? GetExecutableOverride(ToolId id)
    {
        lock (_sync) return _data.ExecutableOverrides.GetValueOrDefault(id.ToString());
    }

    public void SetExecutableOverride(ToolId id, string? path)
    {
        lock (_sync)
        {
            if (string.IsNullOrWhiteSpace(path)) _data.ExecutableOverrides.Remove(id.ToString());
            else _data.ExecutableOverrides[id.ToString()] = Path.GetFullPath(path);
            SaveLocked();
        }
    }

    private void Load(string? legacySettingsPath)
    {
        try
        {
            if (File.Exists(_settingsPath))
            {
                _data = JsonSerializer.Deserialize<SettingsData>(File.ReadAllText(_settingsPath), JsonOptions) ?? new();
                Normalize();
                return;
            }
            if (legacySettingsPath is not null && File.Exists(legacySettingsPath))
            {
                var legacy = JsonSerializer.Deserialize<LegacySettingsData>(File.ReadAllText(legacySettingsPath), JsonOptions);
                _data.DisabledSources = (legacy?.DisabledSources ?? [])
                    .Select(LegacySourceId).Where(x => x is not null).Select(x => x!.Value.ToString()).Distinct().ToList();
                SaveLocked();
            }
        }
        catch (Exception ex)
        {
            _data = new();
            LoadIssue = $"Settings could not be read; defaults are being used. {ex.Message}";
        }
    }

    private void Normalize()
    {
        _data.Version = 3;
        _data.DisabledSources ??= [];
        _data.ExecutableOverrides ??= new(StringComparer.OrdinalIgnoreCase);
    }

    private void SaveLocked()
    {
        var directory = Path.GetDirectoryName(_settingsPath)!;
        Directory.CreateDirectory(directory);
        var temporary = _settingsPath + ".tmp";
        _data.Version = 3;
        File.WriteAllText(temporary, JsonSerializer.Serialize(_data, JsonOptions));
        File.Move(temporary, _settingsPath, true);
        LoadIssue = null;
    }

    private static SourceId? LegacySourceId(string name) => name.ToLowerInvariant() switch
    {
        "winget" => SourceId.Winget,
        "choco" or "chocolatey" => SourceId.Chocolatey,
        "npm" => SourceId.Npm,
        "pip" => SourceId.Pip,
        _ => null,
    };

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
    };
    private static string DefaultSettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PackMan", "settings.json");
    private static string LegacySettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "UpdateManager", "settings.json");

    private sealed class SettingsData
    {
        public int Version { get; set; } = 3;
        public List<string> DisabledSources { get; set; } = [];
        public Dictionary<string, string> ExecutableOverrides { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    }
    private sealed class LegacySettingsData { public List<string>? DisabledSources { get; set; } }
}
