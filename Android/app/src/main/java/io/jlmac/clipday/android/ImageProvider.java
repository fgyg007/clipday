package io.jlmac.clipday.android;

import android.content.*;
import android.content.res.AssetFileDescriptor;
import android.database.*;
import android.net.Uri;
import android.os.*;
import android.provider.OpenableColumns;
import java.io.*;
import java.util.*;
import org.json.JSONObject;
import io.jlmac.clipday.core.Wire;

/** Non-exported provider: Android clipboard grants only the exact image URI for read access. */
public final class ImageProvider extends ContentProvider {
    static final String AUTHORITY="io.jlmac.clipday.android.images";
    static Uri uri(String id){return new Uri.Builder().scheme("content").authority(AUTHORITY).appendPath("image").appendPath(id).build();}
    private String id(Uri uri) throws FileNotFoundException {
        List<String> p=uri.getPathSegments();
        if(!"content".equals(uri.getScheme())||!AUTHORITY.equals(uri.getAuthority())||uri.getQuery()!=null||uri.getFragment()!=null||p.size()!=2||!"image".equals(p.get(0))||!Wire.isId(p.get(1)))throw new FileNotFoundException("Unknown image");
        return p.get(1);
    }
    private ClipDayApp app(){return (ClipDayApp)getContext().getApplicationContext();}
    private JSONObject record(Uri uri)throws FileNotFoundException{try{if(!app().ready||app().privacyPaused)throw new IOException();return app().imageRecord(id(uri));}catch(Exception e){throw new FileNotFoundException("Image unavailable or expired");}}
    @Override public boolean onCreate(){return true;}
    @Override public String getType(Uri uri){try{id(uri);return "image/png";}catch(Exception e){return null;}}
    @Override public String[] getStreamTypes(Uri uri,String filter){return ClipDescription.compareMimeTypes("image/png",filter)&&getType(uri)!=null?new String[]{"image/png"}:null;}
    @Override public ParcelFileDescriptor openFile(Uri uri,String mode)throws FileNotFoundException{
        if(!"r".equals(mode))throw new FileNotFoundException("Read only");JSONObject r=record(uri);final String imageId=id(uri);
        return openPipeHelper(uri,"image/png",null,r,(pipe,u,m,o,manifest)->{
            byte[] png=null;
            try(OutputStream out=new ParcelFileDescriptor.AutoCloseOutputStream(pipe)){
                png=app().imageBytes(imageId);
                for(int offset=0;offset<png.length;offset+=8192){if(app().privacyPaused||manifest.optLong("expires")<=System.currentTimeMillis())break;out.write(png,offset,Math.min(8192,png.length-offset));}
            }catch(Exception ignored){}finally{if(png!=null)Arrays.fill(png,(byte)0);}
        });
    }
    @Override public AssetFileDescriptor openTypedAssetFile(Uri uri,String filter,Bundle opts)throws FileNotFoundException{
        if(!ClipDescription.compareMimeTypes("image/png",filter))throw new FileNotFoundException("PNG only");return new AssetFileDescriptor(openFile(uri,"r"),0,AssetFileDescriptor.UNKNOWN_LENGTH);
    }
    @Override public Cursor query(Uri uri,String[] projection,String selection,String[] args,String sort){
        try{JSONObject r=record(uri);String[] cols=projection==null?new String[]{OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE}:projection;MatrixCursor cursor=new MatrixCursor(cols);Object[] values=new Object[cols.length];for(int i=0;i<cols.length;i++){if(OpenableColumns.DISPLAY_NAME.equals(cols[i]))values[i]="clipboard.png";if(OpenableColumns.SIZE.equals(cols[i]))values[i]=r.optLong("byteCount");}cursor.addRow(values);return cursor;}catch(Exception e){return null;}
    }
    @Override public Uri insert(Uri uri,ContentValues values){throw new UnsupportedOperationException("Read only");}
    @Override public int update(Uri uri,ContentValues values,String selection,String[] args){throw new UnsupportedOperationException("Read only");}
    @Override public int delete(Uri uri,String selection,String[] args){throw new UnsupportedOperationException("Read only");}
}
