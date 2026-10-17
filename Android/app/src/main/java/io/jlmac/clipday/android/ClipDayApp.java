package io.jlmac.clipday.android;

import android.app.Application;
import android.content.*;
import android.net.Uri;
import java.util.Arrays;
import android.os.*;
import org.json.JSONObject;
import java.util.concurrent.*;
import java.util.function.BooleanSupplier;
import io.jlmac.clipday.core.*;

public final class ClipDayApp extends Application {
    final Handler ui = new Handler(Looper.getMainLooper());
    // Durable local capture must never wait behind an SMB timeout or pairing exchange.
    private final ExecutorService localWorker = Executors.newSingleThreadExecutor();
    private final ExecutorService networkWorker = Executors.newSingleThreadExecutor();
    private SyncEngine engine;
    private ImageEngine images;
    private volatile String imageSnapshot = "{}";
    volatile boolean focused, savingImage;
    private final ImageClipboardGate clipboardGate = new ImageClipboardGate();
    private String capturedClipboard = "", capturingClipboard = "", failedClipboard = "";
    private boolean settingClipboard;
    private String captureIntentFingerprint = "", captureIntentId = "";
    private long captureIntentCreated, captureRetryAfter;
    private final Runnable retryCapture = () -> captureClipboard(false);
    private SmbStore store; // Owned only by networkWorker.
    private volatile String snapshot = "{}";
    volatile String message = "正在打开轻贴…";
    private volatile String saveError = "", pauseError = "";
    volatile boolean ready, busy, saving, online, privacyPaused, syncPaused, pauseSaving;
    private volatile long networkEpoch;
    private boolean refreshRequested;
    volatile int connectionRevision;
    volatile String draft = "";
    String setupPassword = ""; // Rotation-only memory; never written into Android saved-state bundles.
    private Runnable listener;
    private boolean visible;
    private final Runnable tick = () -> { if (visible && ready && !busy && paired() && networkEnabled()) refresh(); else schedule(); };
    @Override public void onCreate() {
        super.onCreate();
        localWorker.execute(() -> {
            try {
                Vault vault = new Vault(this); engine = new SyncEngine(vault.load(), vault::save); engine.prune(System.currentTimeMillis());
                Vault imageVault = new Vault(this, "images-state.enc");
                images = new ImageEngine(imageVault.load(), imageVault::save, new ImageFiles(new java.io.File(getNoBackupFilesDir(), "images-v1").toPath(), directory -> {
                    java.io.FileDescriptor descriptor = android.system.Os.open(directory.toString(), android.system.OsConstants.O_RDONLY, 0);
                    try { Wire.require(android.system.OsConstants.S_ISDIR(android.system.Os.fstat(descriptor).st_mode)); android.system.Os.fsync(descriptor); } finally { android.system.Os.close(descriptor); }
                }), ImageCodec::validate);
                if (engine.paired()) images.configure(engine.snapshot().getJSONObject("pair"), engine.snapshot().getString("device"));
                images.prune(System.currentTimeMillis());
                updateSnapshot(); privacyPaused = engine.privacyPaused(); if (privacyPaused) clipboardGate.pause(); syncPaused = engine.syncPaused(); ready = true;
                message = engine.paired() ? "已配对，正在连接 NAS…" : "先在电脑创建同步空间，再让手机加入同一 NAS 文件夹";
            } catch (Exception e) { message = "无法读取本机加密数据，请重启手机后重试。"; }
            ui.post(() -> { notifyUi(); if (visible && paired() && networkEnabled()) refresh(); });
        });
    }
    JSONObject state() { try { return new JSONObject(snapshot); } catch (Exception e) { return new JSONObject(); } }
    JSONObject imageState() { try { return new JSONObject(imageSnapshot); } catch (Exception e) { return new JSONObject(); } }
    JSONObject imageRecord(String id) throws Exception { return images.record(id, System.currentTimeMillis()); }
    byte[] imageBytes(String id) throws Exception { return images.image(id, System.currentTimeMillis()); }
    boolean paired() { return state().has("pair"); }
    private boolean networkEnabled() { return !privacyPaused && !syncPaused; }
    String statusText() {
        String error = (saveError.isEmpty() ? "" : saveError + "\n") + (pauseError.isEmpty() ? "" : pauseError + "\n");
        if (privacyPaused) return error + "隐私已暂停 · 不保存新文字或图片，不发送、不接收。历史与待发送队列保留。已发出的请求无法撤回。" + (pauseSaving ? " 正在保存暂停设置…" : "");
        if (syncPaused) return error + "同步已暂停 · 新文字和图片仍可保存到本机，恢复后再上传；不发送、不接收。" + (pauseSaving ? " 正在保存暂停设置…" : "");
        return error + message;
    }
    void attach(Runnable callback) { listener = callback; visible = true; notifyUi(); if (ready && !busy && paired() && networkEnabled()) refresh(); else schedule(); }
    void detach(Runnable callback) { setFocused(false); if (listener == callback) { listener = null; visible = false; ui.removeCallbacks(tick); } }
    private void notifyUi() { if (listener != null) listener.run(); }
    private synchronized void updateSnapshot() throws Exception { snapshot = engine.snapshot().toString(); if (images != null) imageSnapshot = images.snapshot().toString(); }
    private void schedule() { ui.removeCallbacks(tick); if (visible && ready && paired() && networkEnabled()) ui.postDelayed(tick, online ? 3000 : 10000); }
    private interface NetworkJob { void run(BooleanSupplier allowed) throws Exception; }
    private void runNetwork(String status, NetworkJob job) {
        if (!ready || busy || !networkEnabled()) return;
        busy = true; refreshRequested = false; message = status; notifyUi(); ui.removeCallbacks(tick);
        long token = networkEpoch;
        BooleanSupplier allowed = () -> networkEnabled() && token == networkEpoch;
        networkWorker.execute(() -> {
            try { if (!allowed.getAsBoolean()) throw new GuardedStore.Stopped(); job.run(allowed); }
            catch (GuardedStore.Stopped e) { online = false; disconnect(); }
            catch (Exception e) { online = false; disconnect(); message = friendly(e); }
            finally {
                try { updateSnapshot(); } catch (Exception ignored) { }
                if (!allowed.getAsBoolean()) { online = false; disconnect(); }
                ui.post(() -> { busy = false; notifyUi(); if (refreshRequested && networkEnabled()) refresh(); else schedule(); });
            }
        });
    }
    private String friendly(Exception e) {
        if (e instanceof Wire.UserError) return e.getMessage();
        if (e instanceof com.hierynomus.mssmb2.SMBApiException) {
            long code = ((com.hierynomus.mssmb2.SMBApiException)e).getStatusCode();
            if (code == 0xc000006dL || code == 0xc0000022L) return "NAS 登录或权限不足，请检查账号密码和文件夹读写权限。已保存的待发送文字仍在本机。";
            if (code == 0xc0000035L) return "这组配对码正在处理另一次请求，请在电脑上重新生成。";
        }
        return paired() ? "NAS 暂不可用，配对仍保留。已保存的文字留在本机，重连后重试；尚不能确认接收端收到。" : "无法连接 NAS。请检查 Wi‑Fi、NAS 地址、共享名称和账号密码。";
    }
    private void disconnect() { if (store != null) store.close(); store = null; }
    private SmbStore connection(BooleanSupplier allowed) throws Exception {
        if (store == null) store = new SmbStore(new NasConfig(engine.snapshot().getJSONObject("config")), allowed);
        store.setNetworkAllowed(allowed); return store;
    }
    void testConnection(JSONObject config) {
        runNetwork("正在测试 NAS 连通、读取、写入及删除权限…", allowed -> {
            try (SmbStore candidate = new SmbStore(new NasConfig(config), allowed)) {
                ConnectionDiagnostics.check(new GuardedStore(candidate, allowed));
                message = "NAS 已连通 · 同步目录可读写、可删除。下一步：在电脑显示配对码，让手机加入原空间。";
            }
        });
    }
    void connect(JSONObject config, String code) {
        runNetwork(code.isEmpty() ? "正在验证 NAS 连接与读写权限…" : "正在验证 NAS 并与电脑配对…", allowed -> {
            NasConfig parsed = new NasConfig(config); disconnect();
            SmbStore candidate = new SmbStore(parsed, allowed);
            try {
                GuardedStore guarded = new GuardedStore(candidate, allowed); ConnectionDiagnostics.check(guarded);
                boolean existing = code.isEmpty() && engine.paired();
                JSONObject pair = existing ? engine.snapshot().getJSONObject("pair") : Pairing.join(guarded, code);
                if (existing) Wire.verify(guarded, pair);
                guarded.check();
                synchronized (images) {
                    JSONObject oldPair = engine.snapshot().optJSONObject("pair");
                    if (oldPair != null && !oldPair.getString("space").equals(pair.getString("space")) && images.hasPending()) throw new Wire.UserError("还有待上传图片，请先连接原空间完成上传。");
                    if (existing) engine.configure(config, allowed); else engine.activate(config, pair, allowed);
                    images.configure(pair, engine.snapshot().getString("device")); connectionRevision++;
                }
                guarded.check(); store = candidate; candidate = null; online = true;
            } finally { if (candidate != null) candidate.close(); }
            // A later network failure must not turn a completed pairing into a pairing error.
            try { pollBoth(store, allowed); }
            catch (GuardedStore.Stopped e) { throw e; }
            catch (Exception e) { online = false; disconnect(); message = "配对已保存。后续同步未完成：" + friendly(e); }
        });
    }
    private void report(SyncEngine.PollResult result) throws Exception {
        if (result.paused) { online = false; return; }
        online = !result.listingFailed && result.writeFailures == 0;
        int pending = engine.snapshot().getJSONArray("pending").length();
        if (result.partial()) {
            message = "同步未全部完成：" + (result.writeFailures > 0 ? "上传失败，" : "")
                + (result.listingFailed ? "目录读取失败，" : "")
                + (result.readFailures > 0 ? result.readFailures + " 条记录读取或校验失败，" : "")
                + (result.futureRecords > 0 ? result.futureRecords + " 条记录时间异常，" : "")
                + (result.cleanupFailures > 0 ? result.cleanupFailures + " 条过期记录清理失败，" : "")
                + "稍后自动重试。本机待上传 " + pending + " 条；接收端是否收到未知。";
        } else {
            message = "NAS 本轮同步完成 · 本机待上传 " + pending + " 条。已上传不等于对方已收到，当前没有接收回执。";
        }
    }
    void refresh() {
        if (busy) { refreshRequested = true; return; }
        runNetwork("正在同步 · 可继续保存文字和图片到本机…", allowed -> pollBoth(connection(allowed), allowed));
    }
    private void pollBoth(Store remote, BooleanSupplier allowed) throws Exception {
        final long clipboardToken = clipboardGate.epoch();
        report(engine.pollDetailed(remote, System.currentTimeMillis(), allowed));
        ImageEngine.Result result = images.poll(remote, System.currentTimeMillis(), allowed);
        if (result.paused) return;
        message += " 图片：本轮上传 " + result.uploaded + " 张，接收 " + result.received + " 张。";
        if (result.deferred) message += " 剩余图片下轮继续，本轮不自动覆盖剪贴板。";
        if (result.failures + result.futureRecords + result.cleanupFailures > 0) message += " 图片未全部完成，校验、时间或清理失败的内容保留待重试。";
        if (result.automatic != null) ui.post(() -> {
            JSONObject r = result.automatic;
            if (!allowed.getAsBoolean() || !focused || clipboardToken != clipboardGate.epoch() || !networkEnabled()) return;
            long now = System.currentTimeMillis(), created = r.optLong("created");
            if (!clipboardGate.automaticAllowed(clipboardToken, created, r.optLong("expires"), now)) return;
            try {
                if (r.getJSONObject("observed").optLong(state().getString("device")) < images.sequence()) return;
                copyImage(r.getString("id"), true);
            } catch (Exception ignored) { }
        });
    }
    void localActivity() { clipboardGate.activity(System.currentTimeMillis()); }
    void setFocused(boolean value) {
        if (focused == value) return; focused = value; clipboardGate.focusChanged();
        if (images != null) images.invalidate();
        if (value) captureClipboard(false); else ui.removeCallbacks(retryCapture);
    }
    void clipboardChanged() { localActivity(); if (!settingClipboard) captureClipboard(true); }
    void captureClipboard(boolean changed) {
        if (!ready || !paired() || privacyPaused || !focused) return;
        try {
            ClipboardManager manager = (ClipboardManager)getSystemService(CLIPBOARD_SERVICE);
            ClipData clip = manager.getPrimaryClip();
            if (clipboardGate.needsBaseline()) {
                // Never upload a clipboard image copied during the privacy pause. If focus was
                // absent at resume, establish this baseline at the first allowed foreground read.
                if (clip == null) { if (!manager.hasPrimaryClip()) clipboardGate.baseline(""); return; }
                Uri baseline = clip.getItemCount() == 1 ? clip.getItemAt(0).getUri() : null;
                capturedClipboard = baseline == null ? "" : clip.getDescription().getTimestamp() + ":" + baseline;
                clipboardGate.baseline(capturedClipboard); return;
            }
            if (savingImage || clip == null || clip.getItemCount() != 1) return;
            Uri uri = clip.getItemAt(0).getUri();
            if (uri == null || !"content".equals(uri.getScheme()) || ImageProvider.AUTHORITY.equals(uri.getAuthority())) return;
            if (!clip.getDescription().hasMimeType("image/*")) return; // Resolve/validate the provider MIME on the local worker, not the UI thread.
            String fingerprint = clip.getDescription().getTimestamp() + ":" + uri;
            if (!clipboardGate.captureAllowed(fingerprint) || fingerprint.equals(capturedClipboard) || fingerprint.equals(capturingClipboard) || fingerprint.equals(failedClipboard)) return;
            if (!fingerprint.equals(captureIntentFingerprint)) {
                captureIntentFingerprint = fingerprint; captureIntentId = Wire.id(); captureIntentCreated = System.currentTimeMillis(); captureRetryAfter = 0;
            }
            if (System.currentTimeMillis() >= captureIntentCreated + Wire.LIFETIME) { failedClipboard = fingerprint; return; }
            if (SystemClock.elapsedRealtime() < captureRetryAfter) {
                ui.removeCallbacks(retryCapture); ui.postDelayed(retryCapture, captureRetryAfter - SystemClock.elapsedRealtime()); return;
            }
            final String intentId = captureIntentId; final long created = captureIntentCreated;
            capturingClipboard = fingerprint; savingImage = true;
            final long token = clipboardGate.epoch(); final int revision = connectionRevision;
            BooleanSupplier allowed = () -> !privacyPaused && focused && token == clipboardGate.epoch() && revision == connectionRevision;
            localWorker.execute(() -> {
                byte[] png = null; boolean saved = false, invalid = false, retry = false;
                try {
                    png = ImageCodec.capture(getContentResolver(), uri, allowed);
                    images.enqueue(png, "安卓手机", intentId, created, System.currentTimeMillis(), allowed); updateSnapshot(); saved = true;
                } catch (GuardedStore.Stopped ignored) { }
                catch (Exception e) {
                    if (png == null) { invalid = true; saveError = "这张剪贴板图片无法读取或规范化，未上传；只支持有读取权限的 PNG/JPEG 静态图片。请重新复制后重试。"; }
                    else { retry = true; saveError = "图片尚未保存到本机，前台将稍后重试；未保存前请勿退出。原始24小时到期时间不变。"; }
                }
                finally { if (png != null) Arrays.fill(png, (byte)0); }
                final boolean completed = saved, captureInvalid = invalid, retrySave = retry;
                ui.post(() -> {
                    if (captureInvalid) failedClipboard = fingerprint;
                    if (retrySave && fingerprint.equals(captureIntentFingerprint)) { captureRetryAfter = SystemClock.elapsedRealtime() + 10000; if (focused && !privacyPaused) { ui.removeCallbacks(retryCapture); ui.postDelayed(retryCapture, 10000); } }
                    savingImage = false; capturingClipboard = "";
                    if (completed) { capturedClipboard = fingerprint; saveError = ""; message = "剪贴板图片已自动加密保存，等待上传。"; }
                    notifyUi(); if (completed && networkEnabled()) refresh(); else if (clipboardGate.epoch() != token) captureClipboard(false);
                });
            });
        } catch (Exception ignored) { /* Focus/URI grants can be withdrawn by Android. Do not bypass them. */ }
    }
    void thumbnail(String id, java.util.function.Consumer<android.graphics.Bitmap> done) {
        localWorker.execute(() -> {
            byte[] png = null; android.graphics.Bitmap bitmap = null;
            try {
                if (!privacyPaused) {
                    JSONObject r = images.record(id, System.currentTimeMillis()); png = images.image(id, System.currentTimeMillis());
                    android.graphics.BitmapFactory.Options options = new android.graphics.BitmapFactory.Options();
                    options.inSampleSize = 1;
                    while (Math.max(r.getInt("width"), r.getInt("height")) / options.inSampleSize > 384) options.inSampleSize *= 2;
                    bitmap = android.graphics.BitmapFactory.decodeByteArray(png, 0, png.length, options);
                }
            } catch (Exception | OutOfMemoryError ignored) { }
            finally { if (png != null) Arrays.fill(png, (byte)0); }
            final android.graphics.Bitmap value = bitmap;
            ui.post(() -> { if (!privacyPaused) done.accept(value); else if (value != null) value.recycle(); });
        });
    }
    void copyImage(String id, boolean automatic) throws Exception {
        if (!focused || privacyPaused || (automatic && !networkEnabled())) return;
        images.record(id, System.currentTimeMillis()); localActivity();
        ClipData clip = ClipData.newUri(getContentResolver(), "轻贴图片", ImageProvider.uri(id));
        if (Build.VERSION.SDK_INT >= 33) { PersistableBundle extras = new PersistableBundle(); extras.putBoolean("android.content.extra.IS_SENSITIVE", true); clip.getDescription().setExtras(extras); }
        settingClipboard = true;
        try { ((ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(clip); }
        finally { settingClipboard = false; }
    }
    void send(String text) {
        if (!ready || saving || privacyPaused) return;
        localActivity(); saving = true; saveError = ""; message = "正在加密保存到本机…"; notifyUi();
        localWorker.execute(() -> {
            boolean saved = false;
            try {
                if (privacyPaused) throw new Wire.UserError("隐私已暂停，未保存或发送新文字。");
                engine.enqueue(text, "安卓手机", System.currentTimeMillis(), () -> !privacyPaused); updateSnapshot(); saved = true;
                message = "已保存到本机 · 等待上传 NAS；尚未确认接收端收到。";
            } catch (Exception e) { saveError = e instanceof Wire.UserError ? e.getMessage() : "未能保存到本机，请检查剩余空间；输入内容已保留。"; }
            final boolean completed = saved;
            ui.post(() -> {
                saving = false;
                if (completed && draft.equals(text)) draft = "";
                notifyUi(); if (completed && networkEnabled()) refresh();
            });
        });
    }
    void setPrivacyPaused(boolean value) { setPause(true, value); }
    void setSyncPaused(boolean value) { setPause(false, value); }
    private void setPause(boolean privacy, boolean value) {
        if (!ready || pauseSaving) return;
        // Immediately gate active work. Resume only after the durable setting is saved.
        if (value) { if (privacy) { privacyPaused = true; clipboardGate.pause(); } else syncPaused = true; }
        networkEpoch++; ui.removeCallbacks(retryCapture); localActivity(); if (images != null) images.invalidate(); online = false; pauseSaving = true; pauseError = ""; ui.removeCallbacks(tick); notifyUi();
        localWorker.execute(() -> {
            boolean committed = false;
            try {
                if (privacy) engine.setPrivacyPaused(value); else engine.setSyncPaused(value);
                updateSnapshot(); committed = true; message = "暂停设置已保存。";
            } catch (Exception e) { pauseError = "无法保存暂停设置。当前仍暂停；请检查剩余空间后重试，重启后请再次确认暂停状态。"; }
            final boolean saved = committed;
            ui.post(() -> {
                if (saved) { if (privacy) privacyPaused = value; else syncPaused = value; }
                // Establish the ignored pause-period clipboard on this UI turn before a new
                // clipboard callback can arrive. Without focus the baseline stays pending.
                if (saved && privacy && !value && focused) captureClipboard(false);
                pauseSaving = false; notifyUi(); if (networkEnabled() && paired()) refresh();
            });
        });
    }
}
