using ClipDay.Sync;
using ClipDay.Cloud;

internal static class PairingRegressionTests
{
    public static async Task Run()
    {
        void Check(bool ok, string label) { if (!ok) throw new Exception("FAIL: " + label); Console.WriteLine("PASS: " + label); }
        var view = new PairingViewState();
        var first = view.Begin();
        Check(view.TryApply(first, new("offer")) && view.TryApply(first, new("success")), "current pairing displays offer and success");
        Check(!view.TryApply(first, new("error")) && !view.TryApply(first, new("expired")), "late failure and expiry cannot overwrite success");
        Check(!view.TryApply(first, new("offer")), "queued offer cannot restart countdown after success");
        var oldHost = view.Begin(); var join = view.Begin();
        Check(!view.TryApply(oldHost, new("error")) && !view.TryApply(oldHost, new("success")), "old host callbacks are invalidated before joining");
        Check(view.TryApply(join, new("success")), "joining success belongs to its own session");
        var retry = view.Begin();
        Check(view.TryApply(retry, new("error")), "a genuine new attempt can still report failure");
        Check(!view.TryApply(retry, new("success")), "terminal failure cannot be overwritten by delayed success");
        var root = Path.Combine(Path.GetTempPath(), "ClipDayPair-regression-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var pair = Pair.Create(); FolderSync.Setup(root, pair, true);
            using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            var offer = new TaskCompletionSource<PairEvent>(TaskCreationOptions.RunContinuationsAsynchronously);
            bool successShown = false;
            string lease = Path.Combine(root, "ClipDaySync", "Pairing-v2", "active.lock");
            var host = ShortPairing.HostAsync(root, pair, ev => {
                if (ev.Type == "offer") offer.TrySetResult(ev);
                if (ev.Type == "success") {
                    successShown = true;
                    // Simulate a NAS path becoming inaccessible during post-success cleanup.
                    File.Delete(lease); Directory.CreateDirectory(lease);
                }
            }, cancel.Token);
            var shown = await offer.Task.WaitAsync(cancel.Token);
            var joined = await ShortPairing.JoinAsync(root, shown.Code!, cancel.Token);
            if (joined != pair || !successShown) throw new Exception("FAIL: handshake must succeed before cleanup failure");
            Console.WriteLine("PASS: credentials delivered before simulated NAS cleanup failure");
            try { await host; }
            catch (Exception e) { throw new Exception("FAIL: cleanup turned successful pairing into " + e.GetType().Name); }
            Console.WriteLine("PASS: post-success cleanup cannot reverse pairing result");
        }
        finally { Directory.Delete(root, true); }
    }
}
