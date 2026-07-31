using System.IO;
using System.Text.Json;

namespace UpdateManager.Services;

public sealed class SettingsService
{
    private static readonly string SettingsDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "UpdateManager");

    private static readonly string SettingsPath = Path.Combine(SettingsDirectory, "settings.json");

    public HashSet<string> DisabledSources { get; private set; } = new(StringComparer.OrdinalIgnoreCase);

    public void Load()
    {
        try
        {
            if (!File.Exists(SettingsPath))
                return;

            var data = JsonSerializer.Deserialize<SettingsData>(File.ReadAllText(SettingsPath));
            if (data?.DisabledSources is not null)
                DisabledSources = new HashSet<string>(data.DisabledSources, StringComparer.OrdinalIgnoreCase);
        }
        catch
        {
            // Corrupt or unreadable settings: fall back to defaults.
        }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(SettingsDirectory);
            var data = new SettingsData { DisabledSources = DisabledSources.ToList() };
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch
        {
            // Best effort; losing toggle state is not fatal.
        }
    }

    private sealed class SettingsData
    {
        public List<string>? DisabledSources { get; set; }
    }
}
