package io.jlmac.clipday.core;

import org.json.*;
import org.junit.*;
import static org.junit.Assert.*;
import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Fault-injected local fixtures only; no user's NAS or Android device is accessed. */
public class ReliabilityTest {
    Path root; LocalStore store; JSONObject pair;
    long now = System.currentTimeMillis();
    @Before public void setup() throws Exception {
        root = Files.createTempDirectory("clipday-reliability-test-"); store = new LocalStore(root); pair = CoreTest.fixturePair();
        Files.createDirectories(root.resolve(Wire.spaceRoot(pair) + "records"));
        store.atomic(Wire.spaceRoot(pair) + "space.json", Wire.json(new JSONObject().put("v", 1).put("space", pair.getString("space"))));
        store.atomic(Wire.spaceRoot(pair) + "space.check", Wire.sealRecord(record("clipday-space-v1").put("id", pair.getString("space")), pair));
    }
    @After public void cleanup() throws Exception { try (var walk = Files.walk(root)) { for (Path p : walk.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(p); } }
    JSONObject record(String text) throws Exception { return new JSONObject().put("v", 1).put("space", pair.getString("space")).put("id", Wire.id()).put("device", Wire.id()).put("name", "test desktop").put("seq", 1).put("created", now).put("expires", now + Wire.LIFETIME).put("observed", new JSONObject()).put("text", text); }
    SyncEngine engine() throws Exception { SyncEngine e = new SyncEngine(null, next -> {}); e.activate(new JSONObject(), pair); return e; }
    void publish(JSONObject r) throws Exception { store.atomic(Wire.spaceRoot(pair) + "records/" + r.getString("id") + ".clip", Wire.sealRecord(r, pair)); }
    private static class ForwardingStore implements Store {
        final Store inner;
        ForwardingStore(Store inner) { this.inner = inner; }
        public byte[] read(String p, int n) throws Exception { return inner.read(p, n); }
        public boolean exists(String p) throws Exception { return inner.exists(p); }
        public List<String> list(String p) throws Exception { return inner.list(p); }
        public void create(String p, byte[] b) throws Exception { inner.create(p, b); }
        public void atomic(String p, byte[] b) throws Exception { inner.atomic(p, b); }
        public void delete(String p) throws Exception { inner.delete(p); }
        public void close() { }
    }
    @Test public void durableCaptureDoesNotWaitForBusyNetworkAndMergeKeepsIt() throws Exception {
        JSONObject remote = record("incoming while saving"); publish(remote);
        AtomicReference<JSONObject> durable = new AtomicReference<>();
        SyncEngine e = new SyncEngine(null, next -> durable.set(Wire.cloneJson(next))); e.activate(new JSONObject(), pair);
        CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
        Store slow = new ForwardingStore(store) {
            @Override public List<String> list(String p) throws Exception {
                entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)); return super.list(p);
            }
        };
        ExecutorService workers = Executors.newFixedThreadPool(2);
        try {
            Future<SyncEngine.PollResult> polling = workers.submit(() -> e.pollDetailed(slow, now, () -> true));
            assertTrue(entered.await(5, TimeUnit.SECONDS));
            String id = workers.submit(() -> e.enqueue("must save during a network timeout", "Android", now + 1)).get(2, TimeUnit.SECONDS);
            assertEquals(id, durable.get().getJSONArray("pending").getJSONObject(0).getString("id"));
            release.countDown(); assertEquals(1, polling.get(5, TimeUnit.SECONDS).received);
            assertEquals(1, e.snapshot().getJSONArray("pending").length());
            assertEquals(2, e.snapshot().getJSONArray("history").length());
            SyncEngine restarted = new SyncEngine(durable.get(), next -> durable.set(Wire.cloneJson(next)));
            assertEquals(1, restarted.pollDetailed(store, now + 1, () -> true).uploaded);
            assertEquals(0, restarted.snapshot().getJSONArray("pending").length());
        } finally { release.countDown(); workers.shutdownNow(); }
    }
    @Test public void partialUploadAcknowledgesOnlySuccessfulRecordsAndRetriesRemainder() throws Exception {
        SyncEngine e = engine(); String first = e.enqueue("first", "Android", now); String second = e.enqueue("second", "Android", now + 1);
        publish(record("receive still works"));
        Store flaky = new ForwardingStore(store) {
            @Override public void atomic(String p, byte[] b) throws Exception { if (p.contains(second)) throw new IOException(); super.atomic(p, b); }
        };
        SyncEngine.PollResult result = e.pollDetailed(flaky, now + 1, () -> true);
        assertTrue(result.partial()); assertEquals(1, result.uploaded); assertEquals(1, result.writeFailures); assertEquals(1, result.received);
        JSONArray pending = e.snapshot().getJSONArray("pending"); assertEquals(1, pending.length()); assertEquals(second, pending.getJSONObject(0).getString("id"));
        assertTrue(e.snapshot().getJSONObject("seen").has(first)); assertFalse(e.snapshot().getJSONObject("seen").has(second));
        assertEquals(1, e.pollDetailed(store, now + 1, () -> true).uploaded); assertEquals(3, e.snapshot().getJSONArray("history").length());
    }
    @Test public void directoryFailureDoesNotRollBackUploadedAcknowledgment() throws Exception {
        SyncEngine e = engine(); e.enqueue("uploaded", "Android", now);
        Store flaky = new ForwardingStore(store) { @Override public List<String> list(String p) throws Exception { throw new IOException(); } };
        SyncEngine.PollResult result = e.pollDetailed(flaky, now, () -> true);
        assertTrue(result.listingFailed); assertTrue(result.partial()); assertEquals(1, result.uploaded);
        assertEquals(0, e.snapshot().getJSONArray("pending").length());
    }
    @Test public void corruptFutureAndCleanupFailuresAreVisibleAndRetried() throws Exception {
        JSONObject corrupt = record("repair later"), expired = record("expired").put("created", now - Wire.LIFETIME).put("expires", now);
        JSONObject future = record("future").put("created", now + 400000).put("expires", now + 400000 + Wire.LIFETIME);
        String corruptPath = Wire.spaceRoot(pair) + "records/" + corrupt.getString("id") + ".clip";
        store.atomic(corruptPath, new byte[8]); publish(expired); publish(future);
        Store flaky = new ForwardingStore(store) { @Override public void delete(String p) throws Exception { throw new IOException(); } };
        SyncEngine e = engine(); SyncEngine.PollResult result = e.pollDetailed(flaky, now, () -> true);
        assertEquals(1, result.readFailures); assertEquals(1, result.cleanupFailures); assertEquals(1, result.futureRecords); assertTrue(result.partial());
        assertFalse(e.snapshot().getJSONObject("seen").has(corrupt.getString("id")));
        publish(corrupt); assertEquals(2, e.pollDetailed(store, now + 400000, () -> true).received);
        assertFalse(store.exists(Wire.spaceRoot(pair) + "records/" + expired.getString("id") + ".clip"));
    }
    @Test public void pauseModesPersistAndDoNotEraseHistoryOrOutbox() throws Exception {
        AtomicReference<JSONObject> saved = new AtomicReference<>();
        SyncEngine e = new SyncEngine(null, next -> saved.set(Wire.cloneJson(next))); e.activate(new JSONObject(), pair);
        e.enqueue("keep", "Android", now); e.setSyncPaused(true); e.enqueue("local only", "Android", now + 1);
        e.setPrivacyPaused(true); assertThrows(Wire.UserError.class, () -> e.enqueue("must not save", "Android", now + 2));
        Store never = new ForwardingStore(store) { @Override public boolean exists(String p) { throw new AssertionError("Paused sync must not touch NAS"); } };
        assertTrue(e.pollDetailed(never, now, () -> true).paused);
        SyncEngine restarted = new SyncEngine(saved.get(), next -> saved.set(Wire.cloneJson(next)));
        assertTrue(restarted.privacyPaused()); assertTrue(restarted.syncPaused()); assertEquals(2, restarted.snapshot().getJSONArray("pending").length());
        assertEquals(2, restarted.snapshot().getJSONArray("history").length());
        restarted.setPrivacyPaused(false); assertTrue(restarted.pollDetailed(never, now, () -> true).paused);
        restarted.setSyncPaused(false); assertEquals(2, restarted.pollDetailed(store, now + 1, () -> true).uploaded);
    }
    @Test public void privacyPauseDropsLateReadEvenAfterResume() throws Exception {
        JSONObject remote = record("must not apply late"); publish(remote); SyncEngine e = engine();
        CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1); AtomicInteger operationsAfterRead = new AtomicInteger();
        Store slow = new ForwardingStore(store) {
            @Override public byte[] read(String p, int n) throws Exception {
                byte[] data = super.read(p, n);
                if (p.endsWith(".clip")) { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)); }
                return data;
            }
            @Override public void delete(String p) throws Exception { operationsAfterRead.incrementAndGet(); super.delete(p); }
        };
        ExecutorService worker = Executors.newSingleThreadExecutor();
        try {
            Future<SyncEngine.PollResult> polling = worker.submit(() -> e.pollDetailed(slow, now, () -> true));
            assertTrue(entered.await(5, TimeUnit.SECONDS)); e.setPrivacyPaused(true); e.setPrivacyPaused(false); release.countDown();
            assertTrue(polling.get(5, TimeUnit.SECONDS).paused); assertEquals(0, e.snapshot().getJSONArray("history").length()); assertEquals(0, operationsAfterRead.get());
            assertEquals(1, e.pollDetailed(store, now, () -> true).received);
        } finally { release.countDown(); worker.shutdownNow(); }
    }
    @Test public void pauseDuringUploadLeavesUnacknowledgedRecordForIdempotentRetry() throws Exception {
        SyncEngine e = engine(); e.enqueue("in flight", "Android", now); e.enqueue("must not start", "Android", now + 1);
        AtomicInteger uploads = new AtomicInteger();
        Store pausing = new ForwardingStore(store) {
            @Override public void atomic(String p, byte[] b) throws Exception { super.atomic(p, b); uploads.incrementAndGet(); e.setPrivacyPaused(true); }
        };
        assertTrue(e.pollDetailed(pausing, now + 1, () -> true).paused); assertEquals(1, uploads.get());
        assertEquals(2, e.snapshot().getJSONArray("pending").length());
        e.setPrivacyPaused(false); assertEquals(2, e.pollDetailed(store, now + 1, () -> true).uploaded);
        assertEquals(2, store.list(Wire.spaceRoot(pair) + "records/").size()); assertEquals(2, e.snapshot().getJSONArray("history").length());
    }
    @Test public void failedLocalAcknowledgmentRetainsQueueForRestart() throws Exception {
        SyncEngine initial = engine(); initial.enqueue("already uploaded but local disk full", "Android", now);
        SyncEngine broken = new SyncEngine(initial.snapshot(), next -> { throw new IOException("disk full"); });
        assertThrows(IOException.class, () -> broken.pollDetailed(store, now, () -> true));
        assertEquals(1, broken.snapshot().getJSONArray("pending").length());
        SyncEngine restarted = new SyncEngine(broken.snapshot(), next -> {}); assertEquals(1, restarted.pollDetailed(store, now, () -> true).uploaded);
        assertEquals(1, store.list(Wire.spaceRoot(pair) + "records/").size());
    }
    @Test public void failedPauseSaveFailsClosedAndFailedResumeStaysPaused() throws Exception {
        SyncEngine initial = engine();
        SyncEngine broken = new SyncEngine(initial.snapshot(), next -> { throw new IOException(); });
        assertThrows(IOException.class, () -> broken.setPrivacyPaused(true)); assertTrue(broken.privacyPaused());
        assertThrows(IOException.class, () -> broken.setPrivacyPaused(false)); assertTrue(broken.privacyPaused());
        assertThrows(Wire.UserError.class, () -> broken.enqueue("blocked", "Android", now));
    }
    @Test public void diagnosticsRemoveOnlyTheirOwnProbe() throws Exception {
        store.create("ClipDaySync/keep.txt", Wire.utf8("keep")); ConnectionDiagnostics.check(store);
        assertEquals("keep", new String(store.read("ClipDaySync/keep.txt", 100), java.nio.charset.StandardCharsets.UTF_8));
        for (String path : store.list("ClipDaySync/")) assertFalse(path.startsWith(".connection-check-"));
    }
    @Test public void diagnosticsMissingSpaceReadWriteAndDeleteAreActionable() throws Exception {
        Store absent = new ForwardingStore(store) { @Override public boolean exists(String p) { return false; } };
        assertTrue(assertThrows(Wire.UserError.class, () -> ConnectionDiagnostics.check(absent)).getMessage().contains("电脑端创建"));
        Store unreadable = new ForwardingStore(store) { @Override public List<String> list(String p) throws Exception { throw new IOException(); } };
        assertTrue(assertThrows(Wire.UserError.class, () -> ConnectionDiagnostics.check(unreadable)).getMessage().contains("无法读取"));
        Store readonly = new ForwardingStore(store) { @Override public void atomic(String p, byte[] b) throws Exception { throw new IOException(); } };
        assertTrue(assertThrows(Wire.UserError.class, () -> ConnectionDiagnostics.check(readonly)).getMessage().contains("写入或重命名"));
        Store noDelete = new ForwardingStore(store) { @Override public void delete(String p) throws Exception { throw new IOException(); } };
        assertTrue(assertThrows(Wire.UserError.class, () -> ConnectionDiagnostics.check(noDelete)).getMessage().contains("无法删除"));
    }
    @Test public void guardedStoreSuppressesLateDiagnosticReadAndCleanupAfterPause() throws Exception {
        AtomicBoolean allowed = new AtomicBoolean(true); AtomicInteger deletes = new AtomicInteger();
        Store stopping = new ForwardingStore(store) {
            @Override public byte[] read(String p, int n) throws Exception { byte[] data = super.read(p, n); allowed.set(false); return data; }
            @Override public void delete(String p) throws Exception { deletes.incrementAndGet(); super.delete(p); }
        };
        try (GuardedStore guarded = new GuardedStore(stopping, allowed::get)) { assertThrows(GuardedStore.Stopped.class, () -> ConnectionDiagnostics.check(guarded)); }
        assertEquals(0, deletes.get());
    }
    @Test public void cancelledCaptureAndConnectionCannotCommitLateState() throws Exception {
        SyncEngine e = engine(); String before = e.snapshot().toString();
        assertThrows(Wire.UserError.class, () -> e.enqueue("blocked", "Android", now, () -> false));
        assertThrows(GuardedStore.Stopped.class, () -> e.configure(new JSONObject().put("host", "other"), () -> false));
        assertThrows(GuardedStore.Stopped.class, () -> e.activate(new JSONObject(), Wire.cloneJson(pair).put("space", Wire.id()), () -> false));
        assertEquals(before, e.snapshot().toString());
    }

}
