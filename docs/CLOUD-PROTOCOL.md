# ClipDay folder sync protocol v1

This preview is implemented independently in `Sources/Sync.swift` (CryptoKit) and `Windows/ClipDay.Sync/Sync.cs` (.NET cryptography). Interop tests exercise both directions.

Android 0.1.0 adds an independent Java implementation in `Android/core`. It uses the same record format and joins desktop SRP invitations, accessing the chosen folder directly over SMB2/3 rather than a mounted filesystem. Java/Swift/C# fixture tests cover both record directions, and Java pairs with the desktop helper over local files and an isolated Samba share. Android never automatically applies received text to the clipboard; copy is a foreground user action. Its encrypted local history, dedupe state, counters and outbox are committed together with Android Keystore protection. See `Android/README.md` for mobile limits and lifecycle behavior.

## Directory and pairing

The user chooses a pre-existing directory. Setup creates `ClipDaySync/<space UUID>/space.json`, `space.check`, and `records/`. Polls require the directory and authenticated space proof to exist; they never recreate a missing mount. `space.json` contains `{"v":1,"space":"lowercase UUID"}`. `space.check` is an encrypted record with ID/device equal to the space ID and text `clipday-space-v1`; it proves key possession, its timestamps are not used for record expiry.

The space credentials remain UTF-8 JSON containing `v` (1), `space` (lowercase UUID), and `key` (base64 of 32 random bytes). Production keys use OS cryptographic RNGs. The old `clipday1:` base64 form is retained only for encrypted local config compatibility and fixtures, not exposed in the pairing UI. Test keys are intentionally public and never used for user data.

## Short pairing protocol v2 (app 0.1.1)

Both platforms use `Windows/ClipDay.Sync/Pairing.cs`: BouncyCastle.Cryptography 2.6.2 SRP-6a with the RFC 5054 3072-bit group and SHA-256. Windows runs it in process; Mac bundles a .NET Native AOT helper. Mac commands and results use private stdin/stdout pipes, never credential-bearing command-line arguments or logs. The UI shows a uniform random six-digit PIN (including leading zeroes), a two-minute countdown, and a regenerate action; pairing never writes to the clipboard.

Rendezvous files live under `ClipDaySync/Pairing-v2/`. One `active.json` offer contains version 2, an invitation UUID, a fresh round UUID, expiry in Unix milliseconds, a random 32-byte salt, and SRP server public B. Neither the PIN, SRP verifier, nor plaintext space key is stored on the NAS. A shared `active.lock` serializes cooperating hosts; another unexpired invitation cannot be replaced. Identity is UTF-8 `clipday-pair-v2:<invitation UUID>:<round UUID>`.

The joining device reads the offer and reserves `<round UUID>.request` with exclusive creation. It sends SRP public A and client evidence M1, bound to the invitation and round. The host verifies M1; a failed attempt gets an error response and a new salt, server ephemeral and round identity. The same displayed PIN expires after two minutes, cancellation, five incorrect attempts, or successful authentication. Regeneration first cancels the previous host; it never silently extends the previous PIN's lifetime.

On success, the host consumes the invitation before releasing `<round UUID>.response`. It sends server evidence M2 and the encrypted space credentials: AES-256-GCM, a fresh 12-byte nonce and 16-byte tag, with the round identity as AAD. The wrapping key is SHA-256 of Bouncy Castle's SRP session key in unsigned big-endian bytes. The joining device verifies M2 before decrypting, validates credentials and expiry, then verifies the existing space proof during activation. A response cannot authorize a different round. PIN guesses require an online authentication attempt rather than an offline dictionary attack on a PIN-encrypted space key.

Host timeout uses both wall time and a monotonic stopwatch. The client waits at most 20 seconds and never accepts after expiry. Successful responses remain for collection for at most 15 seconds and within the invitation deadline; the client removes a collected response, and the host cleans its request/response files on exit. Abrupt termination or an inaccessible NAS can leave public offers/encrypted responses until later cleanup, but expired invitations are rejected. One successful cryptographic exchange consumes the PIN even if subsequent local storage or connection setup fails; the user can generate another. Devices need reasonably synchronized clocks. Concurrent hosts and actual SMB locking still require real NAS verification.

The six-digit PIN is not a recovery key. Already paired devices retain their independent random space key; there is no per-device revocation or automatic space-key rotation in this preview.

## Encrypted records

Each `records/<id>.clip` contains raw bytes: 12-byte nonce, ciphertext, 16-byte authentication tag. Algorithm: AES-256-GCM; AAD is UTF-8 `clipday-sync-v1:<space>`. Nonce is randomly generated for every sealing operation. A file is fully authenticated before JSON fields are used. Writes use a temporary sibling followed by atomic rename, but readers still reject/retry partial files because SMB or future cloud folder implementations may not preserve local atomicity.

Plaintext JSON keys (camelCase):

| Key | Type / rule |
| --- | --- |
| v | integer 1 |
| id, space, device | lowercase canonical UUID strings |
| name | source display name, at most 256 UTF-8 bytes |
| seq | positive Int64, monotonic per device, stored before generating an outbound record |
| created | positive Unix milliseconds |
| expires | exactly created + 86,400,000 ms |
| observed | map from device UUID to nonnegative Int64 sequence; at most 100 devices |
| text | nonempty UTF-8 text, at most 1 MiB |

Envelope cap: 2 MiB. Filename must equal the authenticated record ID. Symlink files are refused. An unsupported protocol version, wrong space/key/tag, invalid field, or incomplete file is rejected without advancing the seen set. Timestamps more than 5 minutes ahead are retried later. Expired authenticated records are removed and never imported, including after backup restoration. Only recognized UUID `.clip` files are processed.

## Application and acknowledgement

A local encrypted outbox survives offline periods. Local metadata stores a random device ID, sequence, per-peer high-water marks, and seen record IDs through their expiry. Clock knowledge is captured when copying, never upgraded later when flushing an offline outbox.

A successful scan stores received records in an encrypted local inbox before marking seen. Each batch includes unacknowledged records again. The UI writes local history, then acknowledges and removes the inbox records. A crash in between results in harmless history ID dedupe. Acknowledged local deletions do not reappear on restart.

Automatic clipboard application requires all of:

- A successful scan less than 6 seconds earlier, with no suspension/failure in between.
- Source sequence exceeds the previously observed source maximum.
- Timestamp is not future and is at most 10 seconds old.
- Sender's observed counter for this receiver is at least the receiver's current local sequence.
- Eligible new records come from only one source; choose the highest sequence.
- On the UI thread, the clipboard sequence and local operation generation have not changed; recording/sync is still enabled. Check freshness again after I/O.

All other valid records enter history only. Remote copies never enqueue new records. This multi-device preview favors retaining the user's local clipboard when concurrency is uncertain; it is not a global total order and does not claim clock-independent distributed expiry.

## Platform APIs

- [Apple CryptoKit AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm)
- [Microsoft AesGcm](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.aesgcm?view=net-10.0)
- [Windows clipboard listener](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-addclipboardformatlistener)
- [Bouncy Castle C# SRP implementation](https://github.com/bcgit/bc-csharp/tree/master/crypto/src/crypto/agreement/srp)
- [RFC 5054 SRP groups and protocol](https://www.rfc-editor.org/rfc/rfc5054)
- [.NET Native AOT](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/)
