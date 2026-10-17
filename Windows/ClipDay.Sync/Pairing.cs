using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Org.BouncyCastle.Crypto.Agreement.Srp;
using Org.BouncyCastle.Crypto.Digests;
using Org.BouncyCastle.Math;
using Org.BouncyCastle.Security;

namespace ClipDay.Sync;

public record PairOffer(int V, string Id, string Round, long Expires, string Salt, string B);
public record PairRequest(string Id, string Round, string A, string M1);
public record PairResponse(string Id, string Round, string M2, string Sealed, string Error);
public record PairCommand(string Mode, string Folder, Pair? Pair, string? Code);
public record PairEvent(string Type, string? Code = null, long Expires = 0, string? Message = null, Pair? Pair = null);
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(PairOffer))]
[JsonSerializable(typeof(PairRequest))]
[JsonSerializable(typeof(PairResponse))]
[JsonSerializable(typeof(PairCommand))]
[JsonSerializable(typeof(PairEvent))]
[JsonSerializable(typeof(Pair))]
public partial class PairJson : JsonSerializerContext { }

// One implementation on both platforms: native AOT helper on Mac, in-process on Windows.
// Bouncy Castle SRP-6a (RFC 5054 group, SHA-256) protects a short PIN against offline guesses.
public static class ShortPairing
{
    public const int LifetimeSeconds = 120;
    const int MaxAttempts = 5;
    static readonly Org.BouncyCastle.Crypto.Parameters.Srp6GroupParameters Group = Srp6StandardGroups.rfc5054_3072;
    static byte[] Identity(PairOffer offer) => Encoding.UTF8.GetBytes("clipday-pair-v2:" + offer.Id + ":" + offer.Round);
    static string Encode(BigInteger n) => Convert.ToBase64String(n.ToByteArrayUnsigned());
    static BigInteger Number(string value, int max = 384)
    {
        byte[] data = Convert.FromBase64String(value);
        if (data.Length == 0 || data.Length > max) throw new InvalidDataException();
        var n = new BigInteger(1, data);
        if (n.SignValue <= 0 || n.CompareTo(Group.N) >= 0) throw new InvalidDataException();
        return n;
    }
    public static string NormalizeCode(string code)
    {
        code = code.Replace(" ", "").Trim();
        if (code.Length != 6 || code.Any(c => c < '0' || c > '9')) throw new InvalidDataException("请输入另一台电脑显示的 6 位数字。");
        return code;
    }
    static string DirectoryPath(string folder)
    {
        if (!Directory.Exists(folder) || !Directory.Exists(Path.Combine(folder, "ClipDaySync"))) throw new IOException("请检查 NAS 路径；首台电脑需要先创建同步空间。");
        return Path.Combine(folder, "ClipDaySync", "Pairing-v2");
    }
    static T Read<T>(string path, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type)
    {
        if (new FileInfo(path).Length > 8192) throw new InvalidDataException();
        return JsonSerializer.Deserialize(Wire.Read(path), type) ?? throw new InvalidDataException();
    }
    static PairOffer ReadOffer(string dir)
    {
        var offer = Read(Path.Combine(dir, "active.json"), PairJson.Default.PairOffer);
        if (offer.V != 2 || !Wire.IsId(offer.Id) || !Wire.IsId(offer.Round) || offer.Expires <= Wire.Now || offer.Expires > Wire.Now + 300000 || Convert.FromBase64String(offer.Salt).Length != 32) throw new InvalidDataException("配对码已过期，请在另一台电脑重新生成。");
        return offer;
    }
    // Serialize cooperating writers on the NAS; never delete another live invitation.
    static void Publish(string dir, string id, PairOffer? offer)
    {
        using var lease = new FileStream(Path.Combine(dir, "active.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        var path = Path.Combine(dir, "active.json");
        if (File.Exists(path))
        {
            var previous = Read(path, PairJson.Default.PairOffer);
            if (previous.Id != id && previous.Expires > Wire.Now) throw new IOException("这个文件夹已有一台电脑正在显示配对码，请在另一台输入，或等它过期。");
            if (offer == null && previous.Id != id) return;
        }
        if (offer != null) Wire.Atomic(path, JsonSerializer.SerializeToUtf8Bytes(offer, PairJson.Default.PairOffer));
        else if (File.Exists(path)) File.Delete(path);
    }
    static void DeleteOwn(string path) { try { if (File.Exists(path)) File.Delete(path); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { } }
    static bool Recoverable(Exception e) => e is IOException or InvalidDataException or JsonException or FormatException or ArgumentException or Org.BouncyCastle.Crypto.CryptoException;

    public static async Task HostAsync(string folder, Pair pair, Action<PairEvent> report, CancellationToken cancel, int lifetimeSeconds = LifetimeSeconds)
    {
        pair.Validate();
        string dir = DirectoryPath(folder), id = Guid.NewGuid().ToString();
        Directory.CreateDirectory(dir);
        string code = RandomNumberGenerator.GetInt32(1000000).ToString("D6");
        long expires = Wire.Now + lifetimeSeconds * 1000L;
        var elapsed = Stopwatch.StartNew();
        List<string> ownFiles = [];
        bool published = false;
        try
        {
            for (int attempt = 0; attempt < MaxAttempts; attempt++)
            {
                cancel.ThrowIfCancellationRequested();
                if (Wire.Now >= expires || elapsed.Elapsed.TotalSeconds >= lifetimeSeconds) break;
                var salt = RandomNumberGenerator.GetBytes(32);
                var skeleton = new PairOffer(2, id, Guid.NewGuid().ToString(), expires, Convert.ToBase64String(salt), "");
                var verifier = new Srp6VerifierGenerator(); verifier.Init(Group, new Sha256Digest());
                var v = verifier.GenerateVerifier(salt, Identity(skeleton), Encoding.ASCII.GetBytes(code));
                var srp = new Srp6Server(); srp.Init(Group, v, new Sha256Digest(), new SecureRandom());
                var offer = skeleton with { B = Encode(srp.GenerateServerCredentials()) };
                Publish(dir, id, offer); published = true;
                report(new("offer", code, expires, attempt == 0 ? "在另一台电脑输入这 6 位数字" : $"输入不匹配，还可尝试 {MaxAttempts - attempt} 次"));
                string requestFile = Path.Combine(dir, offer.Round + ".request"), responseFile = Path.Combine(dir, offer.Round + ".response");
                ownFiles.Add(requestFile); ownFiles.Add(responseFile);
                PairRequest? request = null;
                while (Wire.Now < expires && elapsed.Elapsed.TotalSeconds < lifetimeSeconds)
                {
                    await Task.Delay(200, cancel);
                    if (!File.Exists(requestFile)) continue;
                    try { request = Read(requestFile, PairJson.Default.PairRequest); break; }
                    catch (Exception e) when (Recoverable(e)) { continue; } // partial writes are retried, never deserialized unsafely
                }
                if (request == null) break;
                cancel.ThrowIfCancellationRequested();
                bool matched = false;
                try
                {
                    if (request.Id != id || request.Round != offer.Round) throw new InvalidDataException();
                    srp.CalculateSecret(Number(request.A));
                    matched = srp.VerifyClientEvidenceMessage(Number(request.M1, 32));
                }
                catch (Exception e) when (Recoverable(e)) { matched = false; }
                if (!matched)
                {
                    var rejected = new PairResponse(id, offer.Round, "", "", "配对码不匹配，请核对数字后重试。");
                    Wire.Atomic(responseFile, JsonSerializer.SerializeToUtf8Bytes(rejected, PairJson.Default.PairResponse));
                    if (attempt == MaxAttempts - 1) {
                        Publish(dir, id, null);
                        published = false;
                        report(new("expired", Message: "尝试次数已用完，请重新生成"));
                        var grace = Stopwatch.StartNew();
                        while (File.Exists(responseFile) && grace.Elapsed.TotalSeconds < 3) await Task.Delay(200, cancel);
                        return;
                    }
                    continue; // New salt, server ephemeral, and round identity for every online attempt.
                }
                var m2 = srp.CalculateServerEvidenceMessage();
                var key = SHA256.HashData(srp.CalculateSessionKey().ToByteArrayUnsigned());
                byte[] plain = JsonSerializer.SerializeToUtf8Bytes(pair, PairJson.Default.Pair), nonce = RandomNumberGenerator.GetBytes(12), ciphertext = new byte[plain.Length], tag = new byte[16];
                using (var aes = new AesGcm(key, 16)) aes.Encrypt(nonce, plain, ciphertext, tag, Identity(offer));
                CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(plain);
                cancel.ThrowIfCancellationRequested();
                if (Wire.Now >= expires || elapsed.Elapsed.TotalSeconds >= lifetimeSeconds) break;
                Publish(dir, id, null); // Consume before releasing the encrypted space key; replay cannot reuse the invitation.
                published = false; // Already consumed; later cleanup must not reopen the NAS invitation lock.
                var response = new PairResponse(id, offer.Round, Encode(m2), Convert.ToBase64String([.. nonce, .. ciphertext, .. tag]), "");
                Wire.Atomic(responseFile, JsonSerializer.SerializeToUtf8Bytes(response, PairJson.Default.PairResponse));
                report(new("success", Message: "配对成功，这组数字已失效"));
                // Give the peer time to collect the response; no PIN or key is left in plaintext.
                var delivery = Stopwatch.StartNew();
                while (File.Exists(responseFile) && Wire.Now < expires && delivery.Elapsed.TotalSeconds < 15) await Task.Delay(200, cancel);
                return;
            }
            report(new("expired", Message: Wire.Now >= expires || elapsed.Elapsed.TotalSeconds >= lifetimeSeconds ? "配对码已过期，点击重新生成" : "尝试次数已用完，请重新生成"));
        }
        finally
        {
            // Cleanup is best-effort and must not replace a completed handshake or its original error.
            if (published) { try { Publish(dir, id, null); } catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { } }
            foreach (var path in ownFiles) DeleteOwn(path);
        }
    }

    public static async Task<Pair> JoinAsync(string folder, string code, CancellationToken cancel)
    {
        code = NormalizeCode(code);
        string dir = DirectoryPath(folder);
        var offer = ReadOffer(dir);
        var srp = new Srp6Client(); srp.Init(Group, new Sha256Digest(), new SecureRandom());
        var a = srp.GenerateClientCredentials(Convert.FromBase64String(offer.Salt), Identity(offer), Encoding.ASCII.GetBytes(code));
        srp.CalculateSecret(Number(offer.B));
        var request = new PairRequest(offer.Id, offer.Round, Encode(a), Encode(srp.CalculateClientEvidenceMessage()));
        var requestFile = Path.Combine(dir, offer.Round + ".request");
        var responseFile = Path.Combine(dir, offer.Round + ".response");
        // Reserve one attempt; do not overwrite another client's request.
        using (var file = new FileStream(requestFile, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        { var data = JsonSerializer.SerializeToUtf8Bytes(request, PairJson.Default.PairRequest); file.Write(data); file.Flush(); }
        var waiting = Stopwatch.StartNew();
        try
        {
            while (Wire.Now < offer.Expires && waiting.Elapsed.TotalSeconds < 20)
            {
                await Task.Delay(200, cancel);
                if (!File.Exists(responseFile)) continue;
                PairResponse response;
                try { response = Read(responseFile, PairJson.Default.PairResponse); }
                catch (Exception e) when (Recoverable(e)) { continue; }
                if (response.Id != offer.Id || response.Round != offer.Round) throw new InvalidDataException("配对会话不匹配，请重新生成。");
                if (!string.IsNullOrEmpty(response.Error)) throw new InvalidDataException("配对码不匹配，请核对数字后重试。");
                if (!srp.VerifyServerEvidenceMessage(Number(response.M2, 32))) throw new InvalidDataException("配对验证失败，请重新生成。");
                var key = SHA256.HashData(srp.CalculateSessionKey().ToByteArrayUnsigned());
                var sealedData = Convert.FromBase64String(response.Sealed);
                if (sealedData.Length < 28 || sealedData.Length > 2048) throw new InvalidDataException();
                var plain = new byte[sealedData.Length - 28];
                try
                {
                    using var aes = new AesGcm(key, 16);
                    aes.Decrypt(sealedData.AsSpan(0, 12), sealedData.AsSpan(12, plain.Length), sealedData.AsSpan(sealedData.Length - 16), plain, Identity(offer));
                    var pair = JsonSerializer.Deserialize(plain, PairJson.Default.Pair) ?? throw new InvalidDataException(); pair.Validate();
                    cancel.ThrowIfCancellationRequested();
                    if (Wire.Now >= offer.Expires) throw new InvalidDataException("配对码已过期，请重新生成。");
                    return pair;
                }
                finally { CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(plain); }
            }
            throw new IOException("配对已过期或另一台电脑未响应，请重新生成数字后重试。");
        }
        finally { DeleteOwn(responseFile); } // Host owns request lifecycle; client never releases reservation early.
    }
}
