package io.jlmac.clipday.android;

import android.content.Context;
import android.security.keystore.*;
import android.util.AtomicFile;
import org.json.JSONObject;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;
import java.io.*;
import java.security.KeyStore;
import java.util.Arrays;
import io.jlmac.clipday.core.Wire;

/** Credentials, local history and the outbox share one atomic, Keystore-encrypted transaction. */
final class Vault {
    private final AtomicFile file;
    private static final String ALIAS = "clipday-local-v1";
    Vault(Context context) { this(context, "vault.enc"); }
    Vault(Context context, String filename) { file = new AtomicFile(new File(context.getNoBackupFilesDir(), filename)); }
    private SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null);
        if (!store.containsAlias(ALIAS)) {
            KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            return generator.generateKey();
        }
        return (SecretKey) store.getKey(ALIAS, null);
    }
    JSONObject load() throws Exception {
        if (!file.getBaseFile().exists() && !new File(file.getBaseFile() + ".bak").exists()) return null;
        byte[] data = file.readFully();
        if (data.length < 28 || data.length > 40 * 1024 * 1024) throw new IOException();
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, Arrays.copyOf(data, 12)));
        cipher.updateAAD(Wire.utf8(ALIAS)); byte[] plain = cipher.doFinal(data, 12, data.length - 12);
        try { return Wire.parse(plain); } finally { Arrays.fill(plain, (byte) 0); }
    }
    void save(JSONObject value) throws Exception {
        byte[] plain = Wire.json(value); FileOutputStream out = null;
        try {
            if (plain.length + 28 > 40 * 1024 * 1024) throw new IOException("Vault capacity");
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key()); cipher.updateAAD(Wire.utf8(ALIAS));
            byte[] encrypted = cipher.doFinal(plain); out = file.startWrite(); out.write(cipher.getIV()); out.write(encrypted); file.finishWrite(out);
        } catch (Exception e) { if (out != null) file.failWrite(out); throw new Wire.UserError("无法保存本机加密数据，请检查手机剩余空间后重试。"); }
        finally { Arrays.fill(plain, (byte) 0); }
    }
}
