#!/usr/bin/env python3
"""Make MinIO's `mc admin cluster iam export` importable by RustFS 1.0.5.

stdin: the export zip; stdout: the filtered zip; argv[1]: a file that receives the
number of service accounts kept (no secrets). Used by cutover.sh, step 4.

- MinIO writes "groups": null on every service account when it has no groups;
  RustFS rejects the whole import ("invalid type: null, expected a sequence").
- MinIO stores "no session policy" (= inherit the parent's) either as null or as an
  empty embedded policy ({"Version":"","Statement":null}). RustFS rejects the first
  and silently skips accounts with the second. Both become inherited-policy, which
  is what MinIO enforces for them (svcacct info: impliedPolicy true).
- Service accounts whose parent is a Google-OIDC console login are dropped (owner
  decision 2026-11-18): RustFS has no such identity, so it would skip them anyway.
"""
import io
import json
import sys
import zipfile

src = zipfile.ZipFile(io.BytesIO(sys.stdin.buffer.read()))
users = set(json.loads(src.read("iam-assets/users.json")))
out = io.BytesIO()
kept = 0
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as dst:
    for name in src.namelist():
        raw = src.read(name)
        if name.endswith("svcaccts.json"):
            accts = json.loads(raw)
            for key, v in list(accts.items()):
                claims = v.get("claims") or {}
                if v.get("parent") not in users and "aud" in claims:
                    print(f"dropped {key[:6]}… (parent is an OIDC login)", file=sys.stderr)
                    del accts[key]
                    continue
                if v.get("groups") is None:
                    v["groups"] = []
                sp = v.get("sessionPolicy")
                if not (isinstance(sp, dict) and sp.get("Statement")):
                    v.pop("sessionPolicy", None)
                    claims.pop("sessionPolicy", None)
                    claims.pop("sessionPolicy-extracted", None)
                    if claims.get("sa-policy") == "embedded-policy":
                        claims["sa-policy"] = "inherited-policy"
            kept = len(accts)
            raw = json.dumps(accts).encode()
        dst.writestr(name, raw)
with open(sys.argv[1], "w") as f:
    f.write(f"{kept}\n")
sys.stdout.buffer.write(out.getvalue())
