using System.Security.Cryptography;
using ClipDay.Sync;

if (args.Length == 1 && args[0] == "pairing") { await PairingTests.Run(); return; }
if (args.Length == 1 && args[0] == "pairing-regressions") { await PairingRegressionTests.Run(); return; }
if (args.Length == 1 && args[0] == "reliability") { await ReliabilityRegressionTests.Run(); return; }
if (args.Length == 1 && args[0] == "images") { await ImageRegressionTests.Run(); return; }
if (args.Length == 0) { await ReliabilityRegressionTests.Run(); await ImageRegressionTests.Run(); }
if (args.Length == 1 && args[0] == "drive") { await DriveFolderTests.Run(); return; }
if (args.Length == 0) await DriveFolderTests.Run();
int checks = 0;
void Check(bool ok, string label) { if (!ok) throw new Exception("FAIL: " + label); checks++; Console.WriteLine("PASS: " + label); }
void Reject(Action action, string label) { bool rejected = false; try { action(); } catch { rejected = true; } Check(rejected, label); }
if (args.Length == 2 && args[0] == "interop")
{
    var pair = new Pair(1, "c1416f42-de6e-43e0-97f0-122e9016a926", Convert.ToBase64String(Enumerable.Range(0, 32).Select(x => (byte)x).ToArray()));
    var b = new FolderSync(args[1], Path.Combine(args[1], "csharp"), pair, "Windows interop");
    var batch = b.Poll();
    Check(batch.Records.Any(x => x.Text == "Swift → C# 你好 👋\nline two"), "Swift AES-GCM records decrypt in C#");
    b.Enqueue("C# → Swift 你好 🪟\r\nline two"); b.Poll(); return;
}
var root = Path.Combine(Path.GetTempPath(), "ClipDaySync-tests-" + Guid.NewGuid());
Directory.CreateDirectory(root);
try
{
    long t = 1_800_000_000_000;
    var pair = Pair.Create(); FolderSync.Setup(root, pair, true);
    Check(Pair.Parse(pair.Code) == pair, "pairing round trip");
    var a = new FolderSync(root, Path.Combine(root, "a"), pair, "Windows");
    var b = new FolderSync(root, Path.Combine(root, "b"), pair, "Mac");
    a.Poll(t); b.Poll(t);
    var first = a.Enqueue("hello 你好\r\n🪟", t + 100); a.Poll(t + 200);
    var received = b.Poll(t + 300);
    Check(received.Automatic?.Id == first.Id, "live text arrives and is eligible for paste");
    b.Acknowledge(received.Records);
    Check(b.Poll(t + 400).Records.Count == 0, "duplicate files ignored");
    var reply = b.Enqueue("reply", t + 500); b.Poll(t + 600);
    Check(a.Poll(t + 700).Automatic?.Id == reply.Id, "causal reverse copy arrives");
    a.Enqueue("simultaneous A", t + 800); b.Enqueue("simultaneous B", t + 800);
    var ap = a.Poll(t + 900); var bp = b.Poll(t + 900); var ap2 = a.Poll(t + 1000);
    Check(ap.Automatic == null && bp.Automatic == null && ap2.Automatic == null, "simultaneous copies stay in history");
    b.Suspend(); a.Enqueue("backlog", t + 1100); a.Poll(t + 1200);
    var catchup = b.Poll(t + 1300);
    Check(catchup.Automatic == null && catchup.Records.Any(x => x.Text == "backlog"), "reconnect is history-only");
    var restarted = new FolderSync(root, b.Local, pair, "Mac");
    Check(!restarted.Poll(t + 1400).Records.Any(x => x.Id == first.Id), "acknowledged records do not resurrect after restart");
    Check(restarted.History(t + 1400).Any(x => x.Text == "backlog"), "inbox persists across restart");
    var partial = a.Enqueue("partial", t + 1500); var data = Wire.Seal(partial, pair);
    var file = Path.Combine(a.RecordsPath, partial.Id + ".clip"); File.WriteAllBytes(file, data[..15]);
    Check(b.Poll(t + 1600).Rejected > 0, "truncated record rejected");
    File.WriteAllBytes(file, data);
    Check(b.Poll(t + 1700).Records.Any(x => x.Id == partial.Id), "truncated records retried after repair");
    var tampered = data.ToArray(); tampered[20] ^= 1;
    Reject(() => Wire.Open(tampered, pair), "tampering rejected");
    Reject(() => Wire.Open(data, pair with { Key = Pair.Create().Key }), "wrong key rejected");
    Reject(() => Wire.Open(data, pair with { Space = Guid.NewGuid().ToString() }), "wrong space rejected");
    var future = partial with { Id = Guid.NewGuid().ToString(), Seq = 999, Created = t + 600000, Expires = t + 600000 + Wire.Lifetime };
    File.WriteAllBytes(Path.Combine(a.RecordsPath, future.Id + ".clip"), Wire.Seal(future, pair));
    Check(b.Poll(t + 1800).Rejected > 0, "large clock skew rejected");
    Directory.Move(Path.Combine(root, "ClipDaySync"), Path.Combine(root, "parked"));
    Reject(() => b.Poll(t + 1900), "NAS disappearance handled");
    b.Enqueue("offline queued", t + 2000);
    Check(!Directory.Exists(Path.Combine(root, "ClipDaySync")), "missing NAS never recreated locally");
    Directory.Move(Path.Combine(root, "parked"), Path.Combine(root, "ClipDaySync")); b.Poll(t + 2100);
    Check(a.Poll(t + 2200).Records.Any(x => x.Text == "offline queued"), "offline outbox retries successfully");
    b.Poll(t + Wire.Lifetime + 700000);
    Check(b.History(t + Wire.Lifetime + 700000).Count == 0, "expired inbox removed");
    Check(!File.Exists(Path.Combine(a.RecordsPath, first.Id + ".clip")), "expired NAS record removed");
    File.WriteAllBytes(file, data);
    Check(b.Poll(t + Wire.Lifetime + 800000).Records.Count == 0, "restored expired files cannot resurrect history");
    Reject(() => a.Enqueue(new string('x', Wire.MaxText + 1)), "size bound enforced");
    Check(!System.Text.Encoding.UTF8.GetString(Wire.Seal(first, pair)).Contains(first.Text), "ciphertext does not contain plaintext");
    Console.WriteLine($"{checks} C# sync checks passed");
}
finally { Directory.Delete(root, true); }
