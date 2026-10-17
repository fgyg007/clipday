package io.jlmac.clipday.core;

import java.util.List;
import java.util.function.BooleanSupplier;

/** Checks privacy/cancellation before each request and before exposing late results. Does not own the connection. */
public final class GuardedStore implements Store {
    public static final class Stopped extends Exception { private static final long serialVersionUID = 1L; }
    private final Store delegate;
    private final BooleanSupplier allowed;
    public GuardedStore(Store delegate, BooleanSupplier allowed) { this.delegate = delegate; this.allowed = allowed; }
    public void check() throws Stopped { if (!allowed.getAsBoolean()) throw new Stopped(); }
    public byte[] read(String path, int limit) throws Exception { check(); byte[] value = delegate.read(path, limit); check(); return value; }
    public boolean exists(String path) throws Exception { check(); boolean value = delegate.exists(path); check(); return value; }
    public List<String> list(String path) throws Exception { check(); List<String> value = delegate.list(path); check(); return value; }
    public void create(String path, byte[] data) throws Exception { check(); delegate.create(path, data); check(); }
    public void atomic(String path, byte[] data) throws Exception { check(); delegate.atomic(path, data); check(); }
    public void delete(String path) throws Exception { check(); delegate.delete(path); check(); }
    public void imageDirectory(String path) throws Exception { check(); delegate.imageDirectory(path); check(); }
    public void close() { }
}
