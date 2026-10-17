package io.jlmac.clipday.android;

import android.app.Instrumentation;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;
import android.os.Bundle;
import android.content.*;
import android.widget.*;
import android.view.*;
import org.json.JSONObject;
import java.util.function.BooleanSupplier;

/** Runs only against the isolated fixture SMB share supplied by the local QA harness. */
@RunWith(AndroidJUnit4.class)
public class JourneyTest {
    private Instrumentation getInstrumentation() { return InstrumentationRegistry.getInstrumentation(); }
    private MainActivity launch() {
        return (MainActivity)getInstrumentation().startActivitySync(new Intent(getInstrumentation().getTargetContext(), MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    }
    @Test public void testSmbTransport() throws Exception {
        JSONObject config = new JSONObject().put("host", InstrumentationRegistry.getArguments().getString("host", "10.0.2.2")).put("port", 1445).put("share", "fixture")
            .put("username", "clipdaytest").put("password", "ClipDay-fixture-only");
        try (io.jlmac.clipday.core.SmbStore store = new io.jlmac.clipday.core.SmbStore(new io.jlmac.clipday.core.NasConfig(config))) {
            assertTrue(store.exists("ClipDaySync"));
        }
    }
    private Button firstCopy(View view) {
        if (view instanceof Button && ((Button)view).getText().toString().equals("复制")) return (Button)view;
        if (view instanceof ViewGroup) for (int i = 0; i < ((ViewGroup)view).getChildCount(); i++) { Button b = firstCopy(((ViewGroup)view).getChildAt(i)); if (b != null) return b; }
        return null;
    }
    private void waitFor(BooleanSupplier done) throws Exception {
        long until = System.currentTimeMillis() + 45000;
        while (!done.getAsBoolean() && System.currentTimeMillis() < until) Thread.sleep(100);
        assertTrue("Timed out waiting for application state", done.getAsBoolean());
    }
    @Test public void testPairShareAndCopy() throws Exception {
        Bundle args = InstrumentationRegistry.getArguments();
        String pin = args.getString("pin"); assertNotNull("Synthetic pairing PIN required", pin);
        MainActivity activity = launch();
        ClipDayApp app = (ClipDayApp)activity.getApplication(); waitFor(() -> app.ready);
        getInstrumentation().runOnMainSync(() -> {
            ((EditText)activity.findViewById(R.id.nas_host)).setText(args.getString("host", "10.0.2.2") + ":1445");
            ((EditText)activity.findViewById(R.id.nas_share)).setText("fixture");
            ((EditText)activity.findViewById(R.id.nas_username)).setText("clipdaytest");
            ((EditText)activity.findViewById(R.id.nas_password)).setText("ClipDay-fixture-only");
            ((EditText)activity.findViewById(R.id.pair_code)).setText(pin);
            activity.findViewById(R.id.connect).performClick();
        });
        waitFor(() -> !app.saving && !app.busy); assertTrue(app.message, app.paired()); assertTrue(app.message, app.online);
        assertTrue(app.state().getJSONArray("history").length() >= 2);
        Vault vault = new Vault(activity); JSONObject restored = vault.load(); assertEquals(app.state().getJSONObject("pair").toString(), restored.getJSONObject("pair").toString());
        Intent shared = new Intent(Intent.ACTION_SEND).setType("text/plain").setClass(activity, MainActivity.class)
            .putExtra(Intent.EXTRA_TEXT, "Android share fixture 你好 📱").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        activity.startActivity(shared); getInstrumentation().waitForIdleSync();
        waitFor(() -> app.draft.equals("Android share fixture 你好 📱"));
        getInstrumentation().runOnMainSync(() -> activity.findViewById(R.id.send).performClick());
        waitFor(() -> !app.saving && !app.busy); assertTrue(app.message, app.online); assertEquals(0, app.state().getJSONArray("pending").length()); assertEquals("", app.draft);
        getInstrumentation().runOnMainSync(() -> {
            assertTrue(activity.findViewById(R.id.send).getHeight() >= 48 * activity.getResources().getDisplayMetrics().density);
            assertTrue(activity.findViewById(R.id.refresh).isShown());
            Button copy = firstCopy(activity.getWindow().getDecorView()); assertNotNull(copy); copy.performClick();
            ClipboardManager clipboard = (ClipboardManager)activity.getSystemService(Context.CLIPBOARD_SERVICE);
            assertEquals("Android share fixture 你好 📱", clipboard.getPrimaryClip().getItemAt(0).getText().toString());
        });
        // A cold reload must retain both the independently generated device identity and the pair.
        assertEquals(app.state().getString("device"), new Vault(activity).load().getString("device"));
    }
    @Test public void testOfflineKeepsPairAndQueue() throws Exception {
        MainActivity activity = launch(); ClipDayApp app = (ClipDayApp)activity.getApplication();
        waitFor(() -> app.ready && !app.busy); assertTrue(app.paired());
        getInstrumentation().runOnMainSync(() -> {
            ((EditText)activity.findViewById(R.id.composer)).setText("Android offline fixture");
            activity.findViewById(R.id.send).performClick();
        });
        waitFor(() -> !app.saving && !app.busy); assertTrue(app.paired()); assertFalse(app.online);
        assertEquals(1, app.state().getJSONArray("pending").length());
        assertEquals(1, new Vault(activity).load().getJSONArray("pending").length());
    }
    @Test public void testReconnectAfterProcessRestart() throws Exception {
        MainActivity activity = launch(); ClipDayApp app = (ClipDayApp)activity.getApplication();
        waitFor(() -> app.ready && !app.busy && app.online); assertTrue(app.paired());
        assertEquals(0, app.state().getJSONArray("pending").length());
        assertTrue(app.state().getJSONArray("history").toString().contains("Android offline fixture"));
    }
    @Test public void testLayoutPreview() throws Exception {
        MainActivity activity = launch(); ClipDayApp app = (ClipDayApp)activity.getApplication(); waitFor(() -> app.ready && !app.busy);
        getInstrumentation().waitForIdleSync();
        getInstrumentation().runOnMainSync(() -> {
            View view = activity.getWindow().getDecorView();
            android.graphics.Bitmap bitmap = android.graphics.Bitmap.createBitmap(view.getWidth(), view.getHeight(), android.graphics.Bitmap.Config.ARGB_8888);
            view.draw(new android.graphics.Canvas(bitmap));
            try (java.io.OutputStream out = new java.io.FileOutputStream(new java.io.File(activity.getExternalFilesDir(null), "layout.png"))) {
                bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out);
            } catch (Exception e) { throw new AssertionError(e); }
        });
    }
}
