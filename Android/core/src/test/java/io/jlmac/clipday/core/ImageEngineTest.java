package io.jlmac.clipday.core;

import org.json.*;
import org.junit.*;
import static org.junit.Assert.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.*;

/** Local fake NAS and encrypted private cache only; no SDK, device, or live SMB. */
public class ImageEngineTest {
    Path dir, cache;LocalStore store;JSONObject pair;long now=1800000000000L;
    byte[] png=Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAGUlEQVR4nAXBAQ0AAAjAINwsbvILImlH4h4/gAaBNbRWFQAAAABJRU5ErkJggg==");
    AtomicReference<JSONObject> durable;
    @Before public void setup()throws Exception{
        dir=Files.createTempDirectory("clipday-image-tests-");cache=dir.resolve("cache");store=new LocalStore(dir.resolve("nas"));pair=CoreTest.fixturePair();durable=new AtomicReference<>();
        Files.createDirectories(dir.resolve("nas").resolve(Wire.spaceRoot(pair)+"records"));
        store.atomic(Wire.spaceRoot(pair)+"space.json",Wire.json(new JSONObject().put("v",1).put("space",pair.getString("space"))));
        JSONObject proof=new JSONObject().put("v",1).put("space",pair.getString("space")).put("id",pair.getString("space")).put("device",Wire.id()).put("name","test").put("seq",1).put("created",now).put("expires",now+Wire.LIFETIME).put("observed",new JSONObject()).put("text","clipday-space-v1");
        store.atomic(Wire.spaceRoot(pair)+"space.check",Wire.sealRecord(proof,pair));
    }
    @After public void cleanup()throws Exception{try(var walk=Files.walk(dir)){for(Path p:walk.sorted(Comparator.reverseOrder()).toList())Files.deleteIfExists(p);}}
    ImageEngine engine()throws Exception{ImageEngine e=new ImageEngine(null,n->durable.set(Wire.cloneJson(n)),new ImageFiles(cache),ImageWire::verifyImage);e.configure(pair,Wire.id());return e;}
    JSONObject remote(long created)throws Exception{return ImageWire.manifest(png,pair,Wire.id(),Wire.id(),"desktop",1,created,new JSONObject());}
    void publish(JSONObject r)throws Exception{store.imageDirectory(ImageWire.root(pair));store.atomic(ImageWire.root(pair)+ImageWire.chunkName(r.getString("id"),0),ImageWire.sealChunk(png,r,0,pair));store.atomic(ImageWire.root(pair)+r.getString("id")+".img",ImageWire.sealManifest(r,pair));}
    private static class Forward implements Store{
        final Store inner;Forward(Store s){inner=s;}public byte[] read(String p,int n)throws Exception{return inner.read(p,n);}public boolean exists(String p)throws Exception{return inner.exists(p);}public List<String> list(String p)throws Exception{return inner.list(p);}public void create(String p,byte[] b)throws Exception{inner.create(p,b);}public void atomic(String p,byte[] b)throws Exception{inner.atomic(p,b);}public void delete(String p)throws Exception{inner.delete(p);}public void imageDirectory(String p)throws Exception{inner.imageDirectory(p);}public void close(){}
    }
    @Test public void durableEncryptedCaptureRestartUploadManifestLast()throws Exception{
        ImageEngine e=engine();String id=e.enqueue(png,"Android",now,()->true);
        assertEquals(1,durable.get().getJSONArray("pending").length());byte[] cacheBytes=Files.readAllBytes(cache.resolve(ImageWire.chunkName(id,0)));assertFalse(Arrays.equals(png,cacheBytes));
        ImageEngine restarted=new ImageEngine(durable.get(),n->durable.set(Wire.cloneJson(n)),new ImageFiles(cache),ImageWire::verifyImage);
        List<String> writes=new ArrayList<>();Store tracked=new Forward(store){@Override public void atomic(String p,byte[] b)throws Exception{writes.add(p);super.atomic(p,b);}};
        assertEquals(1,restarted.poll(tracked,now,()->true).uploaded);assertTrue(writes.get(writes.size()-1).endsWith(".img"));assertEquals(0,restarted.snapshot().getJSONArray("pending").length());assertArrayEquals(png,restarted.image(id,now));
    }
    @Test public void missingChunkDurableInboxRemainsUnseenAndRetries()throws Exception{
        ImageEngine e=engine();JSONObject r=remote(now);publish(r);String chunk=ImageWire.root(pair)+ImageWire.chunkName(r.getString("id"),0);byte[] encrypted=store.read(chunk,1000);store.delete(chunk);
        ImageEngine.Result failed=e.poll(store,now,()->true);assertEquals(1,failed.failures);assertEquals(0,e.snapshot().getJSONArray("history").length());assertEquals(1,e.snapshot().getJSONArray("inbox").length());
        ImageEngine restarted=new ImageEngine(durable.get(),n->durable.set(Wire.cloneJson(n)),new ImageFiles(cache),ImageWire::verifyImage);store.atomic(chunk,encrypted);assertEquals(1,restarted.poll(store,now,()->true).received);assertArrayEquals(png,restarted.image(r.getString("id"),now));
    }
    @Test public void shaAndNativeValidationBeforeUsableHistory()throws Exception{
        ImageEngine e=engine();JSONObject r=remote(now).put("sha256","0".repeat(64));publish(r);assertEquals(1,e.poll(store,now,()->true).failures);assertEquals(0,e.snapshot().getJSONArray("history").length());
        assertThrows(Exception.class,()->e.image(r.getString("id"),now));
    }
    @Test public void pauseLateUploadRetainsPendingAndStopsManifest()throws Exception{
        ImageEngine e=engine();e.enqueue(png,"Android",now,()->true);AtomicBoolean allowed=new AtomicBoolean(true);AtomicInteger writes=new AtomicInteger();
        Store stopping=new Forward(store){@Override public void atomic(String p,byte[] b)throws Exception{super.atomic(p,b);writes.incrementAndGet();allowed.set(false);}};
        assertTrue(e.poll(stopping,now,allowed::get).paused);assertEquals(1,writes.get());assertEquals(1,e.snapshot().getJSONArray("pending").length());assertEquals(1,e.poll(store,now,()->true).uploaded);
    }
    @Test public void pauseLateReadDoesNotCommitHistory()throws Exception{
        ImageEngine e=engine();JSONObject r=remote(now);publish(r);AtomicBoolean allowed=new AtomicBoolean(true);
        Store stopping=new Forward(store){@Override public byte[] read(String p,int limit)throws Exception{byte[] b=super.read(p,limit);if(p.endsWith(".chunk"))allowed.set(false);return b;}};
        assertTrue(e.poll(stopping,now,allowed::get).paused);assertEquals(0,e.snapshot().getJSONArray("history").length());assertEquals(1,e.poll(store,now,()->true).received);
    }
    @Test public void privacyCaptureCancelledButSyncOnlyAllowsLocalSave()throws Exception{
        ImageEngine e=engine();assertThrows(GuardedStore.Stopped.class,()->e.enqueue(png,"Android",now,()->false));assertEquals(0,e.snapshot().getJSONArray("history").length());
        e.enqueue(png,"Android",now,()->true);assertTrue(e.poll(store,now,()->false).paused);assertEquals(1,e.snapshot().getJSONArray("pending").length());assertEquals(1,e.poll(store,now,()->true).uploaded);
    }
    @Test public void expirationOriginalNotExtendedAndFutureRetry()throws Exception{
        ImageEngine e=engine();String id=e.enqueue(png,"Android",now,()->true);assertEquals(now+Wire.LIFETIME,e.record(id,now).getLong("expires"));e.prune(now+Wire.LIFETIME);assertEquals(0,e.snapshot().getJSONArray("pending").length());assertFalse(Files.exists(cache.resolve(ImageWire.chunkName(id,0))));
        JSONObject r=remote(now+400000);publish(r);assertEquals(1,e.poll(store,now,()->true).futureRecords);assertEquals(0,e.snapshot().getJSONArray("history").length());assertEquals(1,e.poll(store,now+400000,()->true).received);
    }
    @Test public void firstScanHistoryOnlyThenFreshSingleSourceAndObservedGate()throws Exception{
        ImageEngine e=engine();JSONObject first=remote(now);publish(first);assertNull(e.poll(store,now,()->true).automatic);
        JSONObject next=remote(now+1000).put("device",first.getString("device")).put("seq",2);publish(next);assertNotNull(e.poll(store,now+1000,()->true).automatic);
        e.enqueue(png,"Android",now+1500,()->true);JSONObject stale=remote(now+2000).put("device",first.getString("device")).put("seq",3);publish(stale);assertNull(e.poll(store,now+2000,()->true).automatic);
        JSONObject observed=remote(now+3000).put("device",first.getString("device")).put("seq",4);observed.getJSONObject("observed").put(e.snapshot().getString("device"),e.sequence());publish(observed);assertNotNull(e.poll(store,now+3000,()->true).automatic);
        e.invalidate();JSONObject catchup=remote(now+4000).put("device",first.getString("device")).put("seq",5);catchup.getJSONObject("observed").put(e.snapshot().getString("device"),e.sequence());publish(catchup);assertNull(e.poll(store,now+4000,()->true).automatic);
    }
    @Test public void competingFreshSourcesSuppressAutomatic()throws Exception{
        ImageEngine e=engine();e.poll(store,now,()->true);publish(remote(now+1000));publish(remote(now+1000));assertNull(e.poll(store,now+1000,()->true).automatic);
    }
    @Test public void hundredRecordLimitNeverEvictsPending()throws Exception{
        ImageEngine e=engine();for(int i=0;i<100;i++)e.enqueue(png,"Android",now+i,()->true);assertThrows(Wire.UserError.class,()->e.enqueue(png,"Android",now+101,()->true));assertEquals(100,e.snapshot().getJSONArray("pending").length());
    }
    @Test public void spaceSwitchBlockedWithPendingAndCachePathRejectsSymlink()throws Exception{
        ImageEngine e=engine();e.enqueue(png,"Android",now,()->true);assertThrows(Wire.UserError.class,()->e.configure(Wire.cloneJson(pair).put("space",Wire.id()),e.snapshot().getString("device")));
        Path target=dir.resolve("outside");Files.createDirectories(target);Path link=dir.resolve("link");Files.createSymbolicLink(link,target);assertThrows(Wire.UserError.class,()->new ImageFiles(link));
    }
    @Test public void cleanStartupDoesNotRequireDirectorySync() throws Exception {
        AtomicInteger syncs = new AtomicInteger();
        ImageFiles files = new ImageFiles(dir.resolve("clean-startup"), path -> syncs.incrementAndGet());
        new ImageEngine(null, value -> {}, files, ImageWire::verifyImage);
        assertEquals("An unchanged cache must not fsync its directory during app startup", 0, syncs.get());

        Path stale = dir.resolve("clean-startup").resolve("." + Wire.id() + ".tmp");
        Files.write(stale, new byte[]{1});
        new ImageEngine(null, value -> {}, files, ImageWire::verifyImage);
        assertEquals("Deleting a stale cache file must still sync the directory", 1, syncs.get());
    }
    @Test public void failedMetadataCommitDoesNotLeaveUntrackedPlainOrCiphertext()throws Exception{
        ImageEngine configured=engine();ImageEngine broken=new ImageEngine(configured.snapshot(),n->{throw new IOException("disk full");},new ImageFiles(cache),ImageWire::verifyImage);
        assertThrows(IOException.class,()->broken.enqueue(png,"Android",now,()->true));assertEquals(0,new ImageFiles(cache).bytes());
    }
    @Test public void retryUsesSameCaptureIdentityAndOriginalExpiration() throws Exception {
        ImageEngine initial=engine();AtomicBoolean fail=new AtomicBoolean(true);
        ImageEngine e=new ImageEngine(initial.snapshot(),n->{if(fail.getAndSet(false))throw new IOException("temporary disk failure");durable.set(Wire.cloneJson(n));},new ImageFiles(cache),ImageWire::verifyImage);
        String id=Wire.id();assertThrows(IOException.class,()->e.enqueue(png,"Android",id,now,now,()->true));
        assertEquals(id,e.enqueue(png,"Android",id,now,now+5000,()->true));assertEquals(now+Wire.LIFETIME,e.record(id,now+5000).getLong("expires"));
        assertEquals(id,e.enqueue(png,"Android",id,now,now+6000,()->true));assertEquals(1,e.snapshot().getJSONArray("history").length());assertEquals(1,e.sequence());
    }
    @Test public void payloadBudgetDefersWithoutFailureAndPreventsPartialAutomatic() throws Exception {
        ImageEngine e=engine();e.poll(store,now,()->true);publish(remote(now+1000));publish(remote(now+1000));publish(remote(now+1000));
        ImageEngine.Result result=e.poll(store,now+1000,()->true);assertEquals(2,result.received);assertTrue(result.deferred);assertEquals(0,result.failures);assertNull(result.automatic);
        assertEquals(1,e.poll(store,now+2000,()->true).received);
        for(int i=0;i<3;i++)e.enqueue(png,"Android",now+3000+i,()->true);
        assertEquals(2,e.poll(store,now+4000,()->true).uploaded);assertEquals(1,e.snapshot().getJSONArray("pending").length());assertEquals(1,e.poll(store,now+5000,()->true).uploaded);
    }
    @Test public void manifestScanCursorProgressesBeyondFirstThousandFailures() throws Exception {
        ImageEngine e=engine();store.imageDirectory(ImageWire.root(pair));
        for(int i=0;i<1000;i++)store.atomic(ImageWire.root(pair)+String.format(java.util.Locale.ROOT,"%08x-0000-4000-8000-000000000000.img",i),new byte[1]);
        JSONObject r=ImageWire.manifest(png,pair,"ffffffff-ffff-4fff-8fff-ffffffffffff",Wire.id(),"desktop",1,now,new JSONObject());publish(r);
        ImageEngine.Result first=e.poll(store,now,()->true);assertTrue(first.deferred);assertEquals(0,first.received);
        assertEquals(1,e.poll(store,now+1000,()->true).received);
    }
    @Test public void nativeValidationFailureRemainsRetryableNotUsable() throws Exception {
        ImageEngine initial=engine();AtomicBoolean reject=new AtomicBoolean(true);
        ImageEngine e=new ImageEngine(initial.snapshot(),n->durable.set(Wire.cloneJson(n)),new ImageFiles(cache),(data,r)->{if(reject.get())throw new IOException("native decode rejected");});
        JSONObject r=remote(now);publish(r);assertEquals(1,e.poll(store,now,()->true).failures);assertEquals(0,e.snapshot().getJSONArray("history").length());
        reject.set(false);assertEquals(1,e.poll(store,now+1000,()->true).received);
    }

