package io.jlmac.clipday.core;
import org.json.JSONObject;
import org.junit.Test;
import static org.junit.Assert.*;
public class NasConfigTest {
    private JSONObject config(String host) throws Exception { return new JSONObject().put("host",host).put("share","fixture"); }
    @Test public void directDomainIsSupported() throws Exception { assertEquals("nas.example.com", new NasConfig(config("nas.example.com")).host); }
    @Test public void quickConnectHasActionableError() throws Exception {
        try { new NasConfig(config("example.cn6.quickconnect.cn")); fail(); }
        catch (Wire.UserError e) { assertTrue(e.getMessage().contains("QuickConnect")); assertTrue(e.getMessage().contains("VPN")); }
    }
    @Test public void webUrlHasActionableError() throws Exception {
        try { new NasConfig(config("https://nas.example.com/")); fail(); }
        catch (Wire.UserError e) { assertTrue(e.getMessage().contains("https://")); }
    }
}
