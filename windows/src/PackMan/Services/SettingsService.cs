using System.Text.Json;

namespace PackMan.Services;

public interface ISettingsService
{
    string? LoadIssue { get; }
    bool IsSourceEnabled(SourceId id);
    void SetSourceEnabled(SourceId id, bool enabled);
    string? GetExecutableOverride(ToolId id);
    void SetExecutableOverride(ToolId id, string? path);
    ToolContext? GetCachedContext(SourceId id);
    void SetCachedContext(SourceId id, ToolContext? context);
    IReadOnlySet<string> GetIgnoredUpdates();
    void SetUpdateIgnored(string key, bool ignored);
    DateTimeOffset? GetLastAppUpdateCheck();
    void SetLastAppUpdateCheck(DateTimeOffset? checkedAt);
    string? GetSkippedAppUpdateVersion();
    void SetSkippedAppUpdateVersion(string? version);
    AppUpdateInfo? GetAvailableAppUpdate();
    void SetAvailableAppUpdate(AppUpdateInfo? update);
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

    public ToolContext? GetCachedContext(SourceId id)
    {
        lock (_sync)
        {
            if (!_data.CachedTools.TryGetValue(id.ToString(), out var cached)) return null;
            if (string.IsNullOrWhiteSpace(cached.Path) || !File.Exists(cached.Path)) return null;
            if (!Enum.TryParse<ToolResolutionOrigin>(cached.Origin, true, out var origin))
                origin = ToolResolutionOrigin.Custom;
            return new ToolContext(cached.Path,
                string.IsNullOrWhiteSpace(cached.Version) ? "Available" : cached.Version,
                origin, cached.PathEntries ?? [], cached.PrefixArguments);
        }
    }

    public void SetCachedContext(SourceId id, ToolContext? context)
    {
        lock (_sync)
        {
            if (context is null) _data.CachedTools.Remove(id.ToString());
            else _data.CachedTools[id.ToString()] = new CachedToolData
            {
                Path = context.ExecutablePath,
                Version = context.Version,
                Origin = context.Origin.ToString(),
                PathEntries = context.PathEntries.ToList(),
                PrefixArguments = context.PrefixArguments?.ToList(),
            };
            SaveLocked();
        }
    }

    public IReadOnlySet<string> GetIgnoredUpdates()
    {
        lock (_sync) return _data.IgnoredUpdates.ToHashSet(StringComparer.OrdinalIgnoreCase);
    }

    public void SetUpdateIgnored(string key, bool ignored)
    {
        lock (_sync)
        {
            _data.IgnoredUpdates.RemoveAll(x => x.Equals(key, StringComparison.OrdinalIgnoreCase));
            if (ignored) _data.IgnoredUpdates.Add(key);
            _data.IgnoredUpdates.Sort(StringComparer.OrdinalIgnoreCase);
            SaveLocked();
        }
    }

    public DateTimeOffset? GetLastAppUpdateCheck()
    {
        lock (_sync) return _data.LastAppUpdateCheck;
    }

    public void SetLastAppUpdateCheck(DateTimeOffset? checkedAt)
    {
        lock (_sync)
        {
            _data.LastAppUpdateCheck = checkedAt;
            SaveLocked();
        }
    }

    public string? GetSkippedAppUpdateVersion()
    {
        lock (_sync) return _data.SkippedAppUpdateVersion;
    }

    public void SetSkippedAppUpdateVersion(string? version)
    {
        lock (_sync)
        {
            _data.SkippedAppUpdateVersion = string.IsNullOrWhiteSpace(version) ? null : version;
            SaveLocked();
        }
    }

    public AppUpdateInfo? GetAvailableAppUpdate()
    {
        lock (_sync) return _data.AvailableAppUpdate is { } update
            && !string.IsNullOrWhiteSpace(update.Version)
            && !string.IsNullOrWhiteSpace(update.DownloadUrl)
            && !string.IsNullOrWhiteSpace(update.ChecksumUrl)
            && !string.IsNullOrWhiteSpace(update.ReleaseUrl)
            ? new AppUpdateInfo(update.Version, update.DownloadUrl, update.ChecksumUrl, update.ReleaseUrl)
            : null;
    }

    public void SetAvailableAppUpdate(AppUpdateInfo? update)
    {
        lock (_sync)
        {
            _data.AvailableAppUpdate = update is null ? null : new AppUpdateData
            {
                Version = update.Version,
                DownloadUrl = update.DownloadUrl,
                ChecksumUrl = update.ChecksumUrl,
                ReleaseUrl = update.ReleaseUrl,
            };
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
        _data.Version = 5;
        _data.DisabledSources ??= [];
        _data.ExecutableOverrides ??= new(StringComparer.OrdinalIgnoreCase);
        _data.CachedTools ??= new(StringComparer.OrdinalIgnoreCase);
        _data.IgnoredUpdates ??= [];
    }

    private void SaveLocked()
    {
        var directory = Path.GetDirectoryName(_settingsPath)!;
        Directory.CreateDirectory(directory);
        var temporary = _settingsPath + ".tmp";
        _data.Version = 5;
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
        public int Version { get; set; } = 5;
        public List<string> DisabledSources { get; set; } = [];
        public Dictionary<string, string> ExecutableOverrides { get; set; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, CachedToolData> CachedTools { get; set; } = new(StringComparer.OrdinalIgnoreCase);
        public List<string> IgnoredUpdates { get; set; } = [];
        public DateTimeOffset? LastAppUpdateCheck { get; set; }
        public string? SkippedAppUpdateVersion { get; set; }
        public AppUpdateData? AvailableAppUpdate { get; set; }
    }
    private sealed class AppUpdateData
    {
        public string? Version { get; set; }
        public string? DownloadUrl { get; set; }
        public string? ChecksumUrl { get; set; }
        public string? ReleaseUrl { get; set; }
    }
    private sealed class CachedToolData
    {
        public string? Path { get; set; }
        public string? Version { get; set; }
        public string? Origin { get; set; }
        public List<string>? PathEntries { get; set; }
        public List<string>? PrefixArguments { get; set; }
    }
    private sealed class LegacySettingsData { public List<string>? DisabledSources { get; set; } }
}
