using ClipDay.Sync;

namespace ClipDay.Cloud;

// Access only on the UI thread, including callbacks after BeginInvoke.
sealed class PairingViewState
{
    Guid session;
    bool finished;
    public Guid Begin() { session = Guid.NewGuid(); finished = false; return session; }
    public bool TryApply(Guid source, PairEvent ev)
    {
        if (source != session || finished) return false;
        if (ev.Type is "success" or "error" or "expired" or "cancelled") finished = true;
        return true;
    }
}
