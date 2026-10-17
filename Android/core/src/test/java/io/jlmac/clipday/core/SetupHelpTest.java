package io.jlmac.clipday.core;
import org.junit.Test;
import static org.junit.Assert.*;
public class SetupHelpTest {
    @Test public void describesSupportedModeAndReadonlyFirst() {
        String prompt = SetupHelp.androidNas(35);
        assertTrue(prompt.contains("Android（API 35）")); assertTrue(prompt.contains("模式：NAS"));
        assertTrue(prompt.contains("手机端目前不支持网盘文件夹模式")); assertTrue(prompt.contains("先做只读检查"));
    }
    @Test public void requiresPermissionAndNoSecurityBypass() {
        String prompt = SetupHelp.androidNas(35);
        assertTrue(prompt.contains("改变前都先问我")); assertTrue(prompt.contains("不关闭防火墙"));
        assertTrue(prompt.contains("不要索要或让我粘贴密码、令牌、配对密钥、剪贴板内容"));
    }
    @Test public void templateHasNoDynamicSensitiveInputsOrLinks() {
        String prompt = SetupHelp.androidNas(Integer.MAX_VALUE);
        assertEquals(SetupHelp.androidNas(-1), prompt);
        assertFalse(prompt.contains("http://")); assertFalse(prompt.contains("https://"));
        assertFalse(prompt.contains("clipday1:")); assertFalse(prompt.contains("clipday-drive1:"));
        assertFalse(prompt.contains("192.168.")); assertFalse(prompt.contains("/Users/"));
    }
}
