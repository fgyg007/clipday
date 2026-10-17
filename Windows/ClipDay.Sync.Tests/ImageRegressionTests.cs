using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ClipDay.Cloud;
using ClipDay.Sync;

internal static class ImageRegressionTests
{
    public static async Task Run()
    {
        int checks = 0;
        void Check(bool condition, string label) { if (!condition) throw new Exception("FAIL: " + label); checks++; Console.WriteLine("PASS: " + label); }
        void Reject(Action action, string label) { bool failed = false; try { action(); } catch { failed = true; } Check(failed, label); }
        string fixturePath = Path.Combine(AppContext.BaseDirectory, "Fixtures", "image-v1.json");
        using var fixture = JsonDocument.Parse(File.ReadAllBytes(fixturePath)); var f = fixture.RootElement;
        byte[] png = Convert.FromBase64String(f.GetProperty("pngBase64").GetString()!);
        var pair = new Pair(1, f.GetProperty("space").GetString()!, f.GetProperty("keyBase64").GetString()!);
        byte[] envelope = Convert.FromBase64String(f.GetProperty("manifestEnvelopeBase64").GetString()!);
        var manifest = ImageWire.OpenManifest(envelope, pair, f.GetProperty("id").GetString());
        Check(manifest.Name == "测试设备 Mac" && manifest.Width == 2 && manifest.Height == 2 && manifest.ByteCount == 82, "shared deterministic manifest decrypts with UTF-8 AAD");
        byte[] chunk = Convert.FromBase64String(f.GetProperty("chunkEnvelopeBase64").GetString()!);
        Check(ImageWire.OpenChunk(chunk, manifest, 0, pair).SequenceEqual(png), "shared chunk decrypts with identity/index/length AAD");
        ImageWire.ValidateContent(png, manifest, _ => { }); checks++;
        Check(ImageWire.OpenManifest(ImageWire.SealManifest(manifest, pair), pair).Sha256 == manifest.Sha256, "manifest randomized-nonce round trip");
        Check(ImageWire.OpenChunk(ImageWire.SealChunk(png, manifest, 0, pair), manifest, 0, pair).SequenceEqual(png), "chunk randomized-nonce round trip");
        Reject(() => ImageWire.OpenManifest(envelope, pair, Guid.NewGuid().ToString()), "manifest must match canonical filename identity");
        Reject(() => ImageWire.OpenManifest(envelope, pair with { Space = Guid.NewGuid().ToString() }), "manifest cannot cross spaces");
        Reject(() => ImageWire.OpenChunk(chunk, manifest, 1, pair), "out-of-range chunk index rejected");
        Reject(() => ImageWire.OpenChunk(chunk, manifest with { Id = Guid.NewGuid().ToString() }, 0, pair), "chunk cannot cross record identities");
        Reject(() => ImageWire.OpenChunk(chunk, manifest with { ByteCount = 83 }, 0, pair), "chunk length is authenticated");
        byte[] bad = chunk.ToArray(); bad[15] ^= 1;
        Reject(() => ImageWire.OpenChunk(bad, manifest, 0, pair), "corrupt chunk authentication fails");
        Reject(() => ImageWire.ValidateContent(png, manifest with { Sha256 = new string('0', 64) }, _ => { }), "complete-image SHA-256 mismatch rejected");
        Reject(() => ImageWire.ValidateContent(png, manifest with { Width = 3 }, _ => { }), "decoded/header dimensions must match manifest");
        Reject(() => ImageWire.Validate(manifest with { Expires = manifest.Expires + 1 }), "retention cannot be extended");
        Reject(() => ImageWire.Validate(manifest with { Width = 8193 }), "oversized image dimension rejected before allocation");
        Reject(() => ImageWire.Validate(manifest with { Width = 8192, Height = 8192 }), "pixel bomb rejected before allocation");
        Reject(() => ImageWire.Validate(manifest with { ByteCount = ImageWire.MaxBytes + 1 }), "encoded image limit enforced");
        Reject(() => ImageWire.Png(Encoding.UTF8.GetBytes("<svg></svg>")), "SVG and arbitrary files rejected");
        Reject(() => ImageWire.Png(InsertChunk(png, "acTL", new byte[8])), "animated PNG rejected before native decoder");
        foreach (var type in new[] { "iCCP", "zTXt", "iTXt" }) Reject(() => ImageWire.Png(InsertChunk(png, type, new byte[8])), type + " compressed metadata rejected before native decoder");
        byte[] badPng = png.ToArray(); badPng[45] ^= 1;
        Reject(() => ImageWire.Png(badPng), "PNG CRC corruption rejected");

        var textCandidate = new Record(1, Guid.NewGuid().ToString(), pair.Space, manifest.Device, "source", 1, manifest.Created - 1, manifest.Expires - 1, [], "older text");
        Check(ClipboardDelivery.Newest(textCandidate, manifest).Image?.Id == manifest.Id, "newer image wins over earlier text in one clipboard decision");
        Check(ClipboardDelivery.Newest(textCandidate with { Created = manifest.Created + 1 }, manifest).Text != null, "newer text wins over earlier image without image overwrite");
        Check(ClipboardDelivery.Newest(textCandidate with { Device = Guid.NewGuid().ToString() }, manifest) is { Text: null, Image: null }, "conflicting cross-type sources stay in history");
        Check(ClipboardDelivery.Newest(textCandidate with { Created = manifest.Created }, manifest) is { Text: null, Image: null }, "equal-time independent clocks do not invent ordering");

        var capture = new ClipboardCaptureState(); capture.Ignore(10);
        var attempt = capture.BeginImage(11, png, 1000);
        Check(ReferenceEquals(attempt, capture.BeginImage(11, png, 2000)), "image capture retry preserves original ID and expiry");
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        bool enqueued = false;
        var committing = capture.CommitAsync(attempt, () => release.Task, () => { enqueued = true; return Task.CompletedTask; });
        capture.SetPrivacyPaused(true, 12); release.SetResult();
        Check(!await committing && !enqueued && capture.Pending == null && capture.LastSequence == 12, "image privacy pause invalidates stale local-save callback and next enqueue");
        capture.SetPrivacyPaused(false, 13);
        Check(!capture.ShouldCapture(13), "image copy made during private interval is skipped on resume");

        string root = Path.Combine(Path.GetTempPath(), "ClipDay-images-" + Guid.NewGuid()); Directory.CreateDirectory(root);
        try
        {
            long t = Wire.Now; pair = Pair.Create(); FolderSync.Setup(root, pair, true);
            byte[] key = RandomNumberGenerator.GetBytes(32);
            var textA = new FolderSync(root, Path.Combine(root, "a"), pair, "A");
            var textB = new FolderSync(root, Path.Combine(root, "b"), pair, "B");
            var vaultA = new ImageVault(Path.Combine(root, "vault-a"), key, _ => { });
            var vaultB = new ImageVault(Path.Combine(root, "vault-b"), key, _ => { });
            var a = new FolderImageSync(textA, vaultA); var b = new FolderImageSync(textB, vaultB);
            Check(a.State.Device == textA.State.Device && a.State.Seq == 0, "image clock separate but shares stable text device identity");
            a.Poll(t); b.Poll(t);
            var first = a.Enqueue(png, Guid.NewGuid().ToString(), t + 1, timestamp: t + 1);
            long seq = a.State.Seq;
            Check(a.Enqueue(png, first.Id, t + 1, timestamp: t + 1).Id == first.Id && a.State.Seq == seq, "durable image enqueue retry is idempotent");
            Check(textA.State.Seq == 0, "image capture does not advance text causal sequence");
            var sealedBlob = File.ReadAllBytes(Path.Combine(root, "vault-a", first.Id + ".blob"));
            Check(!sealedBlob.AsSpan().SequenceEqual(png) && sealedBlob.Length == png.Length + 28, "local image history/outbox uses encrypted single-copy payload");
            using var stopped = new CancellationTokenSource(); stopped.Cancel();
            Reject(() => a.Poll(t + 2, stopped.Token), "canceled transfer does not start");
            Check(vaultA.Find(first.Id)?.Pending == true && !File.Exists(Path.Combine(a.ImagesPath, first.Id + ".img")), "canceled transfer retains encrypted pending data");
            Check(a.Poll(t + 3).Uploaded == 1 && vaultA.Find(first.Id)?.Pending == false, "manifest-last successful upload updates durable queue state");
            var received = b.Poll(t + 4);
            Check(received.Automatic?.Id == first.Id && vaultB.Read(first).SequenceEqual(png), "continuous fresh causal image verified and eligible for auto apply");
            Check(b.Poll(t + 5).Records.Count == 0, "seen image does not loop or duplicate");
            var second = a.Enqueue(png, Guid.NewGuid().ToString(), t + 6, timestamp: t + 6); a.Poll(t + 7);
            string chunkPath = Path.Combine(a.ImagesPath, ImageWire.ChunkName(second.Id, 0)); byte[] saved = File.ReadAllBytes(chunkPath); File.Delete(chunkPath);
            Check(b.Poll(t + 8).Rejected > 0 && vaultB.Find(second.Id) == null && !b.State.Seen.ContainsKey(second.Id), "missing chunk remains retryable and never becomes usable history");
            File.WriteAllBytes(chunkPath, saved);
            Check(b.Poll(t + 9).Records.Any(x => x.Id == second.Id), "repaired partial image retries successfully");
            b.Suspend(); var backlog = a.Enqueue(png, Guid.NewGuid().ToString(), t + 10, timestamp: t + 10); a.Poll(t + 11);
            var caughtUp = b.Poll(t + 12); Check(caughtUp.Automatic == null && caughtUp.Records.Any(x => x.Id == backlog.Id), "image catch-up after pause is history-only");
            var older = a.Enqueue(png, "00000000-0000-4000-8000-aaaaaaaaaaa1", t + 20, timestamp: t + 20);
            var newer = a.Enqueue(png, "ffffffff-ffff-4fff-8fff-fffffffffff1", t + 21, timestamp: t + 21);
            a.Poll(t + 22); a.Poll(t + 23);
            var deferred = b.Poll(t + 24);
            Check(deferred.Records.Count == 1 && deferred.Automatic == null && !b.State.Seen.ContainsKey(newer.Id), "deferred same-source payload suppresses automatic application of UUID-first older image");
            Check(b.Poll(t + 25).Automatic?.Id == newer.Id, "newest deferred image remains eligible on complete later fresh scan");
            var pending = a.Enqueue(png, Guid.NewGuid().ToString(), t + 30, timestamp: t + 30);
            vaultA.ClearHistory(t + 31);
            Check(vaultA.Find(pending.Id) is { Pending: true, Visible: false }, "clearing image history never silently evicts pending outbox");
            Check(a.Poll(t + 32).Uploaded == 1 && vaultA.Find(pending.Id) == null, "hidden pending image is removed only after successful upload");
            Check(new FolderImageSync(textB, vaultB).State.Device == b.State.Device, "image causal state survives restart");
            b.Poll(t + Wire.Lifetime + 1000);
            Check(vaultB.List(t + Wire.Lifetime + 1000).Count == 0, "original image expiry prunes local history without retry extension");
            Check(!File.Exists(Path.Combine(a.ImagesPath, first.Id + ".img")) && !File.Exists(Path.Combine(a.ImagesPath, ImageWire.ChunkName(first.Id, 0))), "expired manifest and owned chunks are cleaned together");
            var limited = new ImageVault(Path.Combine(root, "bounded"), key, _ => { });
            for (int i = 0; i < 100; i++) { var r = FolderImageSync.Create(png, Guid.NewGuid().ToString(), pair.Space, a.State.Device, "bounded", i + 1, t, []); limited.Put(r, png, true, t); }
            var overflow = FolderImageSync.Create(png, Guid.NewGuid().ToString(), pair.Space, a.State.Device, "bounded", 101, t, []);
            Reject(() => limited.Put(overflow, png, true, t), "100-record cap rejects additions instead of evicting pending images");
            Check(limited.List(t).Count == 100 && limited.List(t).All(x => x.Pending), "bounded store preserves all pending images");
            var isolated = new ImageVault(Path.Combine(root, "isolated"), key, _ => { });
            var healthy = FolderImageSync.Create(png, Guid.NewGuid().ToString(), pair.Space, a.State.Device, "healthy", 1, t, []);
            var damaged = healthy with { Id = Guid.NewGuid().ToString() };
            isolated.Put(healthy, png, false, t); isolated.Put(damaged, png, true, t);
            File.WriteAllBytes(Path.Combine(root, "isolated", damaged.Id + ".blob"), new byte[28]);
            Check(isolated.History(t).Select(x => x.Id).SequenceEqual(new[] { healthy.Id }) && isolated.Rejected == 1, "one corrupt payload does not block healthy image history or startup");
            Check(isolated.Find(damaged.Id)?.Pending == true, "corrupt pending image is preserved for recovery rather than silently evicted");
            File.WriteAllBytes(Path.Combine(root, "isolated", damaged.Id + ".meta"), new byte[28]);
            Check(isolated.History(t).Any(x => x.Id == healthy.Id), "corrupt metadata is isolated without disabling all recording");

            string scanRoot = Path.Combine(root, "scan"); Directory.CreateDirectory(scanRoot);
            FolderSync.Setup(scanRoot, pair, true);
            var scanText = new FolderSync(scanRoot, Path.Combine(root, "scan-state"), pair, "scan receiver");
            var scanVault = new ImageVault(Path.Combine(root, "scan-vault"), key, _ => { });
            var scanner = new FolderImageSync(scanText, scanVault); scanner.Poll(t);
            for (int i = 0; i < 1000; i++) File.WriteAllBytes(Path.Combine(scanner.ImagesPath, $"00000000-0000-4000-8000-{i:x12}.img"), new byte[28]);
            var tail = FolderImageSync.Create(png, "ffffffff-ffff-4fff-8fff-ffffffffffff", pair.Space, a.State.Device, "tail", 1, t, []);
            File.WriteAllBytes(Path.Combine(scanner.ImagesPath, ImageWire.ChunkName(tail.Id, 0)), ImageWire.SealChunk(png, tail, 0, pair));
            File.WriteAllBytes(Path.Combine(scanner.ImagesPath, tail.Id + ".img"), ImageWire.SealManifest(tail, pair));
            Check(scanner.Poll(t + 1).Rejected == 1000 && scanVault.Find(tail.Id) == null, "manifest scan is bounded to 1000 candidates per pass");
            Check(scanner.Poll(t + 2).Records.Any(x => x.Id == tail.Id), "1001 candidates rotate instead of permanently starving the valid tail");
            var deniedId = Guid.NewGuid().ToString();
            Reject(() => ImageWire.ChunkName("../" + deniedId, 0), "untrusted paths cannot enter chunk filenames");
            Console.WriteLine($"{checks} image protocol, privacy, queue and retention checks passed");
        }
        finally { Directory.Delete(root, true); }
    }
    static byte[] InsertChunk(byte[] png, string type, byte[] payload)
    {
        byte[] chunk = new byte[payload.Length + 12]; BinaryPrimitives.WriteInt32BigEndian(chunk.AsSpan(0, 4), payload.Length);
        Encoding.ASCII.GetBytes(type).CopyTo(chunk, 4); payload.CopyTo(chunk, 8); uint crc = 0xffffffff;
        foreach (byte b in chunk.AsSpan(4, payload.Length + 4)) { crc ^= b; for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320u : 0u); }
        BinaryPrimitives.WriteUInt32BigEndian(chunk.AsSpan(chunk.Length - 4), crc ^ 0xffffffff);
        return [.. png.AsSpan(0, 33).ToArray(), .. chunk, .. png.AsSpan(33).ToArray()];
    }
}
