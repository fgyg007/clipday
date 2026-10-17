package io.jlmac.clipday.core;

import org.junit.*;
import static org.junit.Assert.*;
import org.json.*;
import java.nio.file.*;
import java.util.*;

public class CoreTest {
    Path root; LocalStore store; JSONObject pair;
    long now = System.currentTimeMillis();
    public static JSONObject fixturePair() throws Exception {
        byte[] key = new byte[32]; for (int i = 0; i < 32; i++) key[i] = (byte)i;
        return new JSONObject().put("v", 1).put("space", "c1416f42-de6e-43e0-97f0-122e9016a926").put("key", Wire.base(key));
    }
    @Before public void setup() throws Exception {
        root = Files.createTempDirectory("clipday-android-test-"); store = new LocalStore(root); pair = fixturePair();
        Files.createDirectories(root.resolve(Wire.spaceRoot(pair) + "records"));
        store.atomic(Wire.spaceRoot(pair) + "space.json", Wire.json(new JSONObject().put("v", 1).put("space", pair.getString("space"))));
        JSONObject proof = record("clipday-space-v1").put("id", pair.getString("space"));
        store.atomic(Wire.spaceRoot(pair) + "space.check", Wire.sealRecord(proof, pair));
    }
    @After public void cleanup() throws Exception { try (var walk = Files.walk(root)) { for (Path p : walk.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(p); } }
    JSONObject record(String text) throws Exception { return new JSONObject().put("v", 1).put("space", pair.getString("space")).put("id", Wire.id()).put("device", Wire.id()).put("name", "测试电脑").put("seq", 1).put("created", now).put("expires", now + Wire.LIFETIME).put("observed", new JSONObject()).put("text", text); }
    SyncEngine engine() throws Exception { SyncEngine e = new SyncEngine(null, s -> {}); e.activate(new JSONObject(), pair); return e; }
    void publish(JSONObject r) throws Exception { store.atomic(Wire.spaceRoot(pair) + "records/" + r.getString("id") + ".clip", Wire.sealRecord(r, pair)); }
    @Test public void unicodeAndAuthentication() throws Exception {
        JSONObject r = record("你好 安卓 👋\r\nsecond line"); byte[] data = Wire.sealRecord(r, pair);
        assertEquals(r.getString("text"), Wire.openRecord(data, pair).getString("text"));
        data[20] ^= 1; assertThrows(Exception.class, () -> Wire.openRecord(data, pair));
        assertThrows(Exception.class, () -> Wire.openRecord(new byte[15], pair));
        JSONObject wrong = Wire.cloneJson(pair).put("space", Wire.id());
        assertThrows(Exception.class, () -> Wire.openRecord(Wire.sealRecord(r, pair), wrong));
    }
    @Test public void outboxSurvivesRestartAndDedupes() throws Exception {
        JSONObject[] saved = {null}; SyncEngine a = new SyncEngine(null, s -> saved[0] = Wire.cloneJson(s)); a.activate(new JSONObject(), pair);
        String id = a.enqueue("离线发送", "安卓", now); assertEquals(1, saved[0].getJSONArray("pending").length());
        a = new SyncEngine(saved[0], s -> saved[0] = Wire.cloneJson(s)); a.poll(store, now);
        assertEquals(0, a.snapshot().getJSONArray("pending").length());
        SyncEngine b = engine(); assertEquals(1, b.poll(store, now)); assertEquals(0, b.poll(store, now));
        assertEquals(id, b.snapshot().getJSONArray("history").getJSONObject(0).getString("id"));
        assertEquals(1, a.snapshot().getJSONArray("history").length());
    }
    @Test public void expiredAndFutureRecordsAreNotImported() throws Exception {
        JSONObject expired = record("过期").put("created", now - Wire.LIFETIME).put("expires", now); publish(expired);
        JSONObject future = record("未来").put("created", now + 400000).put("expires", now + 400000 + Wire.LIFETIME); publish(future);
        SyncEngine e = engine(); assertEquals(0, e.poll(store, now)); assertEquals(0, e.snapshot().getJSONArray("history").length());
        assertFalse(store.exists(Wire.spaceRoot(pair) + "records/" + expired.getString("id") + ".clip"));
        assertEquals(1, e.poll(store, now + 400000));
    }
    @Test public void partialFilesRetryAndClockIsPreserved() throws Exception {
        JSONObject r = record("重试"); String path = Wire.spaceRoot(pair) + "records/" + r.getString("id") + ".clip";
        store.atomic(path, new byte[8]); SyncEngine e = engine(); assertEquals(0, e.poll(store, now)); publish(r);
        assertEquals(1, e.poll(store, now)); e.enqueue("回复", "安卓", now + 1);
        assertEquals(1, e.snapshot().getJSONArray("pending").getJSONObject(0).getJSONObject("observed").getLong(r.getString("device")));
    }
    @Test public void saveFailureDoesNotConsumeTextOrAdvanceSequence() throws Exception {
        SyncEngine good = engine(); SyncEngine broken = new SyncEngine(good.snapshot(), s -> { throw new java.io.IOException(); });
        assertThrows(Exception.class, () -> broken.enqueue("保存失败", "安卓", now)); assertEquals(0, broken.snapshot().getLong("seq"));
        assertEquals(0, broken.snapshot().getJSONArray("pending").length());
    }
    @Test public void missingSpaceDoesNotRecreateNasOrLoseOutbox() throws Exception {
        SyncEngine e = engine(); e.enqueue("待重连", "安卓", now); store.delete(Wire.spaceRoot(pair) + "space.json");
        assertThrows(Exception.class, () -> e.poll(store, now)); assertEquals(1, e.snapshot().getJSONArray("pending").length());
        assertFalse(store.exists(Wire.spaceRoot(pair) + "space.json"));
    }
    @Test public void limitsAndPathTraversalRejected() throws Exception {
        SyncEngine e = engine(); assertThrows(Exception.class, () -> e.enqueue("x".repeat(Wire.MAX_TEXT + 1), "安卓", now));
        assertThrows(Exception.class, () -> e.enqueue("\u0000".repeat(400000), "安卓", now));
        assertThrows(Exception.class, () -> NasConfig.safePath("../other"));
        assertThrows(Exception.class, () -> NasConfig.safePath("a/../b"));
        assertThrows(Exception.class, () -> Pairing.join(store, "12345x"));
        JSONObject invalid = record("非法序号").put("seq", 1.5);
        assertThrows(Exception.class, () -> Wire.openRecord(Wire.sealRecord(invalid, pair), pair));
    }
    @Test public void cannotDropPendingBySwitchingSpaces() throws Exception {
        SyncEngine e = engine(); e.enqueue("未发送", "安卓", now);
        JSONObject other = Wire.cloneJson(pair).put("space", Wire.id());
        assertThrows(Exception.class, () -> e.activate(new JSONObject(), other)); assertEquals(pair.toString(), e.snapshot().getJSONObject("pair").toString());
    }
}
