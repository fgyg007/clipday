package io.jlmac.clipday.android;

import android.widget.*;
import org.junit.*;
import org.junit.runner.RunWith;
import org.robolectric.*;
import org.robolectric.android.controller.ActivityController;
import org.robolectric.annotation.Config;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, application = SetupFeedbackTest.TestApp.class)
public class SetupFeedbackTest {
    // No real vault, clipboard, credentials or NAS access in these UI regressions.
    public static class TestApp extends ClipDayApp {
        @Override public void onCreate() { ready = true; message = "等待设置"; }
    }
    private ActivityController<MainActivity> controller;
    private MainActivity activity;
    private ClipDayApp app;
    @Before public void open() {
        controller = Robolectric.buildActivity(MainActivity.class).create().start();
        activity = controller.get(); app = (ClipDayApp)activity.getApplication();
        ((EditText)activity.findViewById(R.id.nas_host)).setText("192.168.1.10");
        ((EditText)activity.findViewById(R.id.nas_share)).setText("fixture");
    }
    @After public void close() { controller.stop().destroy(); }
    private String result() { return ((TextView)activity.findViewById(R.id.setup_result)).getText().toString(); }
    private void click(int id) { assertTrue(activity.findViewById(id).performClick()); }
    @Test public void invalidWebAddressShowsPersistentResultForBothActions() {
        ((EditText)activity.findViewById(R.id.nas_host)).setText("https://example.com/");
        click(R.id.test_connection); assertTrue(result(), result().contains("不要填写 https://"));
        click(R.id.connect); assertTrue(result(), result().contains("不要填写 https://"));
        assertFalse(app.busy);
    }
    @Test public void missingPairCodeIsReportedBeforeNetworkAccess() {
        click(R.id.connect); assertTrue(result(), result().contains("6 位配对码")); assertFalse(app.busy);
    }
    @Test public void pauseExplainsWhyTestCannotRun() {
        app.syncPaused = true; app.setupFeedback("");
        click(R.id.test_connection); assertTrue(result(), result().contains("当前已暂停")); assertFalse(app.busy);
    }
    @Test public void automaticSyncBusyDoesNotSilentlyIgnoreClick() {
        app.busy = true; app.setupFeedback("");
        click(R.id.test_connection); assertTrue(result(), result().contains("正在进行"));
        app.busy = false;
    }
    @Test public void progressChangesButtonAndLocksFieldsUntilCompletion() {
        app.setupBusy = true; app.setupAction = "test"; app.setupFeedback("正在测试 NAS…");
        assertEquals("正在测试 NAS…", ((Button)activity.findViewById(R.id.test_connection)).getText().toString());
        assertFalse(activity.findViewById(R.id.connect).isEnabled());
        assertFalse(activity.findViewById(R.id.nas_host).isEnabled());
        app.setupBusy = false; app.setupFeedback("测试成功：NAS 可读写");
        assertTrue(activity.findViewById(R.id.connect).isEnabled());
        assertTrue(activity.findViewById(R.id.nas_host).isEnabled());
    }
    @Test public void resultSurvivesBackgroundStatusAndActivityRecreation() {
        app.setupFeedback("配对成功：已保存连接设置");
        app.message = "正在自动同步"; app.attach(() -> {});
        controller.recreate(); activity = controller.get();
        assertEquals("配对成功：已保存连接设置", result());
        assertTrue(activity.findViewById(R.id.setup_result).isShown());
    }
}
