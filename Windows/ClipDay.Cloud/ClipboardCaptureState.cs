namespace ClipDay.Cloud;

// UI-thread state shared by the listener and timer. Reading a sequence is not an acknowledgement.
sealed class ClipboardCaptureState
{
    public uint LastSequence { get; private set; }
    public bool PrivacyPaused { get; private set; }
    public CaptureAttempt? Pending { get; private set; }
    public bool ShouldCapture(uint sequence) => !PrivacyPaused && sequence != LastSequence;

    public CaptureAttempt Begin(uint sequence, string text, long created)
    {
        if (PrivacyPaused) throw new InvalidOperationException("Privacy pause is active.");
        if (Pending is not { } pending || pending.Sequence != sequence || pending.Text != text)
            Pending = new(sequence, Guid.NewGuid().ToString(), text, created);
        return Pending!;
    }

    public CaptureAttempt BeginImage(uint sequence, byte[] png, long created)
    {
        if (PrivacyPaused) throw new InvalidOperationException("Privacy pause is active.");
        if (Pending is not { } pending || pending.Sequence != sequence || pending.Png == null)
            Pending = new(sequence, Guid.NewGuid().ToString(), "", created) { Png = png };
        return Pending!;
    }

    public void Ignore(uint sequence) { LastSequence = sequence; Pending = null; }
    public void SetPrivacyPaused(bool paused, uint sequence)
    {
        PrivacyPaused = paused;
        // Never ingest clipboard changes made during the private interval on resume.
        Ignore(sequence);
    }

    public async Task<bool> CommitAsync(CaptureAttempt attempt, Func<Task> saveLocal, Func<Task>? enqueue)
    {
        if (PrivacyPaused || Pending != attempt) return false;
        await saveLocal();
        attempt.SavedLocally = true;
        if (PrivacyPaused || Pending != attempt) return false;
        if (enqueue != null) await enqueue();
        if (PrivacyPaused || Pending != attempt) return false;
        // A failed local write or queue write leaves the same attempt eligible for retry.
        LastSequence = attempt.Sequence; Pending = null;
        return true;
    }
}

sealed record CaptureAttempt(uint Sequence, string Id, string Text, long Created)
{
    public bool SavedLocally { get; set; }
    public byte[]? Png { get; init; }
}
