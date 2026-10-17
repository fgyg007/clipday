using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using ClipDay.Sync;

namespace ClipDay.Cloud;

static class ClipboardImages
{
    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll")] static extern uint EnumClipboardFormats(uint format);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormat(string format);
    [DllImport("gdi32.dll", EntryPoint = "GetObjectW")] static extern int GetObject(IntPtr handle, int size, out NativeBitmap bitmap);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr handle);
    [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr handle);
    [StructLayout(LayoutKind.Sequential)] struct NativeBitmap { public int Type, Width, Height, WidthBytes; public ushort Planes, BitsPixel; public IntPtr Bits; }

    static Bitmap ReadBitmapSnapshot()
    {
        if (!OpenClipboard(IntPtr.Zero)) throw new ExternalException("剪贴板正忙。");
        try
        {
            HashSet<uint> formats = []; uint current = 0;
            while ((current = EnumClipboardFormats(current)) != 0) { if (formats.Count >= 256 || !formats.Add(current)) throw new InvalidDataException(); }
            // Inspect the existing DIB header first. Asking for CF_BITMAP first can make Windows
            // synthesize and allocate a huge bitmap before the application has checked its bounds.
            uint dib = formats.Contains(17) ? 17u : formats.Contains(8) ? 8u : 0u;
            if (dib != 0)
            {
                var handle = GetClipboardData(dib);
                if (handle == IntPtr.Zero || GlobalSize(handle).ToUInt64() < 40) throw new InvalidDataException("无法安全读取此剪贴板图片。");
                IntPtr bits = GlobalLock(handle); if (bits == IntPtr.Zero) throw new InvalidDataException();
                try
                {
                    int header = Marshal.ReadInt32(bits), width = Marshal.ReadInt32(bits, 4), height = Marshal.ReadInt32(bits, 8);
                    if (header is not (40 or 108 or 124) || GlobalSize(handle).ToUInt64() < (ulong)header || height == int.MinValue) throw new InvalidDataException();
                    ImageWire.Dimensions(width, Math.Abs(height));
                    int planes = (ushort)Marshal.ReadInt16(bits, 12), depth = (ushort)Marshal.ReadInt16(bits, 14);
                    if (planes != 1 || depth is not (1 or 4 or 8 or 16 or 24 or 32)) throw new InvalidDataException();
                    if (header == 124 && (Marshal.ReadInt32(bits, 112) != 0 || Marshal.ReadInt32(bits, 116) != 0)) throw new InvalidDataException("不支持带嵌入色彩配置的剪贴板图片。");
                    // BI_RGB and BI_BITFIELDS only; embedded JPEG/PNG could hide dimensions in a DIB wrapper.
                    int compression = Marshal.ReadInt32(bits, 16); if (compression != 0 && compression != 3) throw new InvalidDataException("不支持压缩 DIB 剪贴板图片。");
                }
                finally { GlobalUnlock(handle); }
            }
            if (dib != 0 || formats.Contains(2))
            {
                var handle = GetClipboardData(2);
                if (handle != IntPtr.Zero && GetObject(handle, Marshal.SizeOf<NativeBitmap>(), out var bitmap) != 0)
                {
                    ImageWire.Dimensions(bitmap.Width, bitmap.Height);
                    // Copy from the SAME still-locked snapshot, never a stale IDataObject.
                    return Bitmap.FromHbitmap(handle);
                }
            }
            throw new InvalidDataException("无法安全读取此剪贴板图片。");
        }
        finally { CloseClipboard(); }
    }
    public static bool Contains(IDataObject data) => data.GetDataPresent("PNG", false) || data.GetDataPresent(DataFormats.Bitmap);
    public static byte[] Normalize(IDataObject data)
    {
        // Clipboard PNG is preferred because its dimensions can be checked before decoding.
        if (data.GetDataPresent("PNG", false))
        {
            // Read the standard raw PNG clipboard format directly, with a size bound before copying.
            // Do not invoke generic custom-format deserialization on untrusted clipboard data.
            byte[] bytes;
            if (!OpenClipboard(IntPtr.Zero)) throw new ExternalException("剪贴板正忙。");
            try
            {
                var handle = GetClipboardData(RegisterClipboardFormat("PNG"));
                ulong size = handle == IntPtr.Zero ? 0 : GlobalSize(handle).ToUInt64();
                if (size < 1 || size > ImageWire.MaxBytes) throw new InvalidDataException("图片超过 20 MB 或无法读取。");
                IntPtr memory = GlobalLock(handle); if (memory == IntPtr.Zero) throw new InvalidDataException();
                try { bytes = new byte[(int)size]; Marshal.Copy(memory, bytes, 0, bytes.Length); }
                finally { GlobalUnlock(handle); }
            }
            finally { CloseClipboard(); }
            using var decoded = Decode(bytes); return Encode(decoded);
        }
        using var image = ReadBitmapSnapshot();
        ImageWire.Dimensions(image.Width, image.Height); return Encode(image);
    }
    static byte[] Encode(Image image)
    {
        ImageWire.Dimensions(image.Width, image.Height);
        using var normalized = new Bitmap(image.Width, image.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(normalized)) { graphics.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy; graphics.DrawImage(image, new Rectangle(0, 0, image.Width, image.Height)); }
        using var output = new BoundedPngStream(); normalized.Save(output, ImageFormat.Png);
        byte[] png = output.ToArray(); ImageWire.Png(png); return png;
    }
    public static Bitmap Decode(byte[] png)
    {
        var dimensions = ImageWire.Png(png);
        using var stream = new MemoryStream(png, false); using var source = Image.FromStream(stream, false, true);
        if (source.RawFormat.Guid != ImageFormat.Png.Guid || source.Width != dimensions.Width || source.Height != dimensions.Height) throw new InvalidDataException();
        // Drawing forces decoding while the authenticated byte stream is alive; no lazy stream-backed image escapes.
        var bitmap = new Bitmap(dimensions.Width, dimensions.Height, PixelFormat.Format32bppArgb);
        try { using var g = Graphics.FromImage(bitmap); g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy; g.DrawImage(source, new Rectangle(0, 0, bitmap.Width, bitmap.Height)); return bitmap; }
        catch { bitmap.Dispose(); throw; }
    }
    public static void Validate(byte[] png) { using var bitmap = Decode(png); }
    sealed class BoundedPngStream : MemoryStream
    {
        public override void Write(byte[] buffer, int offset, int count) { if (Position + count > ImageWire.MaxBytes) throw new InvalidDataException("图片超过 20 MB，未记录或同步。"); base.Write(buffer, offset, count); }
        public override void Write(ReadOnlySpan<byte> buffer) { if (Position + buffer.Length > ImageWire.MaxBytes) throw new InvalidDataException("图片超过 20 MB，未记录或同步。"); base.Write(buffer); }
        public override void SetLength(long value) { if (value > ImageWire.MaxBytes) throw new InvalidDataException(); base.SetLength(value); }
    }
}
