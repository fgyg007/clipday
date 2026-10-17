package io.jlmac.clipday.core;

import org.json.JSONObject;
import org.junit.Before;
import org.junit.Test;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.UUID;
import java.util.zip.CRC32;

import static org.junit.Assert.*;

/** Public synthetic fixtures only. Does not access an Android device or a NAS. */
public class ImageWireTest {
    private JSONObject fixture, pair, manifest;
    private byte[] png;
    private String id;

    @Before public void loadFixture() throws Exception {
        Path directory = Path.of(System.getProperty("clipday.repo.root", ".")).toAbsolutePath().normalize();
        Path file = null;
        while (directory != null) {
            Path candidate = directory.resolve("Tests/Fixtures/image-v1.json");
            if (Files.isRegularFile(candidate)) { file = candidate; break; }
            directory = directory.getParent();
        }
        assertNotNull("Run from the repository or set -Dclipday.repo.root", file);
        fixture = new JSONObject(Files.readString(file));
        pair = new JSONObject().put("v", 1).put("space", fixture.getString("space"))
            .put("key", fixture.getString("keyBase64"));
        manifest = fixture.getJSONObject("manifest");
        png = Wire.unbase(fixture.getString("pngBase64"));
        id = fixture.getString("id");
    }

    @Test public void sharedVectorAuthenticatesAndVerifies() throws Exception {
        JSONObject read = ImageWire.openManifest(Wire.unbase(fixture.getString("manifestEnvelopeBase64")), pair, id);
        assertEquals(manifest.toMap(), read.toMap());
        byte[] recovered = ImageWire.openChunk(Wire.unbase(fixture.getString("chunkEnvelopeBase64")), read, 0, pair);
        assertArrayEquals(png, recovered);
        ImageWire.verifyImage(recovered, read);
        assertArrayEquals(new int[]{2, 2}, ImageWire.pngDimensions(recovered));
        assertEquals("445d68236cc530d353247361256337fce1c9aa9f0f95b06825dcfb9f64def069", ImageWire.sha256(recovered));
    }

    @Test public void randomizedRoundTripAndOptionalCrossRuntimeVector() throws Exception {
        JSONObject built = ImageWire.manifest(png, pair, id, manifest.getString("device"), manifest.getString("name"),
            manifest.getLong("seq"), manifest.getLong("created"), manifest.getJSONObject("observed"));
        assertEquals(manifest.toMap(), Wire.cloneJson(built).toMap());
        byte[] sealedManifest = ImageWire.sealManifest(built, pair);
        byte[] sealedChunk = ImageWire.sealChunk(png, built, 0, pair);
        assertFalse(Arrays.equals(sealedManifest, ImageWire.sealManifest(built, pair)));
        assertFalse(Arrays.equals(sealedChunk, ImageWire.sealChunk(png, built, 0, pair)));
        JSONObject read = ImageWire.openManifest(sealedManifest, pair, id);
        ImageWire.verifyImage(ImageWire.openChunk(sealedChunk, read, 0, pair), read);
        String output = System.getenv("CLIPDAY_IMAGE_VECTOR_OUT");
        if (output != null && !output.isBlank()) {
            Path target = Path.of(output).toAbsolutePath().normalize();
            Path temp = Path.of(System.getProperty("java.io.tmpdir")).toAbsolutePath().normalize();
            assertTrue("Public vector output must be in the temporary directory", target.startsWith(temp));
            JSONObject vector = new JSONObject().put("description", "Public test key only; randomly generated Java AES-GCM nonces")
                .put("keyBase64", pair.getString("key")).put("space", pair.getString("space")).put("id", id)
                .put("pngBase64", Wire.base(png)).put("manifest", built)
                .put("manifestAad", fixture.getString("manifestAad")).put("chunkAad", fixture.getString("chunkAad"))
                .put("manifestEnvelopeBase64", Wire.base(sealedManifest)).put("chunkEnvelopeBase64", Wire.base(sealedChunk));
            Files.writeString(target, vector.toString(2));
        }
    }

