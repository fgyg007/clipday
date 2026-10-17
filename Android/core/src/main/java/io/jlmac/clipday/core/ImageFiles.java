package io.jlmac.clipday.core;

import java.nio.file.*;
import java.nio.channels.FileChannel;
import java.util.*;

/** Flat, app-owned encrypted chunk cache. Never accepts a sender-supplied path. */
public final class ImageFiles {
    // Leave 4 MiB for the bounded encrypted metadata vault, journals and one atomic chunk write.
    public static final long MAX_BYTES = 196L * 1024 * 1024;
    public interface DirectorySync { void sync(Path directory) throws Exception; }
    private final Path root;
    private final DirectorySync directorySync;
    public ImageFiles(Path directory) throws Exception {
        this(directory, path -> { try (FileChannel channel = FileChannel.open(path, StandardOpenOption.READ)) { channel.force(true); } });
    }
    public ImageFiles(Path directory, DirectorySync directorySync) throws Exception {
        this.directorySync = directorySync;
        root = directory.toAbsolutePath().normalize();
        for (Path p = root; p != null; p = p.getParent()) Wire.require(!Files.isSymbolicLink(p));
        Files.createDirectories(root); Wire.require(Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS));
    }
    private Path path(String id, int index) throws Exception {
        Wire.require(Wire.isId(id) && index >= 0 && index < 20);
        Path p = root.resolve(ImageWire.chunkName(id, index)); Wire.require(!Files.isSymbolicLink(p)); return p;
    }
    public synchronized long bytes() throws Exception {
        long bytes = 0; int entries = 0;
        try (DirectoryStream<Path> stream = Files.newDirectoryStream(root)) {
            for (Path p : stream) {
                Wire.require(++entries <= 25000 && !Files.isSymbolicLink(p));
                Wire.require(Files.isRegularFile(p, LinkOption.NOFOLLOW_LINKS)); bytes += Files.size(p);
                Wire.require(bytes <= MAX_BYTES);
            }
        }
        return bytes;
    }
    public synchronized void reserve(long extra) throws Exception {
        if (extra < 0 || bytes() + extra > MAX_BYTES) throw new Wire.UserError("图片本机存储已满，请等待到期清理后重试；待上传图片不会被丢弃。");
    }
    public synchronized byte[] read(String id, int index, int expected) throws Exception {
        Path p = path(id, index); Wire.require(Files.size(p) == expected && expected <= ImageWire.CHUNK_SIZE + 28);
        byte[] bytes = Files.readAllBytes(p); Wire.require(bytes.length == expected); return bytes;
    }
    public synchronized boolean exists(String id, int index) throws Exception { return Files.isRegularFile(path(id, index), LinkOption.NOFOLLOW_LINKS); }
    public synchronized void write(String id, int index, byte[] encrypted) throws Exception {
        Wire.require(encrypted.length >= 29 && encrypted.length <= ImageWire.CHUNK_SIZE + 28);
        Path target = path(id, index), temp = root.resolve("." + Wire.id() + ".tmp");
        reserve(encrypted.length);
        try {
            try (FileChannel out = FileChannel.open(temp, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
                java.nio.ByteBuffer b = java.nio.ByteBuffer.wrap(encrypted); while (b.hasRemaining()) out.write(b); out.force(true);
            }
            Files.move(temp, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            syncDirectory();
        } finally { Files.deleteIfExists(temp); }
    }
    public synchronized void remove(String id) throws Exception { for (int i = 0; i < 20; i++) Files.deleteIfExists(path(id, i)); syncDirectory(); }
    public synchronized void reconcile(Set<String> retained) throws Exception {
        try (DirectoryStream<Path> stream = Files.newDirectoryStream(root)) {
            int entries = 0;
            for (Path p : stream) {
                Wire.require(++entries <= 25000 && !Files.isSymbolicLink(p)); String n = p.getFileName().toString();
                if (n.matches("\\.[0-9a-f-]{36}\\.tmp")) Files.deleteIfExists(p);
                else if (n.matches("[0-9a-f-]{36}\\.[0-9]{3}\\.chunk") && !retained.contains(n.substring(0,36))) Files.deleteIfExists(p);
            }
        }
        syncDirectory();
    }
    private void syncDirectory() throws Exception {
        directorySync.sync(root);
    }
}
