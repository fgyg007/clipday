using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ClipDay.Sync;

public record ImageRecord(int V, string Kind, string Id, string Space, string Device, string Name, long Seq,
    long Created, long Expires, Dictionary<string, long> Observed, string Mime, int Width, int Height,
    int ByteCount, int ChunkSize, int Chunks, string Sha256);

public static class ImageWire
{
    public const int MaxBytes = 20 * 1024 * 1024, ChunkSize = 1024 * 1024, MaxManifest = 32768;
    public const long MaxLocalBytes = 200L * 1024 * 1024;
    public const int MaxRecords = 100;
    public static void Dimensions(int width, int height)
    {
        if (width < 1 || height < 1 || width > 8192 || height > 8192 || (long)width * height > 16_777_216)
            throw new InvalidDataException("图片尺寸超出限制（最大 8192 边长、1600 万像素）。");
    }
    // Bound and inspect the complete PNG container before calling any native decoder.
    public static (int Width, int Height) Png(byte[] png)
    {
        ReadOnlySpan<byte> signature = [137, 80, 78, 71, 13, 10, 26, 10];
        if (png.Length < 57 || png.Length > MaxBytes || !png.AsSpan(0, 8).SequenceEqual(signature)) throw new InvalidDataException("仅支持 20 MB 以内的静态 PNG 图片。");
        int offset = 8, width = 0, height = 0; bool idat = false, ended = false;
        while (offset <= png.Length - 12)
        {
            uint length = BinaryPrimitives.ReadUInt32BigEndian(png.AsSpan(offset, 4));
            if (length > png.Length - offset - 12) throw new InvalidDataException();
            int n = (int)length; var type = Encoding.ASCII.GetString(png, offset + 4, 4);
            uint crc = 0xffffffff;
            for (int i = offset + 4; i < offset + 8 + n; i++) { crc ^= png[i]; for (int b = 0; b < 8; b++) crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320u : 0u); }
            if ((crc ^ 0xffffffff) != BinaryPrimitives.ReadUInt32BigEndian(png.AsSpan(offset + 8 + n, 4))) throw new InvalidDataException("PNG 校验失败。");
            if (offset == 8)
            {
                if (type != "IHDR" || n != 13) throw new InvalidDataException();
                width = checked((int)BinaryPrimitives.ReadUInt32BigEndian(png.AsSpan(16, 4)));
                height = checked((int)BinaryPrimitives.ReadUInt32BigEndian(png.AsSpan(20, 4))); Dimensions(width, height);
            }
            else if (type == "IHDR") throw new InvalidDataException();
            if (type is "iCCP" or "zTXt" or "iTXt") throw new InvalidDataException("不支持压缩 PNG 元数据。");
            if (type is "acTL" or "fcTL" or "fdAT") throw new InvalidDataException("不支持动画图片。");
            if (type == "IDAT") idat = true;
            offset += n + 12;
            if (type == "IEND") { if (n != 0 || !idat || offset != png.Length) throw new InvalidDataException(); ended = true; break; }
        }
        if (!ended) throw new InvalidDataException();
        return (width, height);
    }
    public static void Validate(ImageRecord r, string? space = null)
    {
        if (r.V != 1 || r.Kind != "image" || !Wire.IsId(r.Id) || !Wire.IsId(r.Space) || (space != null && r.Space != space) || !Wire.IsId(r.Device)
            || r.Seq <= 0 || r.Created <= 0 || r.Created > long.MaxValue - Wire.Lifetime || r.Expires != r.Created + Wire.Lifetime
            || r.Name == null || Encoding.UTF8.GetByteCount(r.Name) > 256 || r.Mime != "image/png" || r.ByteCount < 1 || r.ByteCount > MaxBytes
            || r.ChunkSize != ChunkSize || r.Chunks != (r.ByteCount + ChunkSize - 1) / ChunkSize
            || r.Observed == null || r.Observed.Count > 100 || r.Observed.Any(x => !Wire.IsId(x.Key) || x.Value < 0)
            || r.Sha256 == null || r.Sha256.Length != 64 || r.Sha256.Any(c => !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f'))) throw new InvalidDataException("图片记录无效。");
        Dimensions(r.Width, r.Height);
    }
    public static int ChunkLength(ImageRecord r, int index)
    {
        Validate(r); if (index < 0 || index >= r.Chunks) throw new InvalidDataException();
        return Math.Min(ChunkSize, r.ByteCount - index * ChunkSize);
    }
    public static byte[] SealManifest(ImageRecord r, Pair pair)
    {
        pair.Validate(); Validate(r, pair.Space);
        byte[] plain = JsonSerializer.SerializeToUtf8Bytes(r, Wire.Json);
        if (plain.Length > MaxManifest) throw new InvalidDataException();
        return Encrypt(plain, Convert.FromBase64String(pair.Key), "clipday-image-manifest-v1:" + pair.Space);
    }
    public static ImageRecord OpenManifest(byte[] bytes, Pair pair, string? expectedId = null)
    {
        pair.Validate();
        var plain = Decrypt(bytes, Convert.FromBase64String(pair.Key), "clipday-image-manifest-v1:" + pair.Space, MaxManifest);
        var r = JsonSerializer.Deserialize<ImageRecord>(plain, Wire.Json) ?? throw new InvalidDataException();
        Validate(r, pair.Space); if (expectedId != null && r.Id != expectedId) throw new InvalidDataException(); return r;
    }
    static string ChunkAad(ImageRecord r, int index) => $"clipday-image-chunk-v1:{r.Space}:{r.Id}:{index}:{ChunkLength(r, index)}";
    public static byte[] SealChunk(byte[] plain, ImageRecord r, int index, Pair pair)
    {
        pair.Validate(); Validate(r, pair.Space); if (plain.Length != ChunkLength(r, index)) throw new InvalidDataException();
        return Encrypt(plain, Convert.FromBase64String(pair.Key), ChunkAad(r, index));
    }
    public static byte[] OpenChunk(byte[] bytes, ImageRecord r, int index, Pair pair)
    {
        pair.Validate(); Validate(r, pair.Space);
        var plain = Decrypt(bytes, Convert.FromBase64String(pair.Key), ChunkAad(r, index), ChunkLength(r, index));
        if (plain.Length != ChunkLength(r, index)) throw new InvalidDataException(); return plain;
    }
    public static void ValidateContent(byte[] png, ImageRecord r, Action<byte[]> nativeValidate)
    {
        Validate(r);
        if (png.Length != r.ByteCount || Convert.ToHexString(SHA256.HashData(png)).ToLowerInvariant() != r.Sha256) throw new InvalidDataException("图片完整性校验失败。");
        var bounds = Png(png); if (bounds.Width != r.Width || bounds.Height != r.Height) throw new InvalidDataException();
        nativeValidate(png);
    }
    internal static byte[] Encrypt(byte[] plain, byte[] key, string aad)
    {
        byte[] nonce = RandomNumberGenerator.GetBytes(12), cipher = new byte[plain.Length], tag = new byte[16];
        using var aes = new AesGcm(key, 16); aes.Encrypt(nonce, plain, cipher, tag, Encoding.UTF8.GetBytes(aad)); return [.. nonce, .. cipher, .. tag];
    }
    internal static byte[] Decrypt(byte[] bytes, byte[] key, string aad, int max)
    {
        if (bytes.Length < 28 || bytes.Length > max + 28) throw new InvalidDataException();
        byte[] plain = new byte[bytes.Length - 28];
        using var aes = new AesGcm(key, 16); aes.Decrypt(bytes.AsSpan(0, 12), bytes.AsSpan(12, plain.Length), bytes.AsSpan(bytes.Length - 16), plain, Encoding.UTF8.GetBytes(aad)); return plain;
    }
    public static void SafePath(string path)
    {
        for (string? current = Path.GetFullPath(path); current != null; current = Path.GetDirectoryName(current))
            if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new IOException("不支持符号链接或重解析路径。");
    }
    public static byte[] Read(string path, int max)
    {
        SafePath(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length < 0 || stream.Length > max) throw new InvalidDataException();
        byte[] bytes = new byte[(int)stream.Length]; stream.ReadExactly(bytes);
        if (stream.ReadByte() != -1) throw new InvalidDataException(); return bytes;
    }
    public static void Atomic(string path, byte[] bytes)
    {
        SafePath(path); string temp = path + "." + Guid.NewGuid() + ".tmp";
        try { using (var s = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { s.Write(bytes); s.Flush(true); } SafePath(path); File.Move(temp, path, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    public static string ChunkName(string id, int i) { if (!Wire.IsId(id) || i < 0 || i >= 20) throw new InvalidDataException(); return $"{id}.{i:000}.chunk"; }
}

public record StoredImage(ImageRecord Record, bool Pending, bool Visible = true);

// One encrypted copy serves history AND outbox, so a pending image never doubles the disk budget.
// The caller serializes every vault and sync operation. Keys are supplied from platform protected storage.
public sealed class ImageVault
{
    readonly string root; readonly byte[] key; readonly Action<byte[]> nativeValidate;
    public int Rejected { get; private set; }
    static bool InvalidEntry(Exception ex) => ex is IOException or InvalidDataException or CryptographicException or JsonException or ArgumentException or OverflowException;
    public ImageVault(string root, byte[] key, Action<byte[]> nativeValidate)
    {
        if (key.Length != 32) throw new InvalidDataException();
        this.root = root; this.key = key.ToArray(); this.nativeValidate = nativeValidate;
        ImageWire.SafePath(root); Directory.CreateDirectory(root);
    }
    string PathFor(string id, string extension) { if (!Wire.IsId(id)) throw new InvalidDataException(); return Path.Combine(root, id + extension); }
    string Aad(string id, string kind) => $"clipday-local-image-v1:{id}:{kind}";
    public StoredImage? Find(string id)
    {
        string file = PathFor(id, ".meta"); if (!File.Exists(file)) return null;
        var entry = JsonSerializer.Deserialize<StoredImage>(ImageWire.Decrypt(ImageWire.Read(file, ImageWire.MaxManifest + 1024), key, Aad(id, "meta"), ImageWire.MaxManifest + 996), Wire.Json) ?? throw new InvalidDataException();
        ImageWire.Validate(entry.Record); if (entry.Record.Id != id) throw new InvalidDataException(); return entry;
    }
    public List<StoredImage> List(long now)
    {
        ImageWire.SafePath(root); Rejected = 0; Prune(now); List<StoredImage> entries = [];
        foreach (var path in Directory.EnumerateFiles(root, "*.meta").Take(101))
        {
            string id = Path.GetFileNameWithoutExtension(path); if (!Wire.IsId(id)) continue;
            try { var item = Find(id); if (item != null) entries.Add(item); }
            catch (Exception ex) when (InvalidEntry(ex)) { Rejected++; }
        }
        if (entries.Count > ImageWire.MaxRecords) throw new IOException("本机图片记录过多。"); return entries;
    }
    public List<ImageRecord> History(long now)
    {
        List<ImageRecord> images = [];
        foreach (var entry in List(now).Where(x => x.Visible))
            try { Read(entry.Record); images.Add(entry.Record); }
            catch (Exception ex) when (InvalidEntry(ex)) { Rejected++; }
        return images;
    }
    public byte[] Read(ImageRecord r)
    {
        byte[] png = ImageWire.Decrypt(ImageWire.Read(PathFor(r.Id, ".blob"), ImageWire.MaxBytes + 28), key, Aad(r.Id, "png"), ImageWire.MaxBytes);
        ImageWire.ValidateContent(png, r, nativeValidate); return png;
    }
    void SaveMetadata(StoredImage item) => ImageWire.Atomic(PathFor(item.Record.Id, ".meta"), ImageWire.Encrypt(JsonSerializer.SerializeToUtf8Bytes(item, Wire.Json), key, Aad(item.Record.Id, "meta")));
    public void Put(ImageRecord r, byte[] png, bool pending, long now)
    {
        ImageWire.ValidateContent(png, r, nativeValidate); if (r.Expires <= now || r.Created > now + 300000) throw new InvalidDataException();
        var old = Find(r.Id);
        if (old != null)
        {
            if (old.Record.Sha256 != r.Sha256 || old.Record.Space != r.Space || old.Record.Created != r.Created) throw new InvalidDataException("图片记录标识冲突。");
            Read(old.Record); return;
        }
        Prune(now);
        var files = new DirectoryInfo(root).EnumerateFiles().Take(1001).ToArray();
        long metaSize = JsonSerializer.SerializeToUtf8Bytes(new StoredImage(r, pending), Wire.Json).Length + 28L;
        if (files.Length > 1000 || files.Count(x => x.Extension == ".meta") >= ImageWire.MaxRecords || files.Sum(x => x.Length) + png.Length + 28L + metaSize > ImageWire.MaxLocalBytes)
            throw new IOException("图片历史/队列已满（100 条或 200 MB）；请清理已发送历史后重试。");
        // Reclaim an interrupted write only for this same ID; pending records always retain their data.
        string blob = PathFor(r.Id, ".blob");
        ImageWire.Atomic(blob, ImageWire.Encrypt(png, key, Aad(r.Id, "png")));
        try { SaveMetadata(new(r, pending)); }
        catch { if (!File.Exists(PathFor(r.Id, ".meta"))) File.Delete(blob); throw; }
    }
    public void Uploaded(string id)
    {
        var entry = Find(id) ?? throw new InvalidDataException();
        if (!entry.Visible) Delete(id); else SaveMetadata(entry with { Pending = false });
    }
    public void ClearHistory(long now)
    {
        foreach (var item in List(now)) { if (item.Pending) SaveMetadata(item with { Visible = false }); else Delete(item.Record.Id); }
    }
    void Delete(string id) { foreach (string ext in new[] { ".meta", ".blob" }) { string path = PathFor(id, ext); ImageWire.SafePath(path); if (File.Exists(path)) File.Delete(path); } }
    public void Prune(long now)
    {
        ImageWire.SafePath(root);
        foreach (var path in Directory.EnumerateFiles(root, "*.meta").Take(1001))
        {
            string id = Path.GetFileNameWithoutExtension(path); if (!Wire.IsId(id)) continue;
            // A damaged local entry is not silently discarded, particularly if it could be pending.
            try { var entry = Find(id); if (entry?.Record.Expires <= now) Delete(id); }
            catch (Exception ex) when (InvalidEntry(ex)) { /* Isolate damaged records; never silently delete a possibly pending image. */ }
        }
        foreach (var path in Directory.EnumerateFiles(root, "*.tmp").Take(1001))
        {
            var parts = Path.GetFileName(path).Split('.');
            if (parts.Length == 4 && Wire.IsId(parts[0]) && parts[1] is "meta" or "blob" && Wire.IsId(parts[2])) { ImageWire.SafePath(path); File.Delete(path); }
        }
        foreach (var path in Directory.EnumerateFiles(root, "*.blob").Take(1001))
        {
            string id = Path.GetFileNameWithoutExtension(path);
            if (Wire.IsId(id) && !File.Exists(PathFor(id, ".meta"))) { ImageWire.SafePath(path); File.Delete(path); }
        }
    }
}

public record ImageBatch(List<ImageRecord> Records, ImageRecord? Automatic, int Rejected, int Uploaded);

public sealed class FolderImageSync
{
    readonly FolderSync text; readonly ImageVault vault; readonly string statePath;
    State state; long? lastPoll; int scanCursor;
    public string ImagesPath => Path.Combine(text.Root, "images-v1");
    public State State => state;
    public FolderImageSync(FolderSync text, ImageVault vault)
    {
        this.text = text; this.vault = vault; statePath = Path.Combine(text.Local, "image-state.json");
        state = File.Exists(statePath) ? JsonSerializer.Deserialize<State>(ImageWire.Read(statePath, 1024 * 1024), Wire.Json) ?? throw new InvalidDataException() : new() { Device = text.State.Device };
        if (state.Device != text.State.Device || state.Seq < 0 || state.Seen == null || state.Clock == null || state.Seen.Count > 25000 || state.Clock.Count > 100 || state.Seen.Any(x => !Wire.IsId(x.Key) || x.Value <= 0) || state.Clock.Any(x => !Wire.IsId(x.Key) || x.Value < 0)) throw new InvalidDataException();
        Save();
    }
    void Save() => ImageWire.Atomic(statePath, JsonSerializer.SerializeToUtf8Bytes(state, Wire.Json));
    public void Suspend() => lastPoll = null;
    public ImageRecord Enqueue(byte[] png, string id, long created, CancellationToken token = default, long? timestamp = null)
    {
        token.ThrowIfCancellationRequested();
        var old = vault.Find(id);
        if (old != null)
        {
            if (old.Record.Space != text.Pair.Space || old.Record.Device != state.Device || old.Record.Created != created || old.Record.Sha256 != Convert.ToHexString(SHA256.HashData(png)).ToLowerInvariant()) throw new InvalidDataException();
            return old.Record;
        }
        ImageWire.Png(png);
        state.Seq = checked(state.Seq + 1); Save();
        var r = Create(png, id, text.Pair.Space, state.Device, text.Name, state.Seq, created, new(state.Clock));
        token.ThrowIfCancellationRequested(); vault.Put(r, png, true, timestamp ?? Wire.Now); return r;
    }
    public static ImageRecord Create(byte[] png, string id, string space, string device, string name, long seq, long created, Dictionary<string, long> clock)
    {
        var d = ImageWire.Png(png);
        var r = new ImageRecord(1, "image", id, space, device, name, seq, created, checked(created + Wire.Lifetime), clock, "image/png", d.Width, d.Height,
            png.Length, ImageWire.ChunkSize, (png.Length + ImageWire.ChunkSize - 1) / ImageWire.ChunkSize, Convert.ToHexString(SHA256.HashData(png)).ToLowerInvariant());
        ImageWire.Validate(r); return r;
    }
    public ImageBatch Poll(long? timestamp = null, CancellationToken cancellationToken = default)
    {
        long now = timestamp ?? Wire.Now; bool continuous = lastPoll.HasValue && now >= lastPoll.Value && now - lastPoll.Value < 6000; lastPoll = null;
        cancellationToken.ThrowIfCancellationRequested();
        // Never recreate a missing/unmounted NAS tree. Authenticate its existing marker before image I/O.
        ImageWire.SafePath(text.Root); FolderSync.Setup(text.Folder, text.Pair, false, text.CloudDrive);
        cancellationToken.ThrowIfCancellationRequested(); ImageWire.SafePath(ImagesPath); Directory.CreateDirectory(ImagesPath);
        int uploaded = 0, rejected = 0; bool imageTransferred = false, payloadDeferred = false;
        foreach (var item in vault.List(now).Where(x => x.Pending && x.Record.Space == text.Pair.Space).OrderBy(x => x.Record.Created).ThenBy(x => x.Record.Seq))
        {
            cancellationToken.ThrowIfCancellationRequested(); var r = item.Record; byte[] png;
            try { png = vault.Read(r); }
            catch (Exception ex) when (ex is InvalidDataException or CryptographicException or ArgumentException or IOException) { rejected++; continue; }
            for (int i = 0; i < r.Chunks; i++)
            {
                cancellationToken.ThrowIfCancellationRequested(); var part = png.AsSpan(i * ImageWire.ChunkSize, ImageWire.ChunkLength(r, i)).ToArray();
                ImageWire.Atomic(Path.Combine(ImagesPath, ImageWire.ChunkName(r.Id, i)), ImageWire.SealChunk(part, r, i, text.Pair));
            }
            cancellationToken.ThrowIfCancellationRequested();
            ImageWire.Atomic(Path.Combine(ImagesPath, r.Id + ".img"), ImageWire.SealManifest(r, text.Pair));
            cancellationToken.ThrowIfCancellationRequested(); vault.Uploaded(r.Id); uploaded++; imageTransferred = true; break;
        }
        var before = new Dictionary<string, long>(state.Clock);
        foreach (var id in state.Seen.Where(x => x.Value <= now).Select(x => x.Key).ToArray()) state.Seen.Remove(id);
        var paths = Directory.EnumerateFileSystemEntries(ImagesPath).Take(25001).ToArray();
        if (paths.Length > 25000) throw new IOException("图片同步目录文件过多。");
        List<ImageRecord> records = [], fresh = [];
        var manifests = paths.Where(x => Path.GetExtension(x) == ".img" && Wire.IsId(Path.GetFileNameWithoutExtension(x))).ToArray();
        var candidates = manifests.Where(x => !state.Seen.ContainsKey(Path.GetFileNameWithoutExtension(x))).OrderBy(x => x, StringComparer.Ordinal).ToArray();
        // A rotating bounded scan, not a hard failure at 1001, prevents invalid entries starving the tail.
        int start = candidates.Length == 0 ? 0 : scanCursor % candidates.Length;
        var scan = candidates.Skip(start).Concat(candidates.Take(start)).Take(1000).ToArray();
        scanCursor = candidates.Length == 0 ? 0 : (start + scan.Length) % candidates.Length;
        HashSet<string> freshSources = [];
        foreach (var path in scan)
        {
            cancellationToken.ThrowIfCancellationRequested(); string id = Path.GetFileNameWithoutExtension(path);
            if (state.Seen.TryGetValue(id, out long expiry) && expiry > now) continue;
            try
            {
                var r = ImageWire.OpenManifest(ImageWire.Read(path, ImageWire.MaxManifest + 28), text.Pair, id);
                if (r.Expires <= now)
                {
                    cancellationToken.ThrowIfCancellationRequested(); ImageWire.SafePath(path); File.Delete(path);
                    for (int i = 0; i < r.Chunks; i++) { cancellationToken.ThrowIfCancellationRequested(); var chunk = Path.Combine(ImagesPath, ImageWire.ChunkName(r.Id, i)); ImageWire.SafePath(chunk); if (File.Exists(chunk)) File.Delete(chunk); }
                    continue;
                }
                if (r.Created > now + 300000) { rejected++; continue; }
                if (!state.Clock.ContainsKey(r.Device) && state.Clock.Count >= 100) { rejected++; continue; }
                if (r.Device != state.Device && continuous && r.Seq > before.GetValueOrDefault(r.Device) && r.Created <= now && now - r.Created <= text.AutomaticWindow && r.Observed.GetValueOrDefault(state.Device) >= state.Seq) freshSources.Add(r.Device);
                var local = vault.Find(r.Id);
                if (r.Device != state.Device && local == null)
                {
                    if (imageTransferred) { payloadDeferred = true; continue; }
                    byte[] png = new byte[r.ByteCount];
                    for (int i = 0; i < r.Chunks; i++)
                    {
                        cancellationToken.ThrowIfCancellationRequested(); var data = ImageWire.Read(Path.Combine(ImagesPath, ImageWire.ChunkName(r.Id, i)), ImageWire.ChunkLength(r, i) + 28);
                        ImageWire.OpenChunk(data, r, i, text.Pair).CopyTo(png, i * ImageWire.ChunkSize);
                    }
                    cancellationToken.ThrowIfCancellationRequested(); vault.Put(r, png, false, now);
                    records.Add(r); imageTransferred = true;
                    if (continuous && r.Seq > before.GetValueOrDefault(r.Device) && r.Created <= now && now - r.Created <= text.AutomaticWindow && r.Observed.GetValueOrDefault(state.Device) >= state.Seq) fresh.Add(r);
                }
                else if (local != null && local.Record.Sha256 != r.Sha256) throw new InvalidDataException();
                cancellationToken.ThrowIfCancellationRequested();
                state.Seen[r.Id] = r.Expires; state.Clock[r.Device] = Math.Max(state.Clock.GetValueOrDefault(r.Device), r.Seq);
            }
            catch (Exception ex) when (ex is IOException or InvalidDataException or CryptographicException or JsonException or ArgumentException or OverflowException) { rejected++; }
        }
        cancellationToken.ThrowIfCancellationRequested(); Save(); lastPoll = now;
        var automatic = !payloadDeferred && freshSources.Count == 1 && candidates.Length <= 1000 ? fresh.MaxBy(x => x.Seq) : null;
        return new(records.OrderBy(x => x.Created).ToList(), automatic, rejected, uploaded);
    }
}

// A single clipboard decision across both independent wire clocks. Never consume the older kind first.
public record ClipboardChoice(Record? Text, ImageRecord? Image);
public static class ClipboardDelivery
{
    public static ClipboardChoice Newest(Record? text, ImageRecord? image)
    {
        if (text == null) return new(null, image);
        if (image == null) return new(text, null);
        // Conflicting devices or same-time unrelated clocks have no reliable cross-type order.
        if (text.Device != image.Device || text.Created == image.Created) return new(null, null);
        return text.Created > image.Created ? new(text, null) : new(null, image);
    }
}
