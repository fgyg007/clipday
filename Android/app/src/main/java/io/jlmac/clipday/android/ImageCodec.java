package io.jlmac.clipday.android;

import android.content.ContentResolver;
import android.graphics.*;
import android.net.Uri;
import java.io.*;
import java.util.Arrays;
import java.util.function.BooleanSupplier;
import org.json.JSONObject;
import io.jlmac.clipday.core.*;

/** Memory-only normalization. No file URI, HTML, animation or arbitrary file handling. */
final class ImageCodec {
    static void validate(byte[] png, JSONObject r) throws Exception {
        ImageWire.verifyImage(png,r);
        BitmapFactory.Options bounds=new BitmapFactory.Options();bounds.inJustDecodeBounds=true;BitmapFactory.decodeByteArray(png,0,png.length,bounds);
        Wire.require(bounds.outWidth==r.getInt("width")&&bounds.outHeight==r.getInt("height")&&"image/png".equals(bounds.outMimeType));
        Bitmap bitmap=null;
        try { bitmap=BitmapFactory.decodeByteArray(png,0,png.length);Wire.require(bitmap!=null&&bitmap.getWidth()==bounds.outWidth&&bitmap.getHeight()==bounds.outHeight); }
        catch(OutOfMemoryError e){throw new Wire.UserError("手机内存不足，图片保留待重试。");}
        finally{if(bitmap!=null)bitmap.recycle();}
    }
    static byte[] capture(ContentResolver resolver,Uri uri,BooleanSupplier allowed) throws Exception {
        Wire.require("content".equals(uri.getScheme()));
        if(!allowed.getAsBoolean())throw new GuardedStore.Stopped();String type=resolver.getType(uri);
        Wire.require("image/png".equals(type)||"image/jpeg".equals(type));
        byte[] encoded;
        try(InputStream in=resolver.openInputStream(uri);ByteArrayOutputStream out=new ByteArrayOutputStream()){
            Wire.require(in!=null);byte[] buffer=new byte[8192];int n;
            while((n=in.read(buffer))!=-1){if(!allowed.getAsBoolean())throw new GuardedStore.Stopped();Wire.require(out.size()+n<=ImageWire.MAX_BYTES);out.write(buffer,0,n);}encoded=out.toByteArray();
        }
        Bitmap bitmap=null;
        try {
            if("image/png".equals(type))ImageWire.pngDimensions(encoded);
            else Wire.require(encoded.length>=3&&(encoded[0]&255)==255&&(encoded[1]&255)==216&&(encoded[2]&255)==255);
            BitmapFactory.Options bounds=new BitmapFactory.Options();bounds.inJustDecodeBounds=true;BitmapFactory.decodeByteArray(encoded,0,encoded.length,bounds);
            Wire.require(type.equals(bounds.outMimeType)&&bounds.outWidth>0&&bounds.outHeight>0&&bounds.outWidth<=8192&&bounds.outHeight<=8192&&(long)bounds.outWidth*bounds.outHeight<=ImageWire.MAX_PIXELS);
            if(!allowed.getAsBoolean())throw new GuardedStore.Stopped();bitmap=BitmapFactory.decodeByteArray(encoded,0,encoded.length);Wire.require(bitmap!=null);
            ByteArrayOutputStream out=new ByteArrayOutputStream(){@Override public synchronized void write(byte[] b,int off,int len){if(count+len>ImageWire.MAX_BYTES)throw new IllegalArgumentException("PNG too large");super.write(b,off,len);}@Override public synchronized void write(int b){if(count>=ImageWire.MAX_BYTES)throw new IllegalArgumentException("PNG too large");super.write(b);}};
            Wire.require(bitmap.compress(Bitmap.CompressFormat.PNG,100,out));if(!allowed.getAsBoolean())throw new GuardedStore.Stopped();byte[] png=out.toByteArray();ImageWire.pngDimensions(png);return png;
        }catch(OutOfMemoryError e){throw new Wire.UserError("手机内存不足，未保存图片。");}
        finally{Arrays.fill(encoded,(byte)0);if(bitmap!=null)bitmap.recycle();}
    }
}
