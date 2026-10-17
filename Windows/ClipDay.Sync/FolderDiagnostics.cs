namespace ClipDay.Sync;

public record FolderDiagnostic(bool Reachable, bool Readable, bool Writable, string Message)
{
    public bool Success => Reachable && Readable && Writable;
}

public static class FolderDiagnostics
{
    // Probe only the selected existing directory. Never create a missing NAS mount or touch sync data.
    public static FolderDiagnostic Check(string folder)
    {
        if (!Directory.Exists(folder)) return new(false, false, false, "路径不可访问：请先在文件资源管理器打开 NAS 共享，并确认共享路径或映射盘已连接。");
        try
        {
            using var entries = Directory.EnumerateFileSystemEntries(folder).GetEnumerator();
            _ = entries.MoveNext();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return new(true, false, false, "路径可访问，但无法读取：请检查当前 Windows 用户的共享目录读取权限。");
        }
        var probe = Path.Combine(folder, ".clipday-check-" + Guid.NewGuid().ToString("N") + ".tmp");
        var renamed = probe + ".renamed";
        string? owned = null;
        try
        {
            using (var file = new FileStream(probe, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
            {
                owned = probe;
                file.WriteByte(0x43); file.Flush(true);
            }
            File.Move(probe, renamed); owned = renamed;
            if (File.ReadAllBytes(renamed) is not [0x43]) throw new IOException("Probe read-back failed.");
            File.Delete(renamed); owned = null;
            return new(true, true, true, "本机路径可访问 · 可读取 · 可写入；还需另一台设备连接同一共享文件夹。");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return new(true, true, false, "目录可读取，但写入、重命名、读回或删除检测失败：请检查共享目录写入权限、磁盘空间和 NAS 连接。");
        }
        finally
        {
            if (owned != null) { try { File.Delete(owned); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { } }
        }
    }
}
