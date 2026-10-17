package io.jlmac.clipday.core;

import org.json.*;
import java.io.ByteArrayOutputStream;
import java.util.*;
import java.util.function.BooleanSupplier;

/** Separate image causal clock. Vault metadata commits only after encrypted chunks are durable. */
public final class ImageEngine {
    public interface Validator { void validate(byte[] png, JSONObject manifest) throws Exception; }
    private JSONObject state;
    private final SyncEngine.Saver saver;
    private final ImageFiles files;
    private final Validator validator;
    private final Object pollLock = new Object();
    private long generation, lastScan;
    private int scanCursor;
    public static final class Result {
        public int uploaded, received, failures, futureRecords, cleanupFailures;
        public boolean paused, deferred;
        public JSONObject automatic;
    }
    public ImageEngine(JSONObject initial, SyncEngine.Saver saver, ImageFiles files, Validator validator) throws Exception {
        this.saver = saver; this.files = files; this.validator = validator;
        state = initial == null ? new JSONObject().put("seq",0).put("clock",new JSONObject()).put("history",new JSONArray()).put("pending",new JSONArray()).put("inbox",new JSONArray()) : initial;
        Wire.require(Wire.integer(state,"seq") >= 0 && state.getJSONArray("history").length() + state.getJSONArray("inbox").length() <= 100);
        files.reconcile(ids(state));
    }
    private static Set<String> ids(JSONObject value) throws Exception {
        Set<String> result = new HashSet<>();
        for (String field : new String[]{"history","inbox"}) { JSONArray a = value.getJSONArray(field); for (int i=0;i<a.length();i++) result.add(a.getJSONObject(i).getString("id")); }
        return result;
    }
    private void commit(JSONObject next) throws Exception { saver.save(next); state = next; }
    public synchronized JSONObject snapshot() throws Exception { return Wire.cloneJson(state); }
    public synchronized long sequence() { return state.optLong("seq"); }
    public synchronized void invalidate() { generation++; lastScan=0; }
    public synchronized boolean hasPending() throws Exception { return state.getJSONArray("pending").length()>0; }
    public synchronized void configure(JSONObject pair, String device) throws Exception {
        Wire.pair(pair); Wire.require(Wire.isId(device));
        JSONObject old = state.optJSONObject("pair");
        if (old != null && old.toString().equals(pair.toString()) && device.equals(state.optString("device"))) return;
        boolean changed = old != null && !old.getString("space").equals(pair.getString("space"));
        if (changed && hasPending()) throw new Wire.UserError("还有待上传图片，请先在原同步空间完成上传，再切换空间。");
        JSONObject next = Wire.cloneJson(state);
        if (changed) next.put("seq",0).put("clock",new JSONObject()).put("history",new JSONArray()).put("pending",new JSONArray()).put("inbox",new JSONArray());
        next.put("pair",pair).put("device",device); commit(next); generation++; lastScan=0;
        if (changed) files.reconcile(ids(next));
    }
    private static JSONArray without(JSONArray old, String id, boolean strings) throws Exception {
        JSONArray result=new JSONArray(); for(int i=0;i<old.length();i++) if(!(strings?old.getString(i):old.getJSONObject(i).getString("id")).equals(id)) result.put(old.get(i)); return result;
    }
    private static JSONObject find(JSONArray a,String id) throws Exception { for(int i=0;i<a.length();i++) if(a.getJSONObject(i).getString("id").equals(id)) return a.getJSONObject(i); return null; }
    public synchronized void prune(long now) throws Exception {
        JSONObject next=Wire.cloneJson(state); Set<String> removed=new HashSet<>();
        for(String field:new String[]{"history","inbox"}) {JSONArray old=next.getJSONArray(field), kept=new JSONArray();for(int i=0;i<old.length();i++){JSONObject r=old.getJSONObject(i);if(r.getLong("expires")>now)kept.put(r);else removed.add(r.getString("id"));}next.put(field,kept);}
        for(String id:removed)next.put("pending",without(next.getJSONArray("pending"),id,true));
        if(!removed.isEmpty()){commit(next);for(String id:removed)files.remove(id);}
    }
    private static void capacity(JSONObject value) throws Exception {if(value.getJSONArray("history").length()+value.getJSONArray("inbox").length()>=100)throw new Wire.UserError("本机图片已达100条上限，请等待到期后重试；待上传图片不会被丢弃。");}
    private static void check(BooleanSupplier allowed) throws GuardedStore.Stopped {if(!allowed.getAsBoolean())throw new GuardedStore.Stopped();}
    public String enqueue(byte[] png,String name,long now,BooleanSupplier captureAllowed) throws Exception {
        return enqueue(png,name,Wire.id(),now,now,captureAllowed);
    }
    /** Reuse this intent ID and original timestamp after a failed local save; never extend retention. */
    public synchronized String enqueue(byte[] png,String name,String id,long created,long now,BooleanSupplier captureAllowed) throws Exception {
        check(captureAllowed); Wire.require(state.has("pair") && Wire.isId(id));
        Wire.require(created>0 && created<=Long.MAX_VALUE-Wire.LIFETIME && created+Wire.LIFETIME>now && created<=now+300000);
        JSONObject existing=find(state.getJSONArray("history"),id);
        if(existing!=null){ImageWire.verifyImage(png,existing);return id;}
        prune(now); capacity(state);
        long seq=state.getLong("seq")+1;Wire.require(seq>0);JSONObject pair=state.getJSONObject("pair");
        JSONObject r=ImageWire.manifest(png,pair,id,state.getString("device"),name,seq,created,state.getJSONObject("clock"));
        ImageWire.verifyImage(png,r);validator.validate(png,r);check(captureAllowed);
        files.reserve(png.length+28L*r.getInt("chunks"));
        boolean committed=false;
        try {
            for(int i=0;i<r.getInt("chunks");i++){check(captureAllowed);byte[] chunk=Arrays.copyOfRange(png,i*ImageWire.CHUNK_SIZE,i*ImageWire.CHUNK_SIZE+ImageWire.chunkLength(r,i));try{files.write(id,i,ImageWire.sealChunk(chunk,r,i,pair));}finally{Arrays.fill(chunk,(byte)0);}}
            check(captureAllowed);JSONObject next=Wire.cloneJson(state);next.put("seq",seq);next.getJSONArray("history").put(r);next.getJSONArray("pending").put(id);commit(next);committed=true;return id;
        } finally {if(!committed)files.remove(id);}
    }
    public synchronized byte[] image(String id,long now) throws Exception {
        JSONObject r=find(state.getJSONArray("history"),id);Wire.require(r!=null&&r.getLong("expires")>now);return readImage(r,state.getJSONObject("pair"),()->true);
    }
    public synchronized JSONObject record(String id,long now) throws Exception {JSONObject r=find(state.getJSONArray("history"),id);Wire.require(r!=null&&r.getLong("expires")>now);return Wire.cloneJson(r);}
    private byte[] readImage(JSONObject r,JSONObject pair,BooleanSupplier allowed) throws Exception {
        ByteArrayOutputStream out=new ByteArrayOutputStream(r.getInt("byteCount"));
        for(int i=0;i<r.getInt("chunks");i++){check(allowed);byte[] chunk=ImageWire.openChunk(files.read(r.getString("id"),i,ImageWire.chunkLength(r,i)+28),r,i,pair);try{out.write(chunk);}finally{Arrays.fill(chunk,(byte)0);}}
        byte[] png=out.toByteArray();try{ImageWire.verifyImage(png,r);check(allowed);return png;}catch(Exception e){Arrays.fill(png,(byte)0);throw e;}
    }
    public Result poll(Store remote,long now,BooleanSupplier externalAllowed) throws Exception {
        synchronized(pollLock){
            Result result=new Result();final JSONObject initial,pair;final long token,previous;
            synchronized(this){if(!state.has("pair"))return result;prune(now);initial=Wire.cloneJson(state);pair=initial.getJSONObject("pair");token=generation;previous=lastScan;lastScan=0;}
            BooleanSupplier allowed=()->externalAllowed.getAsBoolean()&&currentGeneration(token);
            GuardedStore store=new GuardedStore(remote,allowed);String root=ImageWire.root(pair);List<JSONObject> fresh=new ArrayList<>();
            try {
                store.check();Wire.verify(store,pair);store.imageDirectory(root);
                JSONArray queue=initial.getJSONArray("pending");
                for(int n=0;n<Math.min(2,queue.length());n++){
                    store.check();String id=queue.getString(n);JSONObject r=find(initial.getJSONArray("history"),id);if(r==null)continue;
                    try{
                        for(int i=0;i<r.getInt("chunks");i++){store.check();byte[] encrypted=files.read(id,i,ImageWire.chunkLength(r,i)+28);byte[] plain=ImageWire.openChunk(encrypted,r,i,pair);Arrays.fill(plain,(byte)0);store.atomic(root+ImageWire.chunkName(id,i),encrypted);}
                        store.atomic(root+id+".img",ImageWire.sealManifest(r,pair));
                        synchronized(this){store.check();JSONObject next=Wire.cloneJson(state);next.put("pending",without(next.getJSONArray("pending"),id,true));commit(next);result.uploaded++;}
                    }catch(GuardedStore.Stopped e){throw e;}catch(Exception e){result.failures++;}
                }
                List<String> names=store.list(root);Wire.require(names.size()<=25000);Collections.sort(names);int manifests=0, receiveAttempts=0;boolean deferredFresh=false;Set<String> freshSources=new HashSet<>();
                JSONArray retained=initial.getJSONArray("history");for(int n=0;n<retained.length();n++){JSONObject old=retained.getJSONObject(n);if(!old.getString("device").equals(initial.getString("device"))&&now>=old.getLong("created")&&now-old.getLong("created")<=10000)freshSources.add(old.getString("device"));}
                int start=names.isEmpty()?0:scanCursor%names.size();
                for(int visited=0;visited<names.size();visited++){
                    int position=(start+visited)%names.size();String name=names.get(position);scanCursor=(position+1)%names.size();
                    store.check();if(!name.matches("[0-9a-f-]{36}\\.img"))continue;String id=name.substring(0,36);if(!Wire.isId(id))continue;
                    synchronized(this){if(find(state.getJSONArray("history"),id)!=null)continue;}
                    if(++manifests>1000){scanCursor=position;result.deferred=true;break;}
                    JSONObject r;
                    try{
                        r=ImageWire.openManifest(store.read(root+name,ImageWire.MAX_ENVELOPE),pair,id);
                        if(r.getLong("expires")<=now){try{store.delete(root+name);for(int i=0;i<r.getInt("chunks");i++)store.delete(root+ImageWire.chunkName(id,i));}catch(GuardedStore.Stopped e){throw e;}catch(Exception e){result.cleanupFailures++;}continue;}
                        if(r.getLong("created")>now+300000){result.futureRecords++;continue;}
                        boolean recent=!r.getString("device").equals(initial.getString("device"))&&now>=r.getLong("created")&&now-r.getLong("created")<=10000;
                        if(recent)freshSources.add(r.getString("device"));
                        if(receiveAttempts>=2){result.deferred=true;if(recent)deferredFresh=true;continue;}
                        receiveAttempts++;
                        synchronized(this){
                            store.check();if(find(state.getJSONArray("history"),id)!=null)continue;
                            JSONObject cached=find(state.getJSONArray("inbox"),id);
                            if(cached!=null)Wire.require(cached.toString().equals(r.toString()));
                            else {capacity(state);files.reserve(r.getLong("byteCount")+28L*r.getInt("chunks"));JSONObject next=Wire.cloneJson(state);next.getJSONArray("inbox").put(r);commit(next);}
                        }
                        for(int i=0;i<r.getInt("chunks");i++){
                            store.check();boolean valid=false;
                            try{byte[] plain=ImageWire.openChunk(files.read(id,i,ImageWire.chunkLength(r,i)+28),r,i,pair);Arrays.fill(plain,(byte)0);valid=true;}catch(Exception ignored){}
                            if(!valid){byte[] encrypted=store.read(root+ImageWire.chunkName(id,i),ImageWire.chunkLength(r,i)+28);byte[] plain=ImageWire.openChunk(encrypted,r,i,pair);Arrays.fill(plain,(byte)0);store.check();synchronized(this){store.check();files.write(id,i,encrypted);}}
                        }
                        byte[] png=readImage(r,pair,allowed);try{validator.validate(png,r);}finally{Arrays.fill(png,(byte)0);}store.check();
                        synchronized(this){
                            store.check();JSONObject next=Wire.cloneJson(state);if(find(next.getJSONArray("history"),id)!=null)continue;
                            next.put("inbox",without(next.getJSONArray("inbox"),id,false));next.getJSONArray("history").put(r);JSONObject clock=next.getJSONObject("clock");String device=r.getString("device");long old=clock.optLong(device);
                            if(clock.has(device)||clock.length()<100)clock.put(device,Math.max(old,r.getLong("seq")));
                            commit(next);result.received++;
                            if(!device.equals(next.getString("device"))&&r.getLong("seq")>old&&now>=r.getLong("created")&&now-r.getLong("created")<=10000)fresh.add(r);
                        }
                    }catch(GuardedStore.Stopped e){throw e;}catch(Exception e){result.failures++;}
                }
                synchronized(this){store.check();if(result.failures==0&&result.futureRecords==0){lastScan=now;if(previous>0&&now>=previous&&now-previous<6000&&!deferredFresh&&!result.deferred){Set<String> sources=new HashSet<>(freshSources);JSONObject newest=null;for(JSONObject r:fresh){sources.add(r.getString("device"));if(newest==null||r.getLong("seq")>newest.getLong("seq"))newest=r;}if(sources.size()==1&&newest!=null&&newest.getJSONObject("observed").optLong(state.getString("device"))>=state.getLong("seq"))result.automatic=Wire.cloneJson(newest);}}}
            }catch(GuardedStore.Stopped e){result.paused=true;}catch(Exception e){result.failures++;}
            return result;
        }
    }
    private synchronized boolean currentGeneration(long token){return token==generation;}
}
