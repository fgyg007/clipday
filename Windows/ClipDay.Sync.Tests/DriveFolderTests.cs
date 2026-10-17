using ClipDay.Sync;
using System.Text.Json;

internal static class DriveFolderTests
{
    public static Task Run()
    {
        int checks = 0;
        void Check(bool ok, string label) { if (!ok) throw new Exception("FAIL: " + label); checks++; Console.WriteLine("PASS: " + label); }
        void Reject(Action action, string label) { bool failed = false; try { action(); } catch { failed = true; } Check(failed, label); }
        string temp = Path.Combine(Path.GetTempPath(), "clipday-drive-synthetic-" + Guid.NewGuid());
        Directory.CreateDirectory(temp);
        try
        {
            string fa = Path.Combine(temp, "folder-a"), fb = Path.Combine(temp, "folder-b");
            Directory.CreateDirectory(fa); Directory.CreateDirectory(fb);
            var pair = Pair.Create();
            Check(Pair.ParseDrive(pair.DriveCode) == pair, "long cloud pairing bundle round-trips");
            Reject(() => Pair.ParseDrive(pair.Code), "NAS bundle not accepted as cloud bundle");
            Reject(() => Pair.Parse(pair.DriveCode), "cloud bundle not accepted as NAS bundle");
            FolderSync.Setup(fa, pair, true, true);
            Check(!Directory.Exists(Path.Combine(fa, "ClipDaySync")), "cloud namespace does not create NAS state");
            Reject(() => FolderSync.Setup(fb, pair, false, true), "join waits for remotely replicated metadata");
            Check(!Directory.Exists(Path.Combine(fb, "ClipDayDrive")), "join never creates missing remote tree");
            string ra = FolderSync.SpaceRoot(fa, pair, true), rb = FolderSync.SpaceRoot(fb, pair, true);
            Directory.CreateDirectory(Path.Combine(rb, "records"));
            File.Copy(Path.Combine(ra, "space.json"), Path.Combine(rb, "space.json"));
            Reject(() => FolderSync.Setup(fb, pair, false, true), "marker without encrypted proof cannot activate");
            File.Copy(Path.Combine(ra, "space.check"), Path.Combine(rb, "space.check"));
            FolderSync.Setup(fb, pair, false, true);
            Check(!File.ReadAllText(Path.Combine(ra, "space.json")).Contains(pair.Key), "public marker contains no key");
            var a = new FolderSync(fa, Path.Combine(temp, "local-a"), pair, "A", true);
            var b = new FolderSync(fb, Path.Combine(temp, "local-b"), pair, "B", true);
            long t = 1800000000000;
            a.Poll(t); b.Poll(t);
            var r = a.Enqueue("delayed encrypted text", t + 100); a.Poll(t + 200);
            string src = Path.Combine(a.RecordsPath, r.Id + ".clip"), dst = Path.Combine(b.RecordsPath, r.Id + ".clip");
            var bytes = File.ReadAllBytes(src);
            Check(!System.Text.Encoding.UTF8.GetString(bytes).Contains(r.Text), "local sync folder gets ciphertext only");
            for (long elapsed = 2000; elapsed <= 30000; elapsed += 2000) Check(b.Poll(t + elapsed).Records.Count == 0, "no receipt invented before provider replication");
            File.WriteAllBytes(dst, bytes[..15]);
            Check(b.Poll(t + 31000).Rejected > 0, "partially hydrated record rejected without acknowledgment");
            File.WriteAllBytes(dst, bytes);
            var received = b.Poll(t + 32000);
            Check(received.Records.Any(x => x.Id == r.Id) && received.Automatic?.Id == r.Id, "repaired delayed record arrives with bounded cloud freshness");
            b.Acknowledge(received.Records);
            Check(b.Poll(t + 33000).Records.Count == 0, "replicated duplicates do not echo");
            b.Suspend();
            var catchup = a.Enqueue("reconnect history only", t + 34000); a.Poll(t + 35000);
            File.Copy(Path.Combine(a.RecordsPath, catchup.Id + ".clip"), Path.Combine(b.RecordsPath, catchup.Id + ".clip"));
            Check(b.Poll(t + 36000).Automatic == null, "reconnect never replaces clipboard with backlog");
            using var fixture = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "image-v1.json")));
            byte[] png = Convert.FromBase64String(fixture.RootElement.GetProperty("pngBase64").GetString()!);
            var image = FolderImageSync.Create(png, Guid.NewGuid().ToString(), pair.Space, a.State.Device, "A", 1, t + 37000, []);
            string images = Path.Combine(rb, "images-v1"); Directory.CreateDirectory(images);
            File.WriteAllBytes(Path.Combine(images, image.Id + ".img"), ImageWire.SealManifest(image, pair));
            var vault = new ImageVault(Path.Combine(temp, "image-local"), new byte[32], _ => { });
            var receiver = new FolderImageSync(b, vault);
            Check(receiver.Poll(t + 38000).Records.Count == 0, "manifest before chunk remains pending");
            File.WriteAllBytes(Path.Combine(images, ImageWire.ChunkName(image.Id, 0)), ImageWire.SealChunk(png, image, 0, pair));
            Check(receiver.Poll(t + 39000).Records.Any(x => x.Id == image.Id), "chunk arriving later completes authenticated image");
            Check(new FolderSync(fa, Path.Combine(temp, "nas-local"), Pair.Create(), "NAS").AutomaticWindow == 10000, "NAS freshness unchanged");
        }
        finally { Directory.Delete(temp, true); }
        Console.WriteLine($"Drive folder synthetic tests: {checks} checks");
        return Task.CompletedTask;
    }
}
