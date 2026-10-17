using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ClipDay.Sync;

public record Pair(int V, string Space, string Key)
{
    public static Pair Create() => new(1, Guid.NewGuid().ToString(), Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)));
    public void Validate()
    {
        if (V != 1 || !Wire.IsId(Space) || Convert.FromBase64String(Key).Length != 32) throw new InvalidDataException("配对信息无效。");
    }
    [System.Text.Json.Serialization.JsonIgnore]
    public string Code => "clipday1:" + Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(this, PairJson.Default.Pair));
    [System.Text.Json.Serialization.JsonIgnore]
    public string DriveCode => "clipday-drive1:" + Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(this, PairJson.Default.Pair));
    public static Pair ParseDrive(string code)
    {
        code = code.Trim();
        const string prefix = "clipday-drive1:";
        if (!code.StartsWith(prefix, StringComparison.Ordinal) || code.Length > 1024) throw new InvalidDataException("云盘配对信息无效。");
        var pair = JsonSerializer.Deserialize(Convert.FromBase64String(code[prefix.Length..]), PairJson.Default.Pair) ?? throw new InvalidDataException();
        pair.Validate(); return pair;
    }
    public static Pair Parse(string code)
    {
        code = code.Trim();
        if (!code.StartsWith("clipday1:") || code.Length > 1024) throw new InvalidDataException("配对码无效。");
        var pair = JsonSerializer.Deserialize(Convert.FromBase64String(code[9..]), PairJson.Default.Pair) ?? throw new InvalidDataException();
        pair.Validate(); return pair;
    }
}
public record Record(int V, string Id, string Space, string Device, string Name, long Seq, long Created, long Expires, Dictionary<string, long> Observed, string Text);
public static class Wire
{
    public const long Lifetime = 86_400_000;
    public const int MaxText = 1024 * 1024, MaxFile = 2 * 1024 * 1024;
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    public static long Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    public static bool IsId(string? id) => id != null && Guid.TryParseExact(id, "D", out _) && id == id.ToLowerInvariant();
    public static byte[] Seal(Record r, Pair pair)
    {
        pair.Validate();
        byte[] plain = JsonSerializer.SerializeToUtf8Bytes(r, Json), nonce = RandomNumberGenerator.GetBytes(12), tag = new byte[16], cipher = new byte[plain.Length];
        using var aes = new AesGcm(Convert.FromBase64String(pair.Key), 16);
        aes.Encrypt(nonce, plain, cipher, tag, Encoding.UTF8.GetBytes("clipday-sync-v1:" + pair.Space));
        return [.. nonce, .. cipher, .. tag];
    }
    public static Record Open(byte[] data, Pair pair)
    {
        pair.Validate();
        if (data.Length < 28 || data.Length > MaxFile) throw new InvalidDataException();
        byte[] plain = new byte[data.Length - 28];
        using var aes = new AesGcm(Convert.FromBase64String(pair.Key), 16);
        aes.Decrypt(data.AsSpan(0, 12), data.AsSpan(12, plain.Length), data.AsSpan(data.Length - 16), plain, Encoding.UTF8.GetBytes("clipday-sync-v1:" + pair.Space));
        var r = JsonSerializer.Deserialize<Record>(plain, Json) ?? throw new InvalidDataException();
        if (r.V != 1 || r.Space != pair.Space || !IsId(r.Id) || !IsId(r.Device) || r.Seq <= 0 || r.Created <= 0 || r.Created > long.MaxValue - Lifetime || r.Expires != r.Created + Lifetime || string.IsNullOrEmpty(r.Text) || Encoding.UTF8.GetByteCount(r.Text) > MaxText || r.Name == null || Encoding.UTF8.GetByteCount(r.Name) > 256 || r.Observed == null || r.Observed.Count > 100 || r.Observed.Any(x => !IsId(x.Key) || x.Value < 0)) throw new InvalidDataException();
        return r;
    }
    public static byte[] Read(string file)
    {
        var info = new FileInfo(file);
        if (info.Length > MaxFile || info.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new InvalidDataException();
        return File.ReadAllBytes(file);
    }
    public static void Atomic(string path, byte[] data)
    {
        var temp = path + "." + Guid.NewGuid() + ".tmp";
        try { File.WriteAllBytes(temp, data); File.Move(temp, path, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}
public class State
{
    public string Device { get; set; } = Guid.NewGuid().ToString();
    public long Seq { get; set; }
    public Dictionary<string, long> Seen { get; set; } = [];
    public Dictionary<string, long> Clock { get; set; } = [];
}
public record Batch(List<Record> Records, Record? Automatic, int Rejected, int Uploaded = 0);
// Caller serializes all operations on a background worker. Never use the UI thread for NAS I/O.
public sealed class FolderSync
{
    public Pair Pair { get; }
    public string Root { get; }
    public string Folder { get; }
    public bool CloudDrive { get; }
    public long AutomaticWindow => CloudDrive ? 300000 : 10000;
    public string Local { get; }
    public string Name { get; }
    public State State { get; }
    long? lastPoll;
    public string RecordsPath => Path.Combine(Root, "records");
    public string Outbox => Path.Combine(Local, "outbox");
    public string Inbox => Path.Combine(Local, "inbox");
    string StatePath => Path.Combine(Local, "state.json");
    public FolderSync(string folder, string local, Pair pair, string name, bool cloudDrive = false)
    {
        pair.Validate(); Pair = pair; Local = local; Name = name[..Math.Min(name.Length, 60)];
        Folder = folder; CloudDrive = cloudDrive;
        Root = SpaceRoot(folder, pair, cloudDrive);
        State = File.Exists(StatePath) ? JsonSerializer.Deserialize<State>(File.ReadAllBytes(StatePath), Wire.Json) ?? throw new InvalidDataException() : new();
        if (!Wire.IsId(State.Device) || State.Seq < 0) throw new InvalidDataException();
        Directory.CreateDirectory(Outbox); Directory.CreateDirectory(Inbox); Save();
    }
    public static string SpaceRoot(string folder, Pair pair, bool cloudDrive = false) => cloudDrive ? Path.Combine(folder, "ClipDayDrive", "v1", pair.Space) : Path.Combine(folder, "ClipDaySync", pair.Space);
    public static void Setup(string folder, Pair pair, bool create, bool cloudDrive = false)
    {
        pair.Validate();
        if (!Directory.Exists(folder)) throw new IOException("NAS 目录不可用。");
        var root = SpaceRoot(folder, pair, cloudDrive);
        if (create)
        {
            if (Directory.Exists(root)) throw new InvalidDataException();
            Directory.CreateDirectory(Path.Combine(root, "records"));
            Wire.Atomic(Path.Combine(root, "space.json"), JsonSerializer.SerializeToUtf8Bytes(new { v = 1, space = pair.Space }));
            long now = Wire.Now;
            var proof = new Record(1, pair.Space, pair.Space, pair.Space, "", 1, now, now + Wire.Lifetime, [], "clipday-space-v1");
            Wire.Atomic(Path.Combine(root, "space.check"), Wire.Seal(proof, pair));
        }
        Verify(root, pair);
    }
    static void Verify(string root, Pair pair)
    {
        var marker = JsonDocument.Parse(Wire.Read(Path.Combine(root, "space.json"))).RootElement;
        if (marker.GetProperty("v").GetInt32() != 1 || marker.GetProperty("space").GetString() != pair.Space || !Directory.Exists(Path.Combine(root, "records"))) throw new IOException("NAS 目录不可用。");
        var proof = Wire.Open(Wire.Read(Path.Combine(root, "space.check")), pair);
        if (proof.Text != "clipday-space-v1" || proof.Id != pair.Space) throw new InvalidDataException("配对信息无效。");
    }
    void Save() => Wire.Atomic(StatePath, JsonSerializer.SerializeToUtf8Bytes(State, Wire.Json));
    public void Suspend() => lastPoll = null;
    public void Acknowledge(IEnumerable<Record> records)
    {
        foreach (var r in records) { if (!Wire.IsId(r.Id)) continue; var file = Path.Combine(Inbox, r.Id + ".clip"); if (File.Exists(file)) File.Delete(file); }
    }
    public List<Record> History(long? timestamp = null)
    {
        var now = timestamp ?? Wire.Now; List<Record> result = [];
        foreach (var file in Directory.GetFiles(Inbox, "*.clip"))
        {
            var r = Wire.Open(Wire.Read(file), Pair);
            if (r.Expires <= now) File.Delete(file); else result.Add(r);
        }
        return result.OrderBy(x => x.Created).ToList();
    }
    public Record Enqueue(string text, long? timestamp = null, string? recordId = null)
    {
        var now = timestamp ?? Wire.Now;
        if (string.IsNullOrEmpty(text) || Encoding.UTF8.GetByteCount(text) > Wire.MaxText) throw new InvalidDataException("每条同步文字最多 1 MB。");
        if (recordId != null)
        {
            if (!Wire.IsId(recordId)) throw new InvalidDataException("记录标识无效。");
            var existing = Path.Combine(Outbox, recordId + ".clip");
            if (File.Exists(existing))
            {
                var queued = Wire.Open(Wire.Read(existing), Pair);
                if (queued.Id != recordId || queued.Device != State.Device || queued.Text != text) throw new InvalidDataException("待发送记录不匹配。");
                return queued;
            }
        }
        var files = new DirectoryInfo(Outbox).GetFiles();
        if (files.Length >= 2000 || files.Sum(x => x.Length) >= 100 * 1024 * 1024) throw new IOException("同步队列已满，这条文字仅留本机。");
        State.Seq++; Save();
        var r = new Record(1, recordId ?? Guid.NewGuid().ToString(), Pair.Space, State.Device, Name, State.Seq, now, now + Wire.Lifetime, new(State.Clock), text);
        Wire.Atomic(Path.Combine(Outbox, r.Id + ".clip"), Wire.Seal(r, Pair)); return r;
    }
    public Batch Poll(long? timestamp = null, CancellationToken cancellationToken = default)
    {
        var now = timestamp ?? Wire.Now;
        bool continuous = lastPoll.HasValue && now >= lastPoll && now - lastPoll < 6000;
        lastPoll = null;
        cancellationToken.ThrowIfCancellationRequested();
        Verify(Root, Pair);
        int uploaded = 0;
        foreach (var file in Directory.GetFiles(Outbox, "*.clip"))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var data = Wire.Read(file); var r = Wire.Open(data, Pair);
            if (r.Expires > now)
            {
                cancellationToken.ThrowIfCancellationRequested();
                Wire.Atomic(Path.Combine(RecordsPath, r.Id + ".clip"), data); uploaded++;
            }
            cancellationToken.ThrowIfCancellationRequested();
            File.Delete(file);
        }
        cancellationToken.ThrowIfCancellationRequested();
        var pending = History(now);
        long incomingBytes = pending.Sum(x => (long)Encoding.UTF8.GetByteCount(x.Text));
        var before = new Dictionary<string, long>(State.Clock);
        foreach (var id in State.Seen.Where(x => x.Value <= now).Select(x => x.Key).ToArray()) State.Seen.Remove(id);
        var files = Directory.GetFiles(RecordsPath);
        if (files.Length > 20000) throw new IOException("同步空间文件过多，请使用新的空间。");
        List<Record> records = pending, fresh = []; int rejected = 0;
        foreach (var file in files.Where(x => Path.GetExtension(x) == ".clip" && Wire.IsId(Path.GetFileNameWithoutExtension(x))))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (State.Seen.ContainsKey(Path.GetFileNameWithoutExtension(file))) continue;
            try
            {
                var r = Wire.Open(Wire.Read(file), Pair);
                if (Path.GetFileName(file) != r.Id + ".clip") throw new InvalidDataException();
                if (r.Expires <= now) { File.Delete(file); continue; }
                if (r.Created > now + 300000) { rejected++; continue; }
                if (r.Device != State.Device)
                {
                    var size = Encoding.UTF8.GetByteCount(r.Text);
                    if (records.Count >= 2000 || incomingBytes + size > 100 * 1024 * 1024) continue;
                    incomingBytes += size;
                    cancellationToken.ThrowIfCancellationRequested();
                    Wire.Atomic(Path.Combine(Inbox, r.Id + ".clip"), Wire.Seal(r, Pair));
                    records.Add(r);
                    if (continuous && r.Seq > before.GetValueOrDefault(r.Device) && r.Created <= now && now - r.Created <= AutomaticWindow && r.Observed.GetValueOrDefault(State.Device) >= State.Seq) fresh.Add(r);
                }
                State.Seen[r.Id] = r.Expires;
                State.Clock[r.Device] = Math.Max(State.Clock.GetValueOrDefault(r.Device), r.Seq);
            }
            catch (Exception ex) when (ex is IOException or InvalidDataException or CryptographicException or JsonException or ArgumentException or NullReferenceException) { rejected++; }
        }
        Record? automatic = fresh.Select(x => x.Device).Distinct().Count() == 1 ? fresh.MaxBy(x => x.Seq) : null;
        cancellationToken.ThrowIfCancellationRequested();
        Save(); lastPoll = now;
        return new(records.OrderBy(x => x.Created).ToList(), automatic, rejected, uploaded);
    }
}
