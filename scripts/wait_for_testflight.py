#!/usr/bin/env python3
"""Wait for the TestFlight build this workflow run just uploaded to be processed.

Why this exists: the upload action's own "wait for processing" query fails with
HTTP 401 ("Authentication credentials are missing or invalid") against a key that
altool and xcodebuild accept, so a green upload looked like a failed run. This
script authenticates with the same App Store Connect API key, using openssl for
the ES256 JWT (no third-party dependency), resolves the app from the bundle id,
and reports the truth:

    VALID      -> print and exit 0
    INVALID    -> Apple rejected the binary (it emails the ITMS-* reasons); exit 1
    PROCESSING -> keep polling until --timeout
    no build   -> keep polling (Apple can take a few minutes to list it)
"""
from __future__ import annotations

import argparse
import base64
import json
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.appstoreconnect.apple.com"


def b64url(data: bytes) -> bytes:
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def der_to_raw(der: bytes) -> bytes:
    """ES256 signatures come out of openssl as DER; JWS wants r||s (32 bytes each)."""
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    if der[index] != 0x02:
        raise ValueError("unexpected DER signature")
    length = der[index + 1]
    r = der[index + 2 : index + 2 + length]
    index += 2 + length
    length = der[index + 1]
    s = der[index + 2 : index + 2 + length]
    return r.lstrip(b"\x00").rjust(32, b"\x00") + s.lstrip(b"\x00").rjust(32, b"\x00")


def token(key_path: Path, key_id: str, issuer: str, lifetime: int = 900) -> str:
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64url(
        json.dumps(
            {"iss": issuer, "iat": now, "exp": now + lifetime, "aud": "appstoreconnect-v1"},
            separators=(",", ":"),
        ).encode()
    )
    signing_input = header + b"." + payload
    with tempfile.TemporaryDirectory() as tmp:
        message = Path(tmp) / "message"
        signature = Path(tmp) / "signature"
        message.write_bytes(signing_input)
        subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(key_path), "-out", str(signature), str(message)],
            check=True,
            capture_output=True,
        )
        raw = der_to_raw(signature.read_bytes())
    return (signing_input + b"." + b64url(raw)).decode()


def api(path: str, jwt: str) -> dict:
    request = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {jwt}"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise SystemExit(f"App Store Connect API {path} failed: HTTP {error.code} {error.read()[:200]!r}")


def app_id_for(bundle_id: str, jwt: str) -> str:
    data = api(f"/v1/apps?filter[bundleId]={bundle_id}", jwt)
    apps = data.get("data", [])
    if not apps:
        raise SystemExit(f"no app record for bundle id {bundle_id}")
    return apps[0]["id"]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default="codes.amos.quarto")
    parser.add_argument("--build", required=True, help="build number to wait for (the workflow run number)")
    parser.add_argument("--key-path", required=True, type=Path)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--timeout", type=int, default=1500)
    parser.add_argument("--poll", type=int, default=30)
    args = parser.parse_args(argv)

    jwt = token(args.key_path, args.key_id, args.issuer)
    app_id = app_id_for(args.bundle_id, jwt)
    print(f"waiting for build {args.build} of app {app_id} ({args.bundle_id})", flush=True)
    deadline = time.time() + args.timeout
    last_state = None
    while True:
        data = api(f"/v1/builds?filter[app]={app_id}&sort=-uploadedDate&limit=20", jwt)
        for build in data.get("data", []):
            attributes = build["attributes"]
            if str(attributes.get("version")) != str(args.build):
                continue
            state = attributes.get("processingState")
            if state != last_state:
                print(f"build {attributes.get('version')}: {state} (uploaded {attributes.get('uploadedDate')})", flush=True)
                last_state = state
            if state == "VALID":
                print(f"build {args.build} is ready in TestFlight", flush=True)
                return 0
            if state == "INVALID":
                print(
                    f"::error::App Store Connect rejected build {args.build} as invalid; "
                    "Apple emails the ITMS-* reasons (usually a missing icon or Info.plist key)",
                    flush=True,
                )
                return 1
        if time.time() > deadline:
            print(
                f"::error::build {args.build} was still not processed after {args.timeout}s "
                f"(last state: {last_state or 'not listed'}) - check App Store Connect",
                flush=True,
            )
            return 1
        time.sleep(args.poll)


if __name__ == "__main__":
    raise SystemExit(main())
