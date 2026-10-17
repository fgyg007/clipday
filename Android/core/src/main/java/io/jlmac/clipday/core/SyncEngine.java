package io.jlmac.clipday.core;

import org.json.*;
import java.util.*;
import java.util.function.BooleanSupplier;

/** Local transactions are short and synchronized; NAS I/O never holds the state lock. */
public final class SyncEngine {
    public interface Saver { void save(JSONObject next) throws Exception; }
    private JSONObject state;
    private final Saver saver;
    private final Object pollLock = new Object();
    private volatile boolean privacyPaused, syncPaused;
    private volatile long generation;
    public static final class PollResult {
        public int received, uploaded, readFailures, writeFailures, cleanupFailures, futureRecords;
        public boolean listingFailed, paused;
        public boolean partial() { return readFailures + writeFailures + cleanupFailures + futureRecords > 0 || listingFailed; }
    }
    public SyncEngine(JSONObject initial, Saver saver) throws Exception {
        this.saver = saver;
        state = initial == null ? new JSONObject().put("device", Wire.id()).put("seq", 0)
            .put("clock", new JSONObject()).put("seen", new JSONObject()).put("history", new JSONArray()).put("pending", new JSONArray()) : initial;
        Wire.require(Wire.isId(state.getString("device")) && state.getLong("seq") >= 0);
        privacyPaused = state.optBoolean("privacyPaused"); syncPaused = state.optBoolean("syncPaused");
    }
    public synchronized JSONObject snapshot() throws Exception { return Wire.cloneJson(state); }
    private void commit(JSONObject next) throws Exception { saver.save(next); state = next; }
    public synchronized boolean paired() { return state.has("pair"); }
    public void activate(JSONObject config, JSONObject pair) throws Exception { activate(config, pair, () -> true); }
    public synchronized void activate(JSONObject config, JSONObject pair, BooleanSupplier allowed) throws Exception {
        if (!allowed.getAsBoolean()) throw new GuardedStore.Stopped();
        Wire.pair(pair); JSONObject next = Wire.cloneJson(state);
        if (paired() && !state.getJSONObject("pair").getString("space").equals(pair.getString("space"))) {
            if (state.getJSONArray("pending").length() > 0) throw new Wire.UserError("还有未发送的文字，请先连接原同步空间发送，再切换空间。");
            next.put("clock", new JSONObject()).put("seen", new JSONObject()).put("history", new JSONArray());
        }
        next.put("config", config).put("pair", pair);
        if (!allowed.getAsBoolean()) throw new GuardedStore.Stopped();
        commit(next); generation++;
    }
    public void configure(JSONObject config) throws Exception { configure(config, () -> true); }
    public synchronized void configure(JSONObject config, BooleanSupplier allowed) throws Exception {
        JSONObject next = Wire.cloneJson(state); next.put("config", config);
        if (!allowed.getAsBoolean()) throw new GuardedStore.Stopped();
        commit(next); generation++;
    }
    public boolean privacyPaused() { return privacyPaused; }
    public boolean syncPaused() { return syncPaused; }
    public synchronized void setPrivacyPaused(boolean value) throws Exception {
        // Fail closed while saving a pause. A failed resume never re-enables network access.
        if (value) { privacyPaused = true; generation++; }
        JSONObject next = Wire.cloneJson(state); next.put("privacyPaused", value); commit(next);
        privacyPaused = value; generation++;
    }
    public synchronized void setSyncPaused(boolean value) throws Exception {
        if (value) { syncPaused = true; generation++; }
        JSONObject next = Wire.cloneJson(state); next.put("syncPaused", value); commit(next);
        syncPaused = value; generation++;
    }
    private boolean allowed(long token) { return !privacyPaused && !syncPaused && generation == token; }
    public String enqueue(String text, String name, long now) throws Exception { return enqueue(text, name, now, () -> true); }
    public synchronized String enqueue(String text, String name, long now, BooleanSupplier captureAllowed) throws Exception {
        if (privacyPaused || !captureAllowed.getAsBoolean()) throw new Wire.UserError("隐私已暂停，恢复后才能保存或发送新文字。");
        if (!paired()) throw new Wire.UserError("请先连接 NAS 并输入电脑上的配对码。");
        if (text.isEmpty() || Wire.utf8(text).length > Wire.MAX_TEXT) throw new Wire.UserError("请输入文字，每条最多 1 MB。");
        JSONObject next = Wire.cloneJson(state); prune(next, now);
        JSONArray pending = next.getJSONArray("pending");
        long bytes = 0; for (int i = 0; i < pending.length(); i++) bytes += Wire.json(pending.getJSONObject(i)).length;
        long seq = next.getLong("seq") + 1; Wire.require(seq > 0 && now > 0 && now <= Long.MAX_VALUE - Wire.LIFETIME);
        String id = Wire.id();
        JSONObject record = new JSONObject().put("v", 1).put("id", id).put("space", next.getJSONObject("pair").getString("space"))
            .put("device", next.getString("device")).put("name", name).put("seq", seq).put("created", now).put("expires", now + Wire.LIFETIME)
            .put("observed", Wire.cloneJson(next.getJSONObject("clock"))).put("text", text);
        Wire.require(Wire.utf8(name).length <= 256);
        int encodedSize = Wire.json(record).length;
        if (encodedSize + 28 > Wire.MAX_FILE) throw new Wire.UserError("这段文字编码后过大，请分成较短的几段发送。");
        if (pending.length() >= 200 || bytes + encodedSize > 16 * 1024 * 1024) throw new Wire.UserError("待发送队列已满，请连接 NAS 后重试。");
        next.put("seq", seq); pending.put(record); next.getJSONArray("history").put(record);
        trimHistory(next);
        if (privacyPaused || !captureAllowed.getAsBoolean()) throw new Wire.UserError("隐私已暂停，未保存或发送新文字。");
        commit(next); return id;
    }
    public synchronized void prune(long now) throws Exception {
        JSONObject next = Wire.cloneJson(state); prune(next, now);
        if (!next.toString().equals(state.toString())) commit(next);
    }
    private static void prune(JSONObject next, long now) throws Exception {
        for (String key : new String[]{"history", "pending"}) {
            JSONArray filtered = new JSONArray(), old = next.getJSONArray(key);
            for (int i = 0; i < old.length(); i++) if (old.getJSONObject(i).getLong("expires") > now) filtered.put(old.getJSONObject(i));
            next.put(key, filtered);
        }
        JSONObject seen = next.getJSONObject("seen"); List<String> expired = new ArrayList<>();
        for (Iterator<String> i = seen.keys(); i.hasNext();) { String id = i.next(); if (seen.getLong(id) <= now) expired.add(id); }
        for (String id : expired) seen.remove(id);
    }
    private static void trimHistory(JSONObject next) throws Exception {
        JSONArray old = next.getJSONArray("history"); List<JSONObject> items = new ArrayList<>();
        for (int i = 0; i < old.length(); i++) items.add(old.getJSONObject(i));
        items.sort((a, b) -> Long.compare(b.optLong("created"), a.optLong("created")));
        JSONArray kept = new JSONArray(); long bytes = 0;
        for (JSONObject r : items) {
            int size = Wire.json(r).length;
            if (kept.length() >= 1000 || bytes + size > 16 * 1024 * 1024) break;
            kept.put(r); bytes += size;
        }
        next.put("history", kept);
    }
    /** Compatibility entry point for existing clients; detailed status is available to the UI. */
    public int poll(Store store, long now) throws Exception { return pollDetailed(store, now, () -> true).received; }
    public PollResult pollDetailed(Store store, long now, BooleanSupplier networkAllowed) throws Exception {
        synchronized (pollLock) {
            PollResult result = new PollResult();
            final JSONObject pair, initial;
            final long token;
            synchronized (this) {
                if (!paired()) return result;
                if (privacyPaused || syncPaused || !networkAllowed.getAsBoolean()) { result.paused = true; return result; }
                prune(now); initial = Wire.cloneJson(state); pair = initial.getJSONObject("pair"); token = generation;
            }
            GuardedStore guarded = new GuardedStore(store, () -> allowed(token) && networkAllowed.getAsBoolean());
            try {
                Wire.verify(guarded, pair);
                String root = Wire.spaceRoot(pair) + "records/";
                JSONArray pending = initial.getJSONArray("pending");
                for (int i = 0; i < pending.length(); i++) {
                    JSONObject r = pending.getJSONObject(i); String id = r.getString("id");
                    try { guarded.atomic(root + id + ".clip", Wire.sealRecord(r, pair)); }
                    catch (GuardedStore.Stopped e) { throw e; }
                    catch (Exception e) { result.writeFailures++; break; }
                    synchronized (this) {
                        guarded.check();
                        JSONObject next = Wire.cloneJson(state); JSONArray remaining = new JSONArray(), current = next.getJSONArray("pending");
                        for (int j = 0; j < current.length(); j++) if (!id.equals(current.getJSONObject(j).getString("id"))) remaining.put(current.getJSONObject(j));
                        next.put("pending", remaining); next.getJSONObject("seen").put(id, r.getLong("expires"));
                        guarded.check(); commit(next); result.uploaded++;
                    }
                }
                List<String> files;
                try { files = guarded.list(root); }
                catch (GuardedStore.Stopped e) { throw e; }
                catch (Exception e) { result.listingFailed = true; return result; }
                if (files.size() > 20000) throw new Wire.UserError("同步空间文件过多，请先在电脑端整理。");
                for (String file : files) {
                    guarded.check();
                    if (!file.endsWith(".clip")) continue;
                    String id = file.substring(0, file.length() - 5); if (!Wire.isId(id)) continue;
                    synchronized (this) { if (state.getJSONObject("seen").has(id)) continue; }
                    JSONObject r;
                    // Authentication/partial-file errors remain unseen and are explicitly reported for retry.
                    try { r = Wire.openRecord(guarded.read(root + file, Wire.MAX_FILE), pair); Wire.require(r.getString("id").equals(id)); }
                    catch (GuardedStore.Stopped e) { throw e; }
                    catch (Exception e) { result.readFailures++; continue; }
                    if (r.getLong("expires") <= now) {
                        try { guarded.delete(root + file); }
                        catch (GuardedStore.Stopped e) { throw e; }
                        catch (Exception e) { result.cleanupFailures++; }
                        continue;
                    }
                    if (r.getLong("created") > now + 300000) { result.futureRecords++; continue; }
                    synchronized (this) {
                        guarded.check();
                        JSONObject next = Wire.cloneJson(state), seen = next.getJSONObject("seen"), clock = next.getJSONObject("clock");
                        if (seen.has(id)) continue;
                        String device = r.getString("device");
                        // A concurrently queued own record already exists in local history.
                        boolean received = !device.equals(next.getString("device"));
                        if (received) next.getJSONArray("history").put(r);
                        seen.put(id, r.getLong("expires"));
                        if (clock.has(device) || clock.length() < 100) clock.put(device, Math.max(clock.optLong(device), r.getLong("seq")));
                        trimHistory(next); guarded.check(); commit(next); if (received) result.received++;
                    }
                }
            } catch (GuardedStore.Stopped e) { result.paused = true; }
            return result;
        }
    }
}
