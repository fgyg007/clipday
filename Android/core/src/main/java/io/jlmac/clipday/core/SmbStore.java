package io.jlmac.clipday.core;

import com.hierynomus.smbj.*;
import com.hierynomus.smbj.connection.Connection;
import com.hierynomus.smbj.session.Session;
import com.hierynomus.smbj.auth.AuthenticationContext;
import com.hierynomus.smbj.share.*;
import com.hierynomus.msdtyp.AccessMask;
import com.hierynomus.msfscc.FileAttributes;
import com.hierynomus.msfscc.fileinformation.*;
import com.hierynomus.mssmb2.*;
import com.hierynomus.security.bc.BCSecurityProvider;
import java.io.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;

public final class SmbStore implements Store {
    private SMBClient client;
    private Connection connection;
    private Session session;
    private DiskShare share;
    private final String prefix;
    private BooleanSupplier networkAllowed;
    public SmbStore(NasConfig config) throws Exception { this(config, () -> true); }
    public SmbStore(NasConfig config, BooleanSupplier allowed) throws Exception {
        networkAllowed = allowed;
        prefix = config.folder.isEmpty() ? "" : config.folder.replace('/', '\\') + "\\";
        try {
            client = new SMBClient(SmbConfig.builder().withSecurityProvider(new BCSecurityProvider())
                .withTimeout(8, TimeUnit.SECONDS).withSoTimeout(8, TimeUnit.SECONDS).build());
            check(allowed); connection = client.connect(config.host, config.port); check(allowed);
            char[] password = config.password.toCharArray();
            try { session = connection.authenticate(new AuthenticationContext(config.username, password, config.domain)); }
            finally { Arrays.fill(password, '\0'); }
            check(allowed); share = (DiskShare) session.connectShare(config.share); check(allowed);
            if (!config.folder.isEmpty() && !share.folderExists(config.folder.replace('/', '\\'))) throw new Wire.UserError("NAS 子文件夹不存在，请与电脑端选择同一目录。");
            check(allowed);
        } catch (Exception e) { close(); throw e; }
    }
    private static void check(BooleanSupplier allowed) throws GuardedStore.Stopped { if (!allowed.getAsBoolean()) throw new GuardedStore.Stopped(); }
    /** Rebound by the single network worker for each new sync generation. */
    public void setNetworkAllowed(BooleanSupplier allowed) { networkAllowed = allowed; }
    private void check() throws GuardedStore.Stopped { check(networkAllowed); }
    private String path(String path) throws Exception {
        NasConfig.safePath(path); String value = prefix + path.replace('/', '\\');
        if (path.contains("/images-v1")) {
            // Check every parent component, including the selected NAS subfolder. Opening
            // the leaf with FILE_OPEN_REPARSE_POINT alone would still follow parent links.
            int end = value.lastIndexOf('\\');
            if (end >= 0) {
                String parent = value.substring(0, end), current = "";
                for (String component : parent.split("\\\\")) {
                    if (component.isEmpty()) continue;
                    current = current.isEmpty() ? component : current + "\\" + component; check();
                    try (Directory directory = share.openDirectory(current, EnumSet.of(AccessMask.GENERIC_READ), null, SMB2ShareAccess.ALL,
                        SMB2CreateDisposition.FILE_OPEN, EnumSet.of(SMB2CreateOptions.FILE_DIRECTORY_FILE, SMB2CreateOptions.FILE_OPEN_REPARSE_POINT))) {
                        check(); Wire.require((directory.getFileInformation().getBasicInformation().getFileAttributes() & FileAttributes.FILE_ATTRIBUTE_REPARSE_POINT.getValue()) == 0);
                    }
                }
            }
        }
        return value;
    }
    @Override public byte[] read(String path, int limit) throws Exception {
        check();
        try (com.hierynomus.smbj.share.File file = share.openFile(path(path), EnumSet.of(AccessMask.GENERIC_READ), null,
                SMB2ShareAccess.ALL, SMB2CreateDisposition.FILE_OPEN, EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE, SMB2CreateOptions.FILE_OPEN_REPARSE_POINT))) {
            check(); FileAllInformation info = file.getFileInformation(); check();
            Wire.require((info.getBasicInformation().getFileAttributes() & FileAttributes.FILE_ATTRIBUTE_REPARSE_POINT.getValue()) == 0 && info.getStandardInformation().getEndOfFile() <= limit);
            try (InputStream in = file.getInputStream(); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[8192]; int n;
                while (true) { check(); n = in.read(buffer); check(); if (n == -1) break; Wire.require(out.size() + n <= limit); out.write(buffer, 0, n); }
                return out.toByteArray();
            }
        }
    }
    @Override public boolean exists(String path) throws Exception {
        check(); String p = path(path); boolean file = share.fileExists(p); check();
        if (file) return true; boolean folder = share.folderExists(p); check(); return folder;
    }
    @Override public List<String> list(String path) throws Exception {
        check();
        List<String> names = new ArrayList<>();
        // Use the iterator so a huge directory is bounded before retaining every entry.
        try (Directory dir = share.openDirectory(path(path), EnumSet.of(AccessMask.GENERIC_READ), null, SMB2ShareAccess.ALL,
            SMB2CreateDisposition.FILE_OPEN, EnumSet.of(SMB2CreateOptions.FILE_DIRECTORY_FILE, SMB2CreateOptions.FILE_OPEN_REPARSE_POINT))) {
            Wire.require((dir.getFileInformation().getBasicInformation().getFileAttributes() & FileAttributes.FILE_ATTRIBUTE_REPARSE_POINT.getValue()) == 0);
            Iterator<FileIdBothDirectoryInformation> entries = dir.iterator();
            int scanned = 0;
            while (true) {
                check(); if (!entries.hasNext()) break;
                Wire.require(++scanned <= 25000); check(); FileIdBothDirectoryInformation f = entries.next(); check();
                if (f.getFileName().equals(".") || f.getFileName().equals("..")) continue;
                if (names.size() >= 25000) throw new Wire.UserError("同步空间文件过多，请先在电脑端整理。");
                if ((f.getFileAttributes() & (FileAttributes.FILE_ATTRIBUTE_DIRECTORY.getValue() | FileAttributes.FILE_ATTRIBUTE_REPARSE_POINT.getValue())) == 0) names.add(f.getFileName());
            }
        }
        return names;
    }
    private void writeNew(String path, byte[] data, String target) throws Exception {
        check();
        try (com.hierynomus.smbj.share.File file = share.openFile(path(path), EnumSet.of(AccessMask.GENERIC_WRITE, AccessMask.DELETE),
            EnumSet.of(FileAttributes.FILE_ATTRIBUTE_NORMAL), EnumSet.noneOf(SMB2ShareAccess.class), SMB2CreateDisposition.FILE_CREATE,
            EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE))) {
            check();
            try (OutputStream out = file.getOutputStream()) { check(); out.write(data); check(); out.flush(); }
            check(); file.flush(); check();
            if (target != null) { file.rename(path(target), true); check(); }
        }
    }
    @Override public void create(String path, byte[] data) throws Exception { writeNew(path, data, null); }
    @Override public void atomic(String path, byte[] data) throws Exception {
        String temp = path + "." + Wire.id() + ".tmp";
        try { writeNew(temp, data, path); } finally { try { delete(temp); } catch (Exception ignored) { } }
    }
    @Override public void delete(String path) throws Exception { check(); String p = path(path); boolean exists = share.fileExists(p); check(); if (exists) { share.rm(p); check(); } }
    @Override public void imageDirectory(String value) throws Exception {
        Wire.require(value.matches("ClipDaySync/[0-9a-f-]{36}/images-v1/"));
        String space = value.substring("ClipDaySync/".length(), "ClipDaySync/".length()+36); Wire.require(Wire.isId(space));
        String parent = "ClipDaySync/" + space;
        // Open each application path without following a reparse point before creating the child.
        for (String component : new String[]{"ClipDaySync", parent}) {
            check();
            try (Directory directory = share.openDirectory(path(component), EnumSet.of(AccessMask.GENERIC_READ), null, SMB2ShareAccess.ALL,
                SMB2CreateDisposition.FILE_OPEN, EnumSet.of(SMB2CreateOptions.FILE_DIRECTORY_FILE, SMB2CreateOptions.FILE_OPEN_REPARSE_POINT))) {
                check(); Wire.require((directory.getFileInformation().getBasicInformation().getFileAttributes() & FileAttributes.FILE_ATTRIBUTE_REPARSE_POINT.getValue()) == 0);
            }
        }
        check();
        try (Directory directory = share.openDirectory(path(value.substring(0,value.length()-1)), EnumSet.of(AccessMask.GENERIC_READ), null, SMB2ShareAccess.ALL,
            SMB2CreateDisposition.FILE_OPEN_IF, EnumSet.of(SMB2CreateOptions.FILE_DIRECTORY_FILE, SMB2CreateOptions.FILE_OPEN_REPARSE_POINT))) {
            check(); Wire.require((directory.getFileInformation().getBasicInformation().getFileAttributes() & FileAttributes.FILE_ATTRIBUTE_REPARSE_POINT.getValue()) == 0);
        }
    }
    @Override public void close() {
        try { if (share != null) share.close(); } catch (Exception ignored) { }
        try { if (session != null) session.close(); } catch (Exception ignored) { }
        try { if (connection != null) connection.close(); } catch (Exception ignored) { }
        try { if (client != null) client.close(); } catch (Exception ignored) { }
    }
}
