package io.jlmac.clipday.core;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Collectors;
public final class LocalStore implements Store {
    private final Path root;
    public LocalStore(Path root) { this.root = root; }
    private Path path(String value) throws Exception { NasConfig.safePath(value); return root.resolve(value); }
    public byte[] read(String file, int limit) throws Exception { Path p = path(file); Wire.require(!Files.isSymbolicLink(p) && Files.size(p) <= limit); return Files.readAllBytes(p); }
    public boolean exists(String file) throws Exception { return Files.exists(path(file)); }
    public List<String> list(String dir) throws Exception { try (var files = Files.list(path(dir))) { return files.map(p -> p.getFileName().toString()).collect(Collectors.toList()); } }
    public void create(String file, byte[] data) throws Exception { Files.write(path(file), data, StandardOpenOption.CREATE_NEW); }
    public void atomic(String file, byte[] data) throws Exception { Path temp = path(file + ".tmp"); Files.write(temp, data); Files.move(temp, path(file), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE); }
    public void delete(String file) throws Exception { Files.deleteIfExists(path(file)); }
    public void imageDirectory(String dir) throws Exception { Files.createDirectories(path(dir)); }
    public void close() { }
}
