package io.jlmac.clipday.core;

import org.json.JSONObject;
import java.nio.file.*;

/** Only synthetic fixtures are accepted; never points at the user's real clipboard or NAS. */
public final class Interop {
    public static void main(String[] args) throws Exception {
        JSONObject pair = CoreTest.fixturePair();
        try (Store store = args[0].equals("smb") ? new SmbStore(new NasConfig(new JSONObject(Files.readString(Path.of(args[1]))))) : new LocalStore(Path.of(args[1]))) {
            if (args[0].equals("badjoin")) {
                String pin = new java.io.BufferedReader(new java.io.InputStreamReader(System.in)).readLine();
                try { Pairing.join(store, pin); throw new AssertionError("Wrong PIN accepted"); }
                catch (Wire.UserError e) { Wire.require(e.getMessage().contains("不匹配")); System.out.println("PASS: wrong PIN rejected by desktop SRP host"); return; }
            }
            if (args[0].equals("join") || args[0].equals("smb")) {
                String pin = new java.io.BufferedReader(new java.io.InputStreamReader(System.in)).readLine();
                JSONObject received = Pairing.join(store, pin);
                Wire.require(pair.getString("space").equals(received.getString("space")) && pair.getString("key").equals(received.getString("key")));
                System.out.println("PASS: Java SRP pairs with the desktop helper");
            }
            SyncEngine engine = new SyncEngine(null, s -> {}); engine.activate(new JSONObject(), pair); engine.poll(store, System.currentTimeMillis());
            String history = engine.snapshot().getJSONArray("history").toString();
            Wire.require(history.contains("Mac → Android") && history.contains("Windows → Android"));
            engine.enqueue("Android → desktop 你好 📱\r\nline two", "Android interop", System.currentTimeMillis()); engine.poll(store, System.currentTimeMillis());
            System.out.println("PASS: desktop records decrypted; Android record published");
        }
    }
}
