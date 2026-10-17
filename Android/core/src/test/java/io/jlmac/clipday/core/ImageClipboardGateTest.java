package io.jlmac.clipday.core;

import org.junit.Test;
import static org.junit.Assert.*;

public class ImageClipboardGateTest {
    @Test public void focusedResumeIgnoresPausedImageButCapturesFirstNewImage() {
        ImageClipboardGate gate=new ImageClipboardGate();gate.pause();assertFalse(gate.captureAllowed("paused"));
        gate.baseline("paused");assertFalse(gate.captureAllowed("paused"));assertTrue(gate.captureAllowed("first-new-after-resume"));
    }
    @Test public void unfocusedResumeDefersBaselineUntilPermittedRead() {
        ImageClipboardGate gate=new ImageClipboardGate();gate.pause();gate.focusChanged();assertTrue(gate.needsBaseline());
        assertFalse(gate.captureAllowed("unread-clipboard"));gate.baseline("unread-clipboard");assertFalse(gate.captureAllowed("unread-clipboard"));assertTrue(gate.captureAllowed("new-image"));
    }
    @Test public void precedingTextActivityBlocksOlderImageAndConcurrentActivityInvalidatesToken() {
        ImageClipboardGate gate=new ImageClipboardGate();gate.activity(1000);long token=gate.epoch();
        assertFalse(gate.automaticAllowed(token,999,100000,2000));assertTrue(gate.automaticAllowed(token,1500,100000,2000));
        gate.activity(2000);assertFalse(gate.automaticAllowed(token,2001,100000,2002));
    }
    @Test public void focusPauseAgeFutureAndExpiryFailClosed() {
        ImageClipboardGate gate=new ImageClipboardGate();long token=gate.epoch();
        assertFalse(gate.automaticAllowed(token,100,20000,10101));assertFalse(gate.automaticAllowed(token,1001,20000,1000));assertFalse(gate.automaticAllowed(token,100,999,1000));
        gate.focusChanged();assertFalse(gate.automaticAllowed(token,100,20000,1000));token=gate.epoch();gate.pause();assertFalse(gate.automaticAllowed(token,100,20000,1000));
    }
}
