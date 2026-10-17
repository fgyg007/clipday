#!/usr/bin/env python3
"""Independent encrypted image fixture validation. Requires Python cryptography.

Only public fixture keys/data and optional synthetic Java exports are read.
Never point this test at a user's actual NAS or clipboard storage.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import struct
import zlib
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.exceptions import InvalidTag

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--java-output', type=Path, help='Optional synthetic Java interoperability JSON')
a = p.parse_args()
v = json.loads((ROOT / 'Tests/Fixtures/image-v1.json').read_text())
key = base64.b64decode(v['keyBase64']); aes = AESGCM(key)
def decrypt(envelope, aad):
    raw = base64.b64decode(envelope)
    return aes.decrypt(raw[:12], raw[12:], aad.encode())
def validate(source):
    manifest = json.loads(decrypt(source['manifestEnvelopeBase64'], v['manifestAad']))
    assert manifest == v['manifest'], 'manifest mismatch'
    image = decrypt(source['chunkEnvelopeBase64'], v['chunkAad'])
    assert image == base64.b64decode(v['pngBase64'])
    assert len(image) == manifest['byteCount'] and hashlib.sha256(image).hexdigest() == manifest['sha256']
    assert image[:8] == b'\x89PNG\r\n\x1a\n'
    assert struct.unpack('>II', image[16:24]) == (manifest['width'], manifest['height'])
    pos = 8
    while pos < len(image):
        length = struct.unpack('>I', image[pos:pos+4])[0]
        body = image[pos+4:pos+8+length]
        assert zlib.crc32(body) == struct.unpack('>I',image[pos+8+length:pos+12+length])[0]
        assert body[:4] != b'acTL'
        pos += 12+length
    assert pos == len(image)
    for aad in [v['chunkAad'].replace(':0:', ':1:'), v['chunkAad']+'x']:
        try: decrypt(source['chunkEnvelopeBase64'],aad)
        except InvalidTag: pass
        else: raise AssertionError('chunk context was not authenticated')
    raw=bytearray(base64.b64decode(source['chunkEnvelopeBase64']));raw[-1]^=1
    try: decrypt(base64.b64encode(raw),v['chunkAad'])
    except InvalidTag: pass
    else: raise AssertionError('tamper accepted')
validate(v)
print('PASS: public manifest/chunk vector, PNG CRC/hash/dimensions, AAD binding and tamper rejection')
if a.java_output:
    validate(json.loads(a.java_output.read_text()))
    print('PASS: Java-produced randomized envelopes decoded and validated independently in Python')
