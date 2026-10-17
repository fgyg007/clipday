package io.jlmac.clipday.core;

/** Platform-independent privacy baseline and cross-format clipboard activity gate. */
public final class ImageClipboardGate {
    private boolean baselinePending;
    private String ignoredFingerprint = "";
    private long epoch, localActivity;
    public synchronized long epoch() { return epoch; }
    public synchronized void activity(long now) { epoch++; localActivity = Math.max(localActivity, now); }
    public synchronized void focusChanged() { epoch++; }
    public synchronized void pause() { baselinePending = true; epoch++; }
    public synchronized boolean needsBaseline() { return baselinePending; }
    /** Call on the focused UI turn which resumes privacy, or first permitted focus afterward. */
    public synchronized void baseline(String fingerprint) { ignoredFingerprint = fingerprint; baselinePending = false; }
    public synchronized boolean captureAllowed(String fingerprint) { return !baselinePending && !fingerprint.equals(ignoredFingerprint); }
    public synchronized boolean automaticAllowed(long token, long created, long expires, long now) {
        return !baselinePending && token == epoch && created > localActivity && created <= now && now-created <= 10000 && expires > now;
    }
}
