package io.jlmac.clipday.core;

import org.json.JSONObject;
import org.json.JSONTokener;

import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Set;
import java.util.Locale;
import java.util.zip.CRC32;

/** Bounded, domain-separated image v1 wire format. Native decoders must also validate PNG data. */
public final class ImageWire {
    public static final int MAX_BYTES = 20 * 1_048_576;
    public static final int CHUNK_SIZE = 1_048_576;
    public static final int MAX_MANIFEST = 32_768;
    /** Maximum encrypted manifest size; a chunk envelope is chunkLength + 28 bytes. */
    public static final int MAX_ENVELOPE = MAX_MANIFEST + 28;
    public static final int MAX_PIXELS = 16_777_216;
    private static final int MAX_DIMENSION = 8192;
    private static final byte[] PNG_SIGNATURE = {(byte)137, 80, 78, 71, 13, 10, 26, 10};

    private ImageWire() { }

    /** Checks the complete bounded PNG chunk framing/CRC without allocating decoded pixels. */
    public static int[] pngDimensions(byte[] png) throws Exception {
        Wire.require(png != null && png.length >= 45 && png.length <= MAX_BYTES);
        for (int i = 0; i < PNG_SIGNATURE.length; i++) Wire.require(png[i] == PNG_SIGNATURE[i]);
        int offset = 8, width = 0, height = 0, color = -1, depth = 0;
        boolean header = false, palette = false, data = false, dataEnded = false;
        while (offset < png.length) {
            Wire.require(png.length - offset >= 12);
            long unsignedLength = uint32(png, offset);
            Wire.require(unsignedLength <= png.length - offset - 12L);
            int length = (int)unsignedLength;
            for (int i = 0; i < 4; i++) {
                int c = png[offset + 4 + i] & 255;
                Wire.require((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'));
            }
            // The reserved bit in a PNG chunk type must be zero.
            Wire.require((png[offset + 6] & 32) == 0);
            String type = new String(png, offset + 4, 4, StandardCharsets.US_ASCII);
            CRC32 crc = new CRC32();
            crc.update(png, offset + 4, length + 4);
            Wire.require(crc.getValue() == uint32(png, offset + 8 + length));
            Wire.require(header || type.equals("IHDR"));
            Wire.require(!type.equals("acTL") && !type.equals("fcTL") && !type.equals("fdAT"));
            // Do not pass compressed profile/text metadata to a native image decoder.
            Wire.require(!type.equals("iCCP") && !type.equals("zTXt") && !type.equals("iTXt"));
            if (type.equals("IHDR")) {
                Wire.require(!header && offset == 8 && length == 13);
                long w = uint32(png, offset + 8), h = uint32(png, offset + 12);
                dimensions(w, h);
                width = (int)w; height = (int)h;
                depth = png[offset + 16] & 255; color = png[offset + 17] & 255;
                boolean validDepth = (color == 0 && (depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16))
                    || (color == 2 && (depth == 8 || depth == 16))
                    || (color == 3 && (depth == 1 || depth == 2 || depth == 4 || depth == 8))
                    || ((color == 4 || color == 6) && (depth == 8 || depth == 16));
                Wire.require(validDepth && png[offset + 18] == 0 && png[offset + 19] == 0
                    && (png[offset + 20] == 0 || png[offset + 20] == 1));
                header = true;
            } else if (type.equals("PLTE")) {
                Wire.require(!palette && !data && color != 0 && color != 4
                    && length > 0 && length <= 768 && length % 3 == 0
                    && (color != 3 || length / 3 <= (1 << depth)));
                palette = true;
            } else if (type.equals("IDAT")) {
                Wire.require(!dataEnded && (color != 3 || palette));
                data = true;
            } else if (type.equals("IEND")) {
                Wire.require(data && length == 0 && offset + 12 == png.length);
                return new int[]{width, height};
            } else {
                // Unknown ancillary chunks are permitted; unknown critical chunks are not.
                Wire.require((png[offset + 4] & 32) != 0);
                if (data) dataEnded = true;
            }
            offset += length + 12;
        }
        throw new Wire.UserError("PNG 数据不完整或格式不受支持。");
    }

    private static long uint32(byte[] bytes, int offset) {
        return ((bytes[offset] & 255L) << 24) | ((bytes[offset + 1] & 255L) << 16)
            | ((bytes[offset + 2] & 255L) << 8) | (bytes[offset + 3] & 255L);
    }

    private static void dimensions(long width, long height) throws Exception {
        Wire.require(width > 0 && width <= MAX_DIMENSION && height > 0 && height <= MAX_DIMENSION
            && width * height <= MAX_PIXELS);
    }

    public static String sha256(byte[] bytes) {
        if (bytes == null) throw new IllegalArgumentException("Missing image bytes");
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
            char[] hex = new char[64];
            final char[] digits = "0123456789abcdef".toCharArray();
            for (int i = 0; i < digest.length; i++) {
                hex[i * 2] = digits[(digest[i] & 255) >>> 4];
                hex[i * 2 + 1] = digits[digest[i] & 15];
            }
            return new String(hex);
        } catch (java.security.NoSuchAlgorithmException impossible) {
            throw new IllegalStateException(impossible);
        }
    }

    public static JSONObject manifest(byte[] png, JSONObject pair, String id, String device,
                                      String name, long seq, long created, JSONObject observed) throws Exception {
        Wire.pair(pair);
        int[] size = pngDimensions(png);
        Wire.require(created > 0 && created <= Long.MAX_VALUE - Wire.LIFETIME && observed != null);
        JSONObject r = new JSONObject().put("v", 1).put("kind", "image").put("id", id)
            .put("space", pair.getString("space")).put("device", device).put("name", name)
            .put("seq", seq).put("created", created).put("expires", created + Wire.LIFETIME)
            .put("observed", Wire.cloneJson(observed)).put("mime", "image/png")
            .put("width", size[0]).put("height", size[1]).put("byteCount", png.length)
            .put("chunkSize", CHUNK_SIZE).put("chunks", count(png.length)).put("sha256", sha256(png));
        return validate(r, pair, id);
    }

    /** Temporal acceptance belongs to the receiver's clock, not the wire parser. */
    public static JSONObject validate(JSONObject r, JSONObject pair, String expectedId) throws Exception {
        Wire.pair(pair);
        fields(r);
        Wire.require(Wire.isId(expectedId) && r.getString("id").equals(expectedId)
            && r.getString("space").equals(pair.getString("space")));
        return r;
    }

    private static void fields(JSONObject r) throws Exception {
        Wire.require(r != null);
        long created = Wire.integer(r, "created");
        JSONObject observed = r.getJSONObject("observed");
        Wire.require(Wire.integer(r, "v") == 1 && string(r, "kind").equals("image")
            && Wire.isId(string(r, "id")) && Wire.isId(string(r, "space")) && Wire.isId(string(r, "device"))
            && Wire.integer(r, "seq") > 0 && created > 0 && created <= Long.MAX_VALUE - Wire.LIFETIME
            && Wire.integer(r, "expires") == created + Wire.LIFETIME && string(r, "mime").equals("image/png")
            && string(r, "sha256").matches("[0-9a-f]{64}") && observed.length() <= 100);
        // Reject unpaired UTF-16 surrogates instead of silently replacing them when encoding.
        ByteBuffer name = StandardCharsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).encode(java.nio.CharBuffer.wrap(string(r, "name")));
        Wire.require(name.remaining() <= 256);
        dimensions(Wire.integer(r, "width"), Wire.integer(r, "height"));
        layout(r);
        for (Iterator<String> keys = observed.keys(); keys.hasNext();) {
            String key = keys.next();
            Wire.require(Wire.isId(key) && Wire.integer(observed, key) >= 0);
        }
        Wire.require(Wire.json(r).length <= MAX_MANIFEST);
    }

