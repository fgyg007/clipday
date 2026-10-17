# Image sync v1 (proposed, unreleased)

Text v1, pairing, space markers, and text causal sequence remain unchanged. Old clients ignore the separate `ClipDaySync/{space}/images-v1/` directory. Images are PNG only: native clients normalize clipboard bitmaps to PNG; arbitrary files, SVG, HTML, animated images, and ZIP are not supported.

## Bounds

- Encoded PNG: 1..20,971,520 bytes (20 MiB).
- Width and height: 1..8192; width × height <= 16,777,216 pixels. Validate PNG signature/IHDR and native decoder bounds before decoding. Reject APNG `acTL`, unsupported MIME, malformed or mismatching dimensions. Do not trust filenames as MIME. Wire PNG must not contain `iCCP`, `zTXt`, or `iTXt`: receivers reject these before invoking native decoders to avoid unbounded expanded metadata. Senders may strip these ancillary chunks structurally before decode/encoding/hash, or reject the source; strip them from encoder output as necessary. Validate CRCs and bounded chunk structure. APNG is always rejected, not silently flattened.
- Chunk size: 1,048,576 bytes; 1..20 chunks. Last chunk is exact remainder.
- Manifest plaintext <= 32,768 bytes, encrypted envelope <= 32,796 bytes.
- Local encrypted image staging (outbox plus inbox) is bounded to 200 MiB and 100 records. The platform history is separately bounded to 200 MiB and 100 image records, so staging and history may temporarily hold two bounded copies. Reject additions when full; never silently evict pending images. Prune expired data first. Retention is original created + 86,400,000 ms, never extended by retry.
- Scan at most 25,000 directory entries; accept at most 1,000 manifests per pass. Device clock map at most 100 lowercase UUID keys.

## Paths and crypto

Flat directory accommodates the existing SMB Store abstraction:
- Manifest `{id}.img`
- Chunks `{id}.{index:03d}.chunk` (zero-based index)

All IDs and space/device fields are canonical lowercase UUIDs. Never use sender-provided filenames or paths. Never follow symlinks/reparse points. The existing 32-byte space key is reused with domain-separated associated data and fresh random 12-byte nonce per encryption. Envelopes are nonce || ciphertext || 16-byte GCM tag, as in text v1.
- Manifest AAD UTF-8: `clipday-image-manifest-v1:{space}`
- Chunk AAD UTF-8: `clipday-image-chunk-v1:{space}:{id}:{index}:{plaintextLength}`

Manifest JSON camelCase fields:
`v:1, kind:"image", id, space, device, name, seq, created, expires, observed, mime:"image/png", width, height, byteCount, chunkSize:1048576, chunks, sha256`

`sha256` is lowercase hex SHA-256 of complete canonical PNG bytes. `name` is source device display name, UTF-8 <=256 bytes. No original filenames. seq positive integer; observed values nonnegative integers. created positive integer; expires exactly created+24h without overflow; future records >5 minutes rejected for retry. Derive chunks and every chunk length from byteCount and fixed chunkSize, not arbitrary input. Validate all fields and authenticated manifest ID matches its filename.

## Transaction and delivery

Save locally durably before upload. Encrypt image chunks locally; no plaintext transient files outside the documented platform history/clipboard interfaces. Publish all chunks atomically first, manifest last. On retry check bounded existing encrypted chunk bytes if feasible; otherwise replace same chunk paths idempotently. An authenticated manifest is not sufficient: receiver checks every chunk, total length, SHA-256, PNG/native bounds before showing usable history or updating clipboard. Missing, corrupt, or paused transfers remain retryable, not seen. Keep pending data until successful upload; late pause can leave same ID pending for idempotent retry.

Images use a separate causal clock/sequence state from text, same stable device identity where available. Automatic clipboard apply follows desktop text semantics: only a continuous recent scan, one fresh source device, observed local image sequence at least current local image sequence, original created within 10 seconds, no local clipboard changes or newer local activity. Initial/catch-up data goes only to history. Shared UI clipboard generation/hold gates must prevent text/image cross-overwrite and copy loops. Privacy pause blocks capture, subsequent transfer steps and late application; sync-only pause preserves local capture. In-flight I/O may finish, never promise recall.

Expired manifests and their owned chunks may be removed when running and connected; no guarantee over NAS backups/snapshots. Manifest-last interrupted upload can leave orphan chunks; only clean app-owned files using age metadata when provably expired (do not delete other devices' fresh uploads). URI clipboard grants on Android are explicitly bounded/read-only and backed by private encrypted storage; content is decrypted for authorized reads, not exported to an unprotected cache.

## Implementation boundaries

Mac keeps the pre-enqueue image intent (space, original ID and creation time) in its existing local history index, then stores transfer chunks encrypted; the pre-existing Mac history remains unencrypted. Windows and Android use one encrypted local image copy shared by queue and history where possible, instead of duplicating payloads. Windows and Android conservatively retain manifest-less NAS chunks when no authenticated expiry/age evidence is available; completed expired manifests allow deletion of their exact owned chunk names. A stopped upload may therefore leave encrypted orphan chunks beyond 24 hours. This does not extend image eligibility and must not be described as guaranteed physical deletion.

Android accepts focused, granted PNG/JPEG content URIs and normalizes to the PNG wire format. Current Android source PNGs containing the prohibited metadata chunks are rejected instead of stripped. Desktop input formats are platform clipboard bitmaps, not file paths. Native platform acceptance is still required for clipboard format conversion and URI grants.