    @Test public void multiChunkRoundTripAndStorageBudgetAreBounded() throws Exception {
        int length=ImageWire.CHUNK_SIZE+17;byte[] metadata=new byte[length];Arrays.fill(metadata,(byte)'x');metadata[0]='p';metadata[1]='a';metadata[2]='d';metadata[3]=0;
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();bytes.write(png,0,png.length-12);
        DataOutputStream data=new DataOutputStream(bytes);data.writeInt(length);byte[] type=Wire.utf8("tEXt");data.write(type);data.write(metadata);
        java.util.zip.CRC32 crc=new java.util.zip.CRC32();crc.update(type);crc.update(metadata);data.writeInt((int)crc.getValue());data.write(png,png.length-12,12);byte[] large=bytes.toByteArray();
        ImageEngine sender=engine();String id=sender.enqueue(large,"Android",now,()->true);assertEquals(2,sender.record(id,now).getInt("chunks"));assertEquals(1,sender.poll(store,now,()->true).uploaded);
        ImageEngine receiver=new ImageEngine(null,n->{},new ImageFiles(dir.resolve("receiver")),ImageWire::verifyImage);receiver.configure(pair,Wire.id());assertEquals(1,receiver.poll(store,now,()->true).received);assertArrayEquals(large,receiver.image(id,now));
        Path quota=dir.resolve("quota");ImageFiles limited=new ImageFiles(quota);Path sparse=quota.resolve(ImageWire.chunkName(Wire.id(),0));
        try(java.nio.channels.FileChannel file=java.nio.channels.FileChannel.open(sparse,StandardOpenOption.CREATE_NEW,StandardOpenOption.WRITE)){file.position(ImageFiles.MAX_BYTES-1);file.write(java.nio.ByteBuffer.wrap(new byte[]{0}));}
        assertThrows(Wire.UserError.class,()->limited.reserve(1));assertThrows(Wire.UserError.class,()->limited.read("../escape",0,29));
    }

}
