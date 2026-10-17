using ClipDay.Cloud;
using ClipDay.Sync;

internal static class ReliabilityRegressionTests
{
    public static async Task Run()
    {
        int checks = 0;
        void Check(bool ok, string label) { if (!ok) throw new Exception("FAIL: " + label); checks++; Console.WriteLine("PASS: " + label); }
        async Task Reject(Func<Task> action, string label)
        {
            bool failed = false; try { await action(); } catch (IOException) { failed = true; }
            Check(failed, label);
        }
        var state = new ClipboardCaptureState(); state.Ignore(10);
        Check(!state.ShouldCapture(10) && state.ShouldCapture(11), "only a new unacknowledged clipboard sequence is captured");
        var attempt = state.Begin(11, "retry me", 1000); int queueCalls = 0;
        await Reject(() => state.CommitAsync(attempt, () => Task.FromException(new IOException("disk full")), () => { queueCalls++; return Task.CompletedTask; }), "history write failure is reported");
        Check(state.LastSequence == 10 && state.ShouldCapture(11) && !attempt.SavedLocally && queueCalls == 0, "failed local persistence neither acknowledges nor queues the capture");
        Check(ReferenceEquals(attempt, state.Begin(11, "retry me", 2000)), "capture retry preserves record identity and original timestamp");
        await Reject(() => state.CommitAsync(attempt, () => Task.CompletedTask, () => Task.FromException(new IOException("queue full"))), "queue write failure is reported");
        Check(state.LastSequence == 10 && attempt.SavedLocally && state.Pending == attempt, "local-save-only outcome remains retryable until the queue is safe");
        Check(await state.CommitAsync(attempt, () => Task.CompletedTask, () => { queueCalls++; return Task.CompletedTask; }), "retry completes after local and queue writes succeed");
        Check(state.LastSequence == 11 && state.Pending == null && queueCalls == 1 && !state.ShouldCapture(11), "successful capture is acknowledged exactly once");
        var local = state.Begin(12, "local only", 2000);
        Check(await state.CommitAsync(local, () => Task.CompletedTask, null) && state.LastSequence == 12, "sync pause still permits durable local-only capture");

        var stale = state.Begin(13, "old", 3000);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var staleCommit = state.CommitAsync(stale, () => release.Task, () => { queueCalls++; return Task.CompletedTask; });
        var newer = state.Begin(14, "new", 3001); release.SetResult();
        Check(!await staleCommit && state.Pending == newer && state.LastSequence == 12 && queueCalls == 1, "late completion cannot acknowledge or queue a superseded capture");

        state.SetPrivacyPaused(true, 20);
        Check(!state.ShouldCapture(21) && state.Pending == null, "privacy pause suppresses capture and clears pending clipboard text");
        bool blocked = false; try { state.Begin(21, "private", 4000); } catch (InvalidOperationException) { blocked = true; }
        Check(blocked, "private clipboard content cannot create a capture attempt");
        Check(!await state.CommitAsync(newer, () => throw new Exception("must not save"), () => throw new Exception("must not enqueue")), "privacy pause prevents deferred persistence from starting");
        state.SetPrivacyPaused(false, 25);
        Check(!state.ShouldCapture(25) && state.ShouldCapture(26), "resuming skips the entire private clipboard interval");
        var inFlight = state.Begin(26, "before pause", 5000);
        var releaseSave = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var inFlightCommit = state.CommitAsync(inFlight, () => releaseSave.Task, () => { queueCalls++; return Task.CompletedTask; });
        state.SetPrivacyPaused(true, 27); releaseSave.SetResult();
        Check(!await inFlightCommit && state.LastSequence == 27 && queueCalls == 1, "pause during a local write prevents the following queue write and late acknowledgement");
        state.SetPrivacyPaused(false, 30);
        var uploading = state.Begin(31, "already queued", 6000);
        var releaseQueue = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var uploadingCommit = state.CommitAsync(uploading, () => Task.CompletedTask, () => releaseQueue.Task);
        state.SetPrivacyPaused(true, 32); releaseQueue.SetResult();
        Check(!await uploadingCommit && state.LastSequence == 32 && state.Pending == null, "an already-issued queue write cannot re-enable capture after privacy pause");

        var root = Path.Combine(Path.GetTempPath(), "ClipDay-reliability-" + Guid.NewGuid()); Directory.CreateDirectory(root);
        try
        {
            var missing = Path.Combine(root, "missing"); var missingResult = FolderDiagnostics.Check(missing);
            Check(!missingResult.Reachable && !missingResult.Success && !Directory.Exists(missing), "diagnostics do not recreate a missing NAS path");
            var sentinel = Path.Combine(root, "keep.txt"); File.WriteAllText(sentinel, "untouched");
            Check(!FolderDiagnostics.Check(sentinel).Success, "a file cannot pass as a NAS directory");
            var good = FolderDiagnostics.Check(root);
            Check(good.Reachable && good.Readable && good.Writable && good.Success, "diagnostics verify directory listing and write/rename/read-back/delete");
            Check(File.ReadAllText(sentinel) == "untouched" && Directory.GetFileSystemEntries(root).Length == 1, "diagnostics preserve existing data and remove only their own probe");
            var firstRun = Path.Combine(root, "first-run"); Directory.CreateDirectory(firstRun); // Program.Main creates Storage.Root before LoadState.
            Check(!PrivacyPreferences.Read(firstRun), "first launch starts normally with an existing empty application-data directory");
            Check(!PrivacyPreferences.Read(root), "older installs without privacy preferences retain their default behavior");
            PrivacyPreferences.Save(root, true);
            Check(PrivacyPreferences.Read(root), "privacy pause persists before pairing and across restart");
            PrivacyPreferences.Save(root, false);
            Check(!PrivacyPreferences.Read(root), "explicit privacy resume persists across restart");
            File.WriteAllText(Path.Combine(root, "privacy.json"), "invalid");
            bool invalidPrivacy = false; try { PrivacyPreferences.Read(root); } catch (System.Text.Json.JsonException) { invalidPrivacy = true; }
            Check(invalidPrivacy, "corrupt privacy state is surfaced for fail-closed loading instead of silently enabling capture");
            var pair = Pair.Create(); FolderSync.Setup(root, pair, true);
            var sync = new FolderSync(root, Path.Combine(root, "local"), pair, "Test");
            long now = 1_800_000_000_000; var id = Guid.NewGuid().ToString();
            Directory.CreateDirectory(Path.Combine(sync.Outbox, id + ".clip"));
            await Reject(() => { sync.Enqueue("queue retry", now, id); return Task.CompletedTask; }, "outbox persistence failure remains visible");
            Directory.Delete(Path.Combine(sync.Outbox, id + ".clip"));
            var queued = sync.Enqueue("queue retry", now, id); var seq = sync.State.Seq;
            var same = sync.Enqueue("queue retry", now, id);
            Check(queued.Id == same.Id && seq == sync.State.Seq && Directory.GetFiles(sync.Outbox, "*.clip").Length == 1, "retrying a durable capture ID does not duplicate the outbox or advance its sequence");
            bool conflict = false; try { sync.Enqueue("different text", now, id); } catch (InvalidDataException) { conflict = true; }
            Check(conflict, "idempotent enqueue rejects a reused ID with different text");
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            bool cancelledPoll = false; try { sync.Poll(now, cancelled.Token); } catch (OperationCanceledException) { cancelledPoll = true; }
            Check(cancelledPoll && File.Exists(Path.Combine(sync.Outbox, id + ".clip")) && Directory.GetFiles(sync.RecordsPath, "*.clip").Length == 0, "privacy-cancelled poll preserves the queue without sending");
            var uploaded = sync.Poll(now + 10);
            Check(uploaded.Uploaded == 1 && Directory.GetFiles(sync.Outbox, "*.clip").Length == 0, "NAS upload is reported only after its file write succeeds");
            Check(sync.Poll(now + 20).Uploaded == 0, "an idle poll does not claim another upload or receiver confirmation");
            var receiver = new FolderSync(root, Path.Combine(root, "receiver"), pair, "Receiver");
            bool cancelledReceive = false; try { receiver.Poll(now + 20, cancelled.Token); } catch (OperationCanceledException) { cancelledReceive = true; }
            Check(cancelledReceive && receiver.History(now + 20).Count == 0, "privacy-cancelled poll does not receive pending remote text");
            var resumed = receiver.Poll(now + 25);
            Check(resumed.Automatic == null && resumed.Records.Any(r => r.Id == id), "resumed receiver catches up in history without replacing the clipboard");
            sync.Enqueue("expired", now - Wire.Lifetime - 100);
            Check(sync.Poll(now + 30).Uploaded == 0, "expired queue cleanup is not reported as an upload");
            Check(new FolderSync(root, sync.Local, pair, "Restarted").State.Device == sync.State.Device, "existing sync state remains compatible after restart");
        }
        finally { Directory.Delete(root, true); }
        Console.WriteLine($"{checks} Windows reliability/privacy/diagnostic checks passed");
    }
}
