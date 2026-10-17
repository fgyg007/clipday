package io.jlmac.clipday.core;

import java.io.Closeable;
import java.util.List;

/** Paths are relative to the user-selected pre-existing NAS folder. */
public interface Store extends Closeable {
    byte[] read(String path, int limit) throws Exception;
    boolean exists(String path) throws Exception;
    List<String> list(String path) throws Exception;
    void create(String path, byte[] data) throws Exception;
    void atomic(String path, byte[] data) throws Exception;
    void delete(String path) throws Exception;
    /** Image v1 uses only its app-owned child directory; legacy adapters fail closed. */
    default void imageDirectory(String path) throws Exception {
        if (!exists(path)) throw new java.io.IOException("Image directory creation is unsupported by this store");
    }
}
