using System.Text.Json;
using ClipDay.Sync;

namespace ClipDay.Cloud;

// Separate from pairing config so privacy pause also persists before first connection.
static class PrivacyPreferences
{
    public static bool Read(string root)
    {
        var path = Path.Combine(root, "privacy.json");
        // Corrupt/unreadable preferences must propagate to the UI's fail-closed loading path.
        try { return JsonSerializer.Deserialize<bool>(File.ReadAllBytes(path)); }
        catch (FileNotFoundException) { return false; }
    }
    public static void Save(string root, bool paused) => Wire.Atomic(Path.Combine(root, "privacy.json"), JsonSerializer.SerializeToUtf8Bytes(paused));
}
