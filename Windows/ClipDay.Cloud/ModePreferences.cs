using System.Text;
using ClipDay.Sync;
namespace ClipDay.Cloud;

enum SyncMode { Nas, CloudFolder, LocalOnly }
static class ModePreferences
{
    // Original identity and NAS files stay in place. No migration or copying into another mode.
    public static readonly string BaseRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClipDay.Cloud");
    static string ModePath => Path.Combine(BaseRoot, "sync-mode.txt");
    public static SyncMode Read()
    {
        try
        {
            if (!File.Exists(ModePath))
            {
                // A fresh install starts offline. Preserve established NAS users without moving data.
                bool legacyNas = File.Exists(Path.Combine(BaseRoot, "config.json"))
                    || File.Exists(Path.Combine(BaseRoot, "history.protected"))
                    || Directory.Exists(Path.Combine(BaseRoot, "images"))
                    || Directory.Exists(Path.Combine(BaseRoot, "sync"));
                return legacyNas ? SyncMode.Nas : SyncMode.LocalOnly;
            }
            return File.ReadAllText(ModePath).Trim() switch { "nas" => SyncMode.Nas, "cloud-folder" => SyncMode.CloudFolder, _ => SyncMode.LocalOnly };
        }
        catch { return SyncMode.LocalOnly; } // Damaged selection must not silently start a transport.
    }
    public static void Save(SyncMode mode)
    {
        Directory.CreateDirectory(BaseRoot);
        Wire.Atomic(ModePath, Encoding.UTF8.GetBytes(mode switch { SyncMode.Nas => "nas", SyncMode.CloudFolder => "cloud-folder", _ => "local-only" }));
    }
}
