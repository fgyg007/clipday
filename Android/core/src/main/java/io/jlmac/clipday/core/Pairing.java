package io.jlmac.clipday.core;

import org.json.JSONObject;
import org.bouncycastle.crypto.agreement.srp.*;
import org.bouncycastle.crypto.digests.SHA256Digest;
import org.bouncycastle.crypto.params.SRP6GroupParameters;
import org.bouncycastle.util.BigIntegers;
import java.math.BigInteger;
import java.security.*;
import java.util.Arrays;

public final class Pairing {
    private static final SRP6GroupParameters GROUP = SRP6StandardGroups.rfc5054_3072;
    private static final String DIR = "ClipDaySync/Pairing-v2/";
    static BigInteger number(String value, int max) throws Exception {
        byte[] b = Wire.unbase(value); BigInteger n = new BigInteger(1, b);
        Wire.require(b.length > 0 && b.length <= max && n.signum() > 0 && n.compareTo(GROUP.getN()) < 0); return n;
    }
    public static JSONObject join(Store store, String code) throws Exception {
        code = code.replace(" ", "").trim();
        if (!code.matches("[0-9]{6}")) throw new Wire.UserError("请输入电脑显示的 6 位配对码。");
        if (!store.exists(DIR + "active.json")) throw new Wire.UserError("未找到配对码。请在电脑上显示配对码，并确认两端选择的是同一个文件夹。");
        JSONObject offer = Wire.parse(store.read(DIR + "active.json", 8192));
        String id = offer.getString("id"), round = offer.getString("round"); long expires = offer.getLong("expires"), now = System.currentTimeMillis();
        Wire.require(offer.getInt("v") == 2 && Wire.isId(id) && Wire.isId(round) && Wire.unbase(offer.getString("salt")).length == 32);
        if (expires <= now || expires > now + 300000) throw new Wire.UserError("配对码已过期，或设备时间不一致。请在电脑上重新生成。");
        String identity = "clipday-pair-v2:" + id + ":" + round;
        SRP6Client srp = new SRP6Client(); srp.init(GROUP, new SHA256Digest(), new SecureRandom());
        BigInteger a = srp.generateClientCredentials(Wire.unbase(offer.getString("salt")), Wire.utf8(identity), Wire.utf8(code));
        srp.calculateSecret(number(offer.getString("b"), 384));
        JSONObject request = new JSONObject().put("id", id).put("round", round)
            .put("a", Wire.base(BigIntegers.asUnsignedByteArray(a))).put("m1", Wire.base(BigIntegers.asUnsignedByteArray(srp.calculateClientEvidenceMessage())));
        String responseFile = DIR + round + ".response";
        // Exclusive creation: another phone cannot replace a request already being checked.
        store.create(DIR + round + ".request", Wire.json(request));
        long started = System.nanoTime();
        try {
            while (System.currentTimeMillis() < expires && System.nanoTime() - started < 20_000_000_000L) {
                if (Thread.currentThread().isInterrupted()) throw new InterruptedException();
                Thread.sleep(200);
                if (!store.exists(responseFile)) continue;
                JSONObject response;
                try { response = Wire.parse(store.read(responseFile, 8192)); }
                catch (org.json.JSONException e) { continue; }
                Wire.require(id.equals(response.getString("id")) && round.equals(response.getString("round")));
                if (!response.optString("error").isEmpty()) throw new Wire.UserError("配对码不匹配，请核对电脑上的数字后重试。");
                Wire.require(srp.verifyServerEvidenceMessage(number(response.getString("m2"), 32)));
                byte[] key = MessageDigest.getInstance("SHA-256").digest(BigIntegers.asUnsignedByteArray(srp.calculateSessionKey()));
                byte[] plain = null;
                try {
                    byte[] encrypted = Wire.unbase(response.getString("sealed")); Wire.require(encrypted.length <= 2048);
                    plain = Wire.open(encrypted, key, identity); JSONObject pair = Wire.parse(plain); Wire.pair(pair);
                    if (System.currentTimeMillis() >= expires) throw new Wire.UserError("配对码已过期，请重新生成。");
                    Wire.verify(store, pair); return pair;
                } finally { Arrays.fill(key, (byte) 0); if (plain != null) Arrays.fill(plain, (byte) 0); }
            }
            throw new Wire.UserError("电脑未响应或配对码已过期，请重新生成后重试。");
        } finally { try { store.delete(responseFile); } catch (Exception ignored) { } }
    }
}
