using ClipDay.Sync;
using System.Text.Json;

internal static class PairingTests
{
    public static async Task Run()
    {
        int count = 0;
        void Check(bool ok, string label) { if (!ok) throw new Exception("FAIL: " + label); count++; Console.WriteLine("PASS: " + label); }
        async Task Reject(Func<Task> action, string label) { bool failed = false; try { await action(); } catch { failed = true; } Check(failed, label); }
        string root = Path.Combine(Path.GetTempPath(), "ClipDayPair-test-" + Guid.NewGuid()); Directory.CreateDirectory(root);
        try
        {
            var pair = Pair.Create(); FolderSync.Setup(root, pair, true);
            using var cancel = new CancellationTokenSource();
            var ready = new TaskCompletionSource<PairEvent>(TaskCreationOptions.RunContinuationsAsynchronously);
            var retry = new TaskCompletionSource<PairEvent>(TaskCreationOptions.RunContinuationsAsynchronously);
            var events = new List<PairEvent>(); int offers = 0;
            var host = ShortPairing.HostAsync(root, pair, ev => { events.Add(ev); if (ev.Type == "offer") { if (++offers == 1) ready.TrySetResult(ev); else retry.TrySetResult(ev); } }, cancel.Token);
            var shown = await ready.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Check(shown.Code?.Length == 6 && shown.Code.All(char.IsAsciiDigit) && shown.Expires > Wire.Now, "host shows six digits and a future expiry");
            var pairingDir = Path.Combine(root, "ClipDaySync", "Pairing-v2");
            var offer = JsonSerializer.Deserialize(File.ReadAllBytes(Path.Combine(pairingDir, "active.json")), PairJson.Default.PairOffer)!;
            var json = File.ReadAllText(Path.Combine(pairingDir, "active.json"));
            Check(!json.Contains(pair.Key) && !json.Contains("\"code\"") && !json.Contains("\"verifier\""), "NAS offer contains neither PIN/verifier nor sync key");
            await Reject(() => ShortPairing.HostAsync(root, pair, _ => {}, CancellationToken.None, 1), "second host cannot replace a live invitation");
            string wrong = shown.Code == "000000" ? "000001" : "000000";
            await Reject(async () => { await ShortPairing.JoinAsync(root, wrong, cancel.Token); }, "wrong PIN cannot recover sync key");
            var again = await retry.Task.WaitAsync(TimeSpan.FromSeconds(10));
            var next = JsonSerializer.Deserialize(File.ReadAllBytes(Path.Combine(pairingDir, "active.json")), PairJson.Default.PairOffer)!;
            Check(again.Code == shown.Code && next.Round != offer.Round && next.B != offer.B, "retry keeps visible PIN but rotates SRP ephemeral and round");
            var joined = await ShortPairing.JoinAsync(root, shown.Code!, cancel.Token);
            Check(joined == pair, "correct PIN securely delivers original random key");
            await host.WaitAsync(TimeSpan.FromSeconds(10));
            Check(events.Any(x => x.Type == "success") && !File.Exists(Path.Combine(pairingDir, "active.json")), "successful invitation is consumed immediately");
            await Reject(async () => { await ShortPairing.JoinAsync(root, shown.Code!, cancel.Token); }, "consumed code cannot be reused");
            Check(!Directory.GetFiles(pairingDir).Any(x => x.EndsWith(".request") || x.EndsWith(".response")), "handshake files cleaned after success");
            var expiring = new List<PairEvent>();
            await ShortPairing.HostAsync(root, pair, ev => expiring.Add(ev), cancel.Token, 1);
            Check(expiring.Any(x => x.Type == "expired") && !File.Exists(Path.Combine(pairingDir, "active.json")), "deadline removes offer and reports expiry");
            using var stop = new CancellationTokenSource();
            var cancelledReady = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var stopped = ShortPairing.HostAsync(root, pair, ev => { if (ev.Type == "offer") cancelledReady.TrySetResult(); }, stop.Token);
            await cancelledReady.Task; stop.Cancel(); try { await stopped; } catch (OperationCanceledException) { }
            Check(!File.Exists(Path.Combine(pairingDir, "active.json")), "cancel removes invitation without waiting for expiry");
            Check(ShortPairing.NormalizeCode(" 012 345 ") == "012345", "leading zeros and grouped digits accepted");
            await Reject(() => Task.FromResult(ShortPairing.NormalizeCode("１２３４５６")), "non-ASCII code rejected");
            var rateReady = new TaskCompletionSource<PairEvent>(TaskCreationOptions.RunContinuationsAsynchronously);
            int round = 0;
            var limited = ShortPairing.HostAsync(root, pair, ev => { if (ev.Type == "offer") { Interlocked.Increment(ref round); rateReady.TrySetResult(ev); } }, cancel.Token);
            var rateOffer = await rateReady.Task;
            string bad = rateOffer.Code == "111111" ? "222222" : "111111";
            for (int i = 0; i < 5; i++) {
                while (Volatile.Read(ref round) <= i) await Task.Delay(50);
                await Reject(async () => { await ShortPairing.JoinAsync(root, bad, cancel.Token); }, $"online wrong attempt {i + 1} rejected");
            }
            await limited.WaitAsync(TimeSpan.FromSeconds(10));
            Check(!File.Exists(Path.Combine(pairingDir, "active.json")), "five wrong attempts invalidate the whole code");
            Console.WriteLine($"{count} short pairing checks passed");
        }
        finally { Directory.Delete(root, true); }
    }
}
