package io.jlmac.clipday.core;

import org.json.*;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.*;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

public final class Wire {
    public static final long LIFETIME = 86_400_000L;
    public static final int MAX_TEXT = 1_048_576, MAX_FILE = 2_097_152;
    private static final SecureRandom RANDOM = new SecureRandom();
    public static final class UserError extends Exception { public UserError(String message) { super(message); } }
    public static byte[] utf8(String value) { return value.getBytes(StandardCharsets.UTF_8); }
    public static byte[] json(JSONObject value) { return utf8(value.toString()); }
    public static JSONObject parse(byte[] data) throws Exception { return new JSONObject(new String(data, StandardCharsets.UTF_8)); }
    public static JSONObject cloneJson(JSONObject value) throws Exception { return new JSONObject(value.toString()); }
    public static String id() { return UUID.randomUUID().toString(); }
    public static boolean isId(String s) { return s != null && s.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"); }
    public static void require(boolean value) throws UserError { if (!value) throw new UserError("数据验证失败，请刷新或重新配对。"); }
    public static byte[] unbase(String text) { return Base64.getDecoder().decode(text); }
    public static String base(byte[] data) { return Base64.getEncoder().encodeToString(data); }
    public static long integer(JSONObject value, String key) throws Exception {
        Object n = value.get(key); require(n instanceof Integer || n instanceof Long); return ((Number)n).longValue();
    }
    public static void pair(JSONObject pair) throws Exception { require(integer(pair, "v") == 1 && isId(pair.getString("space")) && unbase(pair.getString("key")).length == 32); }
    public static byte[] seal(byte[] data, byte[] key, String aad) throws Exception {
        byte[] nonce = new byte[12]; RANDOM.nextBytes(nonce);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
        cipher.updateAAD(utf8(aad)); byte[] encrypted = cipher.doFinal(data);
        byte[] result = Arrays.copyOf(nonce, nonce.length + encrypted.length);
        System.arraycopy(encrypted, 0, result, 12, encrypted.length); return result;
    }
    public static byte[] open(byte[] data, byte[] key, String aad) throws Exception {
        require(data.length >= 28 && data.length <= MAX_FILE);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, Arrays.copyOf(data, 12)));
        cipher.updateAAD(utf8(aad)); return cipher.doFinal(data, 12, data.length - 12);
    }
    public static byte[] sealRecord(JSONObject r, JSONObject p) throws Exception {
        pair(p); return seal(json(r), unbase(p.getString("key")), "clipday-sync-v1:" + p.getString("space"));
    }
    public static JSONObject openRecord(byte[] data, JSONObject p) throws Exception {
        pair(p); JSONObject r = parse(open(data, unbase(p.getString("key")), "clipday-sync-v1:" + p.getString("space")));
        long created = integer(r, "created"); JSONObject observed = r.getJSONObject("observed");
        require(integer(r, "v") == 1 && r.getString("space").equals(p.getString("space")) && isId(r.getString("id")) && isId(r.getString("device"))
            && integer(r, "seq") > 0 && created > 0 && created <= Long.MAX_VALUE - LIFETIME && integer(r, "expires") == created + LIFETIME
            && !r.getString("text").isEmpty() && utf8(r.getString("text")).length <= MAX_TEXT && utf8(r.getString("name")).length <= 256 && observed.length() <= 100);
        for (Iterator<String> i = observed.keys(); i.hasNext();) { String k = i.next(); require(isId(k) && integer(observed, k) >= 0); }
        return r;
    }
    public static String spaceRoot(JSONObject p) throws Exception { pair(p); return "ClipDaySync/" + p.getString("space") + "/"; }
    public static void verify(Store store, JSONObject p) throws Exception {
        String root = spaceRoot(p); JSONObject marker = parse(store.read(root + "space.json", 8192));
        require(marker.getInt("v") == 1 && marker.getString("space").equals(p.getString("space")) && store.exists(root + "records"));
        JSONObject proof = openRecord(store.read(root + "space.check", MAX_FILE), p);
        require(proof.getString("id").equals(p.getString("space")) && proof.getString("text").equals("clipday-space-v1"));
    }
}