    private static String string(JSONObject object, String key) throws Exception {
        Object value = object.get(key);
        Wire.require(value instanceof String);
        return (String)value;
    }

    private static int count(long bytes) { return (int)((bytes + CHUNK_SIZE - 1) / CHUNK_SIZE); }

    private static long layout(JSONObject r) throws Exception {
        long bytes = Wire.integer(r, "byteCount");
        Wire.require(bytes > 0 && bytes <= MAX_BYTES && Wire.integer(r, "chunkSize") == CHUNK_SIZE
            && Wire.integer(r, "chunks") == count(bytes));
        return bytes;
    }

    public static byte[] sealManifest(JSONObject r, JSONObject pair) throws Exception {
        validate(r, pair, r.getString("id"));
        return Wire.seal(Wire.json(r), Wire.unbase(pair.getString("key")), manifestAad(pair));
    }

    public static JSONObject openManifest(byte[] data, JSONObject pair, String expectedId) throws Exception {
        Wire.pair(pair);
        Wire.require(data != null && data.length >= 28 && data.length <= MAX_ENVELOPE && Wire.isId(expectedId));
        byte[] plain = Wire.open(data, Wire.unbase(pair.getString("key")), manifestAad(pair));
        Wire.require(plain.length > 0 && plain.length <= MAX_MANIFEST);
        String text = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(plain)).toString();
        new StrictJson(text).check();
        JSONTokener tokens = new JSONTokener(text);
        Object parsed = tokens.nextValue();
        Wire.require(parsed instanceof JSONObject && tokens.nextClean() == 0);
        return validate((JSONObject)parsed, pair, expectedId);
    }

    /** Android's JSONTokener accepts comments, duplicate keys and non-JSON literals. */
    private static final class StrictJson {
        final String text;
        int position;
        StrictJson(String text) { this.text = text; }
        void check() throws Exception { value(0); whitespace(); Wire.require(position == text.length()); }
        void whitespace() {
            while (position < text.length() && " \t\r\n".indexOf(text.charAt(position)) >= 0) position++;
        }
        boolean take(char ch) {
            if (position < text.length() && text.charAt(position) == ch) { position++; return true; }
            return false;
        }
        void value(int depth) throws Exception {
            whitespace(); Wire.require(depth <= 32 && position < text.length());
            char start = text.charAt(position);
            if (start == '{') {
                position++; whitespace(); Set<String> keys = new HashSet<>();
                if (take('}')) return;
                do {
                    whitespace(); String key = quoted(); Wire.require(keys.add(key));
                    whitespace(); Wire.require(take(':')); value(depth + 1); whitespace();
                    if (take('}')) return;
                    Wire.require(take(','));
                } while (true);
            } else if (start == '[') {
                position++; whitespace();
                if (take(']')) return;
                do {
                    value(depth + 1); whitespace();
                    if (take(']')) return;
                    Wire.require(take(','));
                } while (true);
            } else if (start == '"') {
                quoted();
            } else if (start == 't' || start == 'f' || start == 'n') {
                String literal = start == 't' ? "true" : start == 'f' ? "false" : "null";
                Wire.require(text.startsWith(literal, position)); position += literal.length();
            } else {
                take('-');
                if (!take('0')) { Wire.require(position < text.length() && text.charAt(position) >= '1' && text.charAt(position) <= '9'); digits(); }
                if (take('.')) { Wire.require(digit()); digits(); }
                if (take('e') || take('E')) { if (!take('+')) take('-'); Wire.require(digit()); digits(); }
            }
        }
        boolean digit() { return position < text.length() && text.charAt(position) >= '0' && text.charAt(position) <= '9'; }
        void digits() { while (digit()) position++; }
        String quoted() throws Exception {
            Wire.require(take('"')); StringBuilder result = new StringBuilder();
            while (position < text.length()) {
                char ch = text.charAt(position++);
                if (ch == '"') return result.toString();
                Wire.require(ch >= 0x20);
                if (ch == '\\') {
                    Wire.require(position < text.length()); ch = text.charAt(position++);
                    if (ch == 'u') {
                        Wire.require(position + 4 <= text.length()); int code = 0;
                        for (int i = 0; i < 4; i++) {
                            char hex = text.charAt(position++);
                            int digit = hex >= '0' && hex <= '9' ? hex - '0'
                                : hex >= 'a' && hex <= 'f' ? hex - 'a' + 10 : hex >= 'A' && hex <= 'F' ? hex - 'A' + 10 : -1;
                            Wire.require(digit >= 0); code = code * 16 + digit;
                        }
                        ch = (char)code;
                    } else {
                        int escape = "\"\\/bfnrt".indexOf(ch); Wire.require(escape >= 0);
                        ch = new char[]{'"', '\\', '/', '\b', '\f', '\n', '\r', '\t'}[escape];
                    }
                }
                result.append(ch);
            }
            throw new Wire.UserError("图像描述数据格式无效。");
        }
    }

    public static int chunkLength(JSONObject r, int index) throws Exception {
        long bytes = layout(r);
        Wire.require(index >= 0 && index < count(bytes));
        return (int)Math.min(CHUNK_SIZE, bytes - (long)index * CHUNK_SIZE);
    }

    public static byte[] sealChunk(byte[] plain, JSONObject r, int index, JSONObject pair) throws Exception {
        validate(r, pair, r.getString("id"));
        int length = chunkLength(r, index);
        Wire.require(plain != null && plain.length == length);
        return Wire.seal(plain, Wire.unbase(pair.getString("key")), chunkAad(r, index, length));
    }

    public static byte[] openChunk(byte[] data, JSONObject r, int index, JSONObject pair) throws Exception {
        validate(r, pair, r.getString("id"));
        int length = chunkLength(r, index);
        Wire.require(data != null && data.length == length + 28);
        byte[] plain = Wire.open(data, Wire.unbase(pair.getString("key")), chunkAad(r, index, length));
        Wire.require(plain.length == length);
        return plain;
    }

    private static String manifestAad(JSONObject pair) throws Exception {
        return "clipday-image-manifest-v1:" + pair.getString("space");
    }

    private static String chunkAad(JSONObject r, int index, int length) throws Exception {
        return "clipday-image-chunk-v1:" + r.getString("space") + ":" + r.getString("id") + ":" + index + ":" + length;
    }

    public static String root(JSONObject pair) throws Exception { return Wire.spaceRoot(pair) + "images-v1/"; }

    public static String chunkName(String id, int index) throws Exception {
        Wire.require(Wire.isId(id) && index >= 0 && index < MAX_BYTES / CHUNK_SIZE);
        return id + "." + String.format(Locale.ROOT, "%03d", index) + ".chunk";
    }

    public static void verifyImage(byte[] png, JSONObject r) throws Exception {
        fields(r);
        Wire.require(png != null && png.length == Wire.integer(r, "byteCount") && sha256(png).equals(r.getString("sha256")));
        int[] size = pngDimensions(png);
        Wire.require(size[0] == Wire.integer(r, "width") && size[1] == Wire.integer(r, "height"));
    }
}