    @Test public void builderCopiesClockAndChecksTimeOverflow() throws Exception {
        JSONObject observed = new JSONObject().put(manifest.getString("device"), 1);
        JSONObject built = ImageWire.manifest(png, pair, id, manifest.getString("device"), "Android", 1, 1, observed);
        observed.put(manifest.getString("device"), 99);
        assertEquals(1, built.getJSONObject("observed").getLong(manifest.getString("device")));
        assertThrows(Exception.class, () -> ImageWire.manifest(png, pair, id, manifest.getString("device"), "Android", 1, 0, observed));
        assertThrows(Exception.class, () -> ImageWire.manifest(png, pair, id, manifest.getString("device"), "Android", 1, Long.MAX_VALUE, observed));
        // Future timestamps are structurally valid; receiver time-window checks keep them retryable.
        ImageWire.validate(built.put("created", Long.MAX_VALUE - Wire.LIFETIME).put("expires", Long.MAX_VALUE), pair, id);
    }

    @Test public void maliciousPngHeadersAndDimensionsAreRejected() throws Exception {
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(null));
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(new byte[0]));
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(new byte[ImageWire.MAX_BYTES + 1]));
        byte[] badSignature = png.clone(); badSignature[0] = 0;
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(badSignature));
        for (int[] dims : new int[][]{{0, 1}, {1, 0}, {8193, 1}, {1, 8193}, {8192, 8192}, {-1, 1}, {Integer.MAX_VALUE, Integer.MAX_VALUE}}) {
            byte[] malicious = withDimensions(dims[0], dims[1]);
            assertThrows(Arrays.toString(dims), Exception.class, () -> ImageWire.pngDimensions(malicious));
        }
        assertArrayEquals(new int[]{4096, 4096}, ImageWire.pngDimensions(withDimensions(4096, 4096)));
        assertArrayEquals(new int[]{8192, 2048}, ImageWire.pngDimensions(withDimensions(8192, 2048)));
        byte[] overflowLength = png.clone(); Arrays.fill(overflowLength, 8, 12, (byte)255);
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(overflowLength));
        byte[] headerLength = png.clone(); headerLength[11] = 12;
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(headerLength));
    }

    @Test public void malformedColorCompressionAndInterlaceAreRejected() throws Exception {
        for (int[] change : new int[][]{{24, 3}, {25, 1}, {26, 1}, {27, 1}, {28, 2}}) {
            byte[] malformed = png.clone(); malformed[change[0]] = (byte)change[1]; updateCrc(malformed, 8);
            assertThrows(Exception.class, () -> ImageWire.pngDimensions(malformed));
        }
        byte[] indexedNoPalette = png.clone(); indexedNoPalette[25] = 3; updateCrc(indexedNoPalette, 8);
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(indexedNoPalette));
    }

    @Test public void crcFramingAndChunkOrderAreCheckedAcrossWholePng() throws Exception {
        for (int position : new int[]{16, 29, 45, png.length - 1}) {
            byte[] corrupted = png.clone(); corrupted[position] ^= 1;
            assertThrows(Exception.class, () -> ImageWire.pngDimensions(corrupted));
        }
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(Arrays.copyOf(png, png.length - 1)));
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(Arrays.copyOf(png, png.length + 1)));
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(join(Arrays.copyOf(png, 33), chunk("IEND", new byte[0]))));
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(insertBeforeData(chunk("IHDR", Arrays.copyOfRange(png, 16, 29)))));
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(insertBeforeData(chunk("CRIT", new byte[0]))));
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(insertBeforeData(chunk("texT", new byte[0]))));
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(insertBeforeData(chunk("1EXt", new byte[0]))));
        byte[] interruptedData = join(Arrays.copyOf(png, png.length - 12), chunk("tEXt", new byte[0]), chunk("IDAT", new byte[0]), chunk("IEND", new byte[0]));
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(interruptedData));
        assertArrayEquals(new int[]{2, 2}, ImageWire.pngDimensions(insertBeforeData(chunk("tEXt", Wire.utf8("Comment\0allowed")))));
    }

    @Test public void everyApngControlChunkIsRejected() throws Exception {
        for (String type : new String[]{"acTL", "fcTL", "fdAT"}) {
            byte[] animated = insertBeforeData(chunk(type, new byte[8]));
            assertThrows(type, Exception.class, () -> ImageWire.pngDimensions(animated));
        }
    }

    @Test public void compressedMetadataIsRejectedBeforeNativeDecode() throws Exception {
        for (String type : new String[]{"iCCP", "zTXt", "iTXt"}) {
            byte[] metadata = insertBeforeData(chunk(type, new byte[8]));
            assertThrows(type, Exception.class, () -> ImageWire.pngDimensions(metadata));
        }
    }

    @Test public void paletteStructureAndOrderingAreValidated() throws Exception {
        assertArrayEquals(new int[]{2, 2}, ImageWire.pngDimensions(insertBeforeData(chunk("PLTE", new byte[3]))));
        for (int length : new int[]{0, 1, 769}) {
            byte[] invalid = insertBeforeData(chunk("PLTE", new byte[length]));
            assertThrows(Exception.class, () -> ImageWire.pngDimensions(invalid));
        }
        byte[] duplicate = insertBeforeData(join(chunk("PLTE", new byte[3]), chunk("PLTE", new byte[3])));
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(duplicate));
        byte[] late = join(Arrays.copyOf(png, png.length - 12), chunk("PLTE", new byte[3]), chunk("IEND", new byte[0]));
        assertThrows(Exception.class, () -> ImageWire.pngDimensions(late));
    }

    @Test public void allManifestFieldTypesAndBoundsAreStrict() throws Exception {
        Object[][] mutations = {
            {"v", 2}, {"v", "1"}, {"kind", "text"}, {"mime", "image/jpeg"}, {"mime", "IMAGE/PNG"},
            {"id", "../escape"}, {"space", "../escape"}, {"device", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"},
            {"seq", 0}, {"seq", -1}, {"seq", 1.5}, {"seq", "1"}, {"seq", true},
            {"created", 0}, {"created", Long.MAX_VALUE}, {"expires", manifest.getLong("expires") + 1},
            {"byteCount", 0}, {"byteCount", ImageWire.MAX_BYTES + 1L}, {"byteCount", 82.0},
            {"chunkSize", 1024}, {"chunks", 0}, {"chunks", 2}, {"chunks", "1"},
            {"width", 0}, {"height", 8193}, {"width", 2.0}, {"width", "2"},
            {"sha256", manifest.getString("sha256").toUpperCase(java.util.Locale.ROOT)}, {"sha256", "0".repeat(63)},
            {"name", 42}, {"observed", "{}"}, {"observed", JSONObject.NULL}
        };
        for (Object[] mutation : mutations) {
            JSONObject invalid = Wire.cloneJson(manifest).put((String)mutation[0], mutation[1]);
            assertThrows(mutation[0] + "=" + mutation[1], Exception.class, () -> ImageWire.validate(invalid, pair, id));
        }
        for (String required : manifest.keySet()) {
            JSONObject missing = Wire.cloneJson(manifest); missing.remove(required);
            assertThrows(required, Exception.class, () -> ImageWire.validate(missing, pair, id));
        }
        JSONObject oversizedPixels = Wire.cloneJson(manifest).put("width", 8192).put("height", 8192);
        assertThrows(Exception.class, () -> ImageWire.validate(oversizedPixels, pair, id));
    }

    @Test public void namesUseUtf8BytesAndObservedMapIsBounded() throws Exception {
        ImageWire.validate(Wire.cloneJson(manifest).put("name", "é".repeat(128)), pair, id);
        assertThrows(Exception.class, () -> ImageWire.validate(Wire.cloneJson(manifest).put("name", "é".repeat(129)), pair, id));
        assertThrows(Exception.class, () -> ImageWire.validate(Wire.cloneJson(manifest).put("name", "\ud800"), pair, id));
        JSONObject clock = new JSONObject();
        for (int i = 0; i < 100; i++) clock.put(new UUID(0, i).toString(), i);
        ImageWire.validate(Wire.cloneJson(manifest).put("observed", clock), pair, id);
        clock.put(new UUID(0, 100).toString(), 0);
        assertThrows(Exception.class, () -> ImageWire.validate(Wire.cloneJson(manifest).put("observed", clock), pair, id));
        for (Object value : new Object[]{-1, 1.5, "1", true, JSONObject.NULL}) {
            JSONObject invalid = Wire.cloneJson(manifest).put("observed", new JSONObject().put(id, value));
            assertThrows(Exception.class, () -> ImageWire.validate(invalid, pair, id));
        }
        JSONObject badKey = Wire.cloneJson(manifest).put("observed", new JSONObject().put("../device", 0));
        assertThrows(Exception.class, () -> ImageWire.validate(badKey, pair, id));
    }

    @Test public void manifestSizeHasAnExactBound() throws Exception {
        JSONObject maximum = Wire.cloneJson(manifest).put("padding", "");
        maximum.put("padding", "x".repeat(ImageWire.MAX_MANIFEST - Wire.json(maximum).length));
        assertEquals(ImageWire.MAX_MANIFEST, Wire.json(maximum).length);
        byte[] envelope = ImageWire.sealManifest(maximum, pair);
        assertEquals(ImageWire.MAX_ENVELOPE, envelope.length);
        ImageWire.openManifest(envelope, pair, id);
        maximum.put("padding", maximum.getString("padding") + "x");
        assertThrows(Exception.class, () -> ImageWire.validate(maximum, pair, id));
        assertThrows(Exception.class, () -> ImageWire.sealManifest(maximum, pair));
        assertThrows(Exception.class, () -> ImageWire.openManifest(new byte[ImageWire.MAX_ENVELOPE + 1], pair, id));
    }

    @Test public void manifestRejectsMalformedUtf8TrailingDataAndDuplicateKeys() throws Exception {
        byte[] invalidUtf8 = join(Wire.utf8("{\"name\":\""), new byte[]{(byte)0xc0, (byte)0xaf}, Wire.utf8("\"}"));
        for (byte[] text : new byte[][]{invalidUtf8, join(Wire.json(manifest), Wire.utf8(" {}")), Wire.utf8("[]"),
                Wire.utf8("{\"v\":1,\"v\":2}"), new byte[0]}) {
            byte[] envelope = Wire.seal(text, Wire.unbase(pair.getString("key")), fixture.getString("manifestAad"));
            assertThrows(Exception.class, () -> ImageWire.openManifest(envelope, pair, id));
        }
    }

    @Test public void manifestSyntaxIsStrictOnBothAndroidAndDesktopJsonParsers() throws Exception {
        String base = manifest.toString();
        String prefix = base.substring(0, base.length() - 1) + ",\"extra\":";
        for (String bad : new String[]{base + "\u0000ignored", base + "/* comment */",
                prefix + "'single quotes'}", prefix + "01}", prefix + "+1}", prefix + "1.}",
                prefix + "1e}", prefix + "NaN}", prefix + "[1,]}", prefix + "{\"a\":1,}}",
                prefix + "{\"a\":1,\"\\u0061\":2}}", prefix + "\"bad\\xescape\"}",
                prefix + "\"literal\nnewline\"}", prefix + "[".repeat(34) + "0" + "]".repeat(34) + "}"}) {
            byte[] encrypted = Wire.seal(Wire.utf8(bad), Wire.unbase(pair.getString("key")), fixture.getString("manifestAad"));
            assertThrows(bad, Exception.class, () -> ImageWire.openManifest(encrypted, pair, id));
        }
        String valid = prefix + "[null,true,false,{},[],0,-1,1.25,1e2,\"\\u0061\\b\\f\\n\\r\\t\\/\\\\\\\"\"]}";
        byte[] encrypted = Wire.seal(Wire.utf8(valid), Wire.unbase(pair.getString("key")), fixture.getString("manifestAad"));
        assertEquals(id, ImageWire.openManifest(encrypted, pair, id).getString("id"));
    }

    @Test public void manifestAuthenticationBindsSpaceKeyAndExpectedFilename() throws Exception {
        byte[] envelope = ImageWire.sealManifest(manifest, pair);
        byte[] corrupted = envelope.clone(); corrupted[corrupted.length - 1] ^= 1;
        assertThrows(Exception.class, () -> ImageWire.openManifest(corrupted, pair, id));
        assertThrows(Exception.class, () -> ImageWire.openManifest(new byte[27], pair, id));
        assertThrows(Exception.class, () -> ImageWire.openManifest(envelope, pair, Wire.id()));
        assertThrows(Exception.class, () -> ImageWire.openManifest(envelope, pair, "../image"));
        JSONObject wrongSpace = Wire.cloneJson(pair).put("space", Wire.id());
        JSONObject wrongKey = Wire.cloneJson(pair).put("key", Wire.base(new byte[32]));
        assertThrows(Exception.class, () -> ImageWire.openManifest(envelope, wrongSpace, id));
        assertThrows(Exception.class, () -> ImageWire.openManifest(envelope, wrongKey, id));
        JSONObject wrongManifestSpace = Wire.cloneJson(manifest).put("space", Wire.id());
        byte[] authenticatedMismatch = Wire.seal(Wire.json(wrongManifestSpace), Wire.unbase(pair.getString("key")), fixture.getString("manifestAad"));
        assertThrows(Exception.class, () -> ImageWire.openManifest(authenticatedMismatch, pair, id));
        byte[] textDomain = Wire.seal(Wire.json(manifest), Wire.unbase(pair.getString("key")), "clipday-sync-v1:" + pair.getString("space"));
        assertThrows(Exception.class, () -> ImageWire.openManifest(textDomain, pair, id));
    }

    @Test public void chunkLengthsAreDerivedAtEveryBoundary() throws Exception {
        for (int length : new int[]{1, ImageWire.CHUNK_SIZE - 1, ImageWire.CHUNK_SIZE, ImageWire.CHUNK_SIZE + 1,
                2 * ImageWire.CHUNK_SIZE, ImageWire.MAX_BYTES - 1, ImageWire.MAX_BYTES}) {
            JSONObject r = layout(length);
            int chunks = r.getInt("chunks"), total = 0;
            for (int index = 0; index < chunks; index++) {
                int expected = Math.min(ImageWire.CHUNK_SIZE, length - index * ImageWire.CHUNK_SIZE);
                assertEquals(expected, ImageWire.chunkLength(r, index)); total += expected;
            }
            assertEquals(length, total);
            assertThrows(Exception.class, () -> ImageWire.chunkLength(r, -1));
            assertThrows(Exception.class, () -> ImageWire.chunkLength(r, chunks));
        }
        assertThrows(Exception.class, () -> ImageWire.chunkLength(layout(1).put("chunks", 2), 0));
        assertThrows(Exception.class, () -> ImageWire.chunkLength(layout(1).put("byteCount", Long.MAX_VALUE), 0));
    }

    @Test public void chunkAuthenticationBindsIdIndexSpaceLengthAndKey() throws Exception {
        JSONObject r = layout(2 * ImageWire.CHUNK_SIZE);
        byte[] block = new byte[ImageWire.CHUNK_SIZE]; Arrays.fill(block, (byte)17);
        byte[] encrypted = ImageWire.sealChunk(block, r, 0, pair);
        assertArrayEquals(block, ImageWire.openChunk(encrypted, r, 0, pair));
        assertThrows(Exception.class, () -> ImageWire.openChunk(encrypted, r, 1, pair));
        JSONObject otherId = Wire.cloneJson(r).put("id", Wire.id());
        assertThrows(Exception.class, () -> ImageWire.openChunk(encrypted, otherId, 0, pair));
        JSONObject otherPair = Wire.cloneJson(pair).put("space", Wire.id());
        JSONObject otherSpace = Wire.cloneJson(r).put("space", otherPair.getString("space"));
        assertThrows(Exception.class, () -> ImageWire.openChunk(encrypted, otherSpace, 0, otherPair));
        JSONObject otherKey = Wire.cloneJson(pair).put("key", Wire.base(new byte[32]));
        assertThrows(Exception.class, () -> ImageWire.openChunk(encrypted, r, 0, otherKey));
        assertThrows(Exception.class, () -> ImageWire.openChunk(encrypted, layout(ImageWire.CHUNK_SIZE - 1), 0, pair));
        byte[] wrongLengthAad = Wire.seal(block, Wire.unbase(pair.getString("key")), "clipday-image-chunk-v1:"
            + pair.getString("space") + ":" + id + ":0:" + (ImageWire.CHUNK_SIZE - 1));
        assertThrows(Exception.class, () -> ImageWire.openChunk(wrongLengthAad, r, 0, pair));
        byte[] corrupted = encrypted.clone(); corrupted[20] ^= 1;
        assertThrows(Exception.class, () -> ImageWire.openChunk(corrupted, r, 0, pair));
        assertThrows(Exception.class, () -> ImageWire.openChunk(Arrays.copyOf(encrypted, encrypted.length - 1), r, 0, pair));
        assertThrows(Exception.class, () -> ImageWire.openChunk(Arrays.copyOf(encrypted, encrypted.length + 1), r, 0, pair));
        assertThrows(Exception.class, () -> ImageWire.sealChunk(new byte[1], r, 0, pair));
        JSONObject last = layout(ImageWire.CHUNK_SIZE + 1);
        assertArrayEquals(new byte[]{7}, ImageWire.openChunk(ImageWire.sealChunk(new byte[]{7}, last, 1, pair), last, 1, pair));
    }

    @Test public void completeImageChecksLengthDigestDimensionsAndPng() throws Exception {
        ImageWire.verifyImage(png, manifest);
        assertThrows(Exception.class, () -> ImageWire.verifyImage(Arrays.copyOf(png, png.length - 1), manifest));
        assertThrows(Exception.class, () -> ImageWire.verifyImage(png, Wire.cloneJson(manifest).put("sha256", "0".repeat(64))));
        assertThrows(Exception.class, () -> ImageWire.verifyImage(png, Wire.cloneJson(manifest).put("width", 3)));
        byte[] corrupt = png.clone(); corrupt[45] ^= 1;
        JSONObject matchingHash = Wire.cloneJson(manifest).put("sha256", ImageWire.sha256(corrupt));
        assertThrows(Exception.class, () -> ImageWire.verifyImage(corrupt, matchingHash));
    }

    @Test public void pathsAreCanonicalAndNeverUseSenderFilenames() throws Exception {
        assertEquals("ClipDaySync/" + pair.getString("space") + "/images-v1/", ImageWire.root(pair));
        assertEquals(id + ".000.chunk", ImageWire.chunkName(id, 0));
        assertEquals(id + ".019.chunk", ImageWire.chunkName(id, 19));
        assertThrows(Exception.class, () -> ImageWire.chunkName("../escape", 0));
        assertThrows(Exception.class, () -> ImageWire.chunkName(id, -1));
        assertThrows(Exception.class, () -> ImageWire.chunkName(id, 20));
        assertThrows(Exception.class, () -> ImageWire.root(Wire.cloneJson(pair).put("space", "../escape")));
    }

    private JSONObject layout(int bytes) throws Exception {
        return Wire.cloneJson(manifest).put("byteCount", bytes).put("chunks", (bytes + ImageWire.CHUNK_SIZE - 1) / ImageWire.CHUNK_SIZE);
    }

    private byte[] withDimensions(int width, int height) {
        byte[] result = png.clone(); ByteBuffer.wrap(result).putInt(16, width).putInt(20, height); updateCrc(result, 8); return result;
    }

    private byte[] insertBeforeData(byte[] chunks) throws Exception {
        return join(Arrays.copyOf(png, 33), chunks, Arrays.copyOfRange(png, 33, png.length));
    }

    private static byte[] chunk(String type, byte[] body) {
        byte[] result = new byte[body.length + 12]; ByteBuffer.wrap(result).putInt(body.length);
        System.arraycopy(type.getBytes(StandardCharsets.US_ASCII), 0, result, 4, 4);
        System.arraycopy(body, 0, result, 8, body.length); updateCrc(result, 0); return result;
    }

    private static void updateCrc(byte[] bytes, int offset) {
        int length = ByteBuffer.wrap(bytes).getInt(offset); CRC32 crc = new CRC32(); crc.update(bytes, offset + 4, length + 4);
        ByteBuffer.wrap(bytes).putInt(offset + 8 + length, (int)crc.getValue());
    }

    private static byte[] join(byte[]... parts) throws Exception {
        ByteArrayOutputStream result = new ByteArrayOutputStream();
        for (byte[] part : parts) result.write(part); return result.toByteArray();
    }
}
