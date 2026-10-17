package io.jlmac.clipday.core;

import java.util.Arrays;

/** Uses a unique, content-free probe under ClipDaySync; never creates or replaces a sync space. */
public final class ConnectionDiagnostics {
    private ConnectionDiagnostics() { }
    public static void check(Store store) throws Exception {
        try {
            if (!store.exists("ClipDaySync")) throw new Wire.UserError("NAS 已连通，但此文件夹还没有同步空间。请先在电脑端创建空间，再显示配对码让手机加入；不要另建第二个空间。");
            store.list("ClipDaySync/");
        } catch (GuardedStore.Stopped e) { throw e; }
        catch (Wire.UserError e) { throw e; }
        catch (Exception e) { throw new Wire.UserError("NAS 已连通，但同步目录无法读取。请检查共享、子文件夹和读取权限。"); }
        String path = "ClipDaySync/.connection-check-" + Wire.id() + ".tmp";
        byte[] probe = Wire.utf8("ClipDay connection check");
        boolean cleaned = false;
        try {
            try { store.atomic(path, probe); }
            catch (GuardedStore.Stopped e) { throw e; }
            catch (Exception e) { throw new Wire.UserError("同步目录可读取，但写入或重命名失败。请允许创建、写入和重命名文件。"); }
            try { if (!Arrays.equals(probe, store.read(path, 128))) throw new Exception(); }
            catch (GuardedStore.Stopped e) { throw e; }
            catch (Exception e) { throw new Wire.UserError("测试文件已写入，但无法正确读回。请检查 NAS 读取权限后重试。"); }
            try { store.delete(path); cleaned = true; }
            catch (GuardedStore.Stopped e) { throw e; }
            catch (Exception e) { throw new Wire.UserError("同步目录可读写，但测试文件无法删除。请检查删除权限；目录可能留有 .connection-check 测试文件。"); }
        } finally {
            if (!cleaned) try { store.delete(path); } catch (Exception ignored) { }
        }
    }
}
