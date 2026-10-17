# Windows automatic image sync: verification notes

This is an unreleased implementation. The implementation environment has no .NET SDK or Windows clipboard/GDI, so the C# tests below and OS behavior have **not** been executed here. Tree-sitter syntax parsing and `git diff --check` passed; neither establishes compilation or runtime correctness.

## Automated verification on a .NET 10 runner

- `dotnet run --project Windows/ClipDay.Sync.Tests -- images`
- `dotnet run --project Windows/ClipDay.Sync.Tests`
- `dotnet build Windows/ClipDay.Cloud`

The image suite consumes `Tests/Fixtures/image-v1.json` and covers shared AES-GCM/AAD vectors, SHA-256 and PNG container validation, bad indices/identities/lengths, animation and compressed metadata rejection, privacy callback invalidation, original retention, durable queue retries, corruption isolation, separate causal clocks, partial chunks, pending-safe history clearing, the 100-record cap, a rotating 1,001-manifest scan, and a single newest cross-type clipboard decision. Native decoder validation is deliberately injected as a no-op in portable protocol tests; Windows-specific tests below are still required.

## Windows/manual acceptance gates

1. Copy screenshots/bitmaps from Snipping Tool, Paint, browsers, and common chat applications. Verify automatic protected local history, NAS upload and receiving image clipboard, with no manual send step. Test PNG-only and DIB/DIBV5 clipboard formats, transparency, Unicode device names, and the supplied 2×2 fixture.
2. Copy text then image, and image then text, between two polling ticks. Only the newest fresh item from that source should become the remote clipboard. Both must remain in history. Try simultaneous unrelated devices; conflicts must remain history-only.
3. Change local clipboard during a slow receive. Switch text/image, click history copy, then enter privacy pause. A late result must not overwrite the clipboard, create a copy loop, or start another transfer step. Resume must ignore changes made during the private interval.
4. Sync-only pause must continue local bitmap history without later sending captures made while paused. Existing queued images remain durable. Test shutdown/restart with pending uploads and disconnected NAS, and verify original 24-hour expiry.
5. Interrupt after one chunk and before manifest publication; retry the same ID. Delete/corrupt a chunk before receipt: no usable history or clipboard until complete validation succeeds. No plaintext PNG files should appear under application storage or temporary directories.
6. Test >20 MiB encoded images, >8192 edge, >16,777,216 pixels, APNG, compressed PNG metadata and embedded-profile/compressed DIB. Unsupported sources should be skipped safely. Test clipboard changing while capture is active. Native reads inspect and copy the same open clipboard snapshot.
7. Fill the 100-record/200 MiB combined encrypted image history/outbox budget. New additions must fail visibly, not evict pending data. Clear history with pending items: hidden pending payloads remain until successful upload/expiry.
8. Corrupt one local payload and one metadata file among healthy items, then restart. Healthy history must still load; corrupted pending data must not be silently deleted. Test preview/copy and expiry while sync is paused.
9. Test UNC/reparse-point paths, corrupt NAS manifests, >1,000 candidates and missing/offline shares. Text must still get a turn before each image pass. The image-specific failure must not disable successful text synchronization.

## Storage/compatibility behavior

- `images-v1` is separate from text. Old clients ignore it. Windows stores one AES-GCM protected local PNG copy for both image history and outbox; the installation key is DPAPI protected for the current Windows user.
- Local history/queue are jointly limited to 200 MiB and 100 records. Corrupt records remain on disk for recovery/inspection and still consume capacity; pending records are not silently discarded.
- File drops, arbitrary files, ZIP, SVG, HTML and animated images are not automatic image uploads. PNG source images with compressed metadata are rejected, not silently decoded; normalized native bitmaps have no such metadata.
- An interrupted manifest-last upload can leave NAS chunks without a manifest. Unknown orphan chunks are conservatively retained because their authenticated creation/expiry cannot be established. Authenticated expired manifests and their owned chunks are removed on a connected active pass. NAS backups/snapshots are outside this retention guarantee.
- Native clipboard synthesis, GDI decoding, preview rendering and actual device interoperability remain unverified until tested on Windows and other real target clients.
