"""Copy new or changed Supabase Storage files to Cloudflare R2, encrypted.

Used by .github/workflows/backup.yml (see docs/BACKUPS.md). Standard library
only. Inputs:
  objects.tsv   bucket_id <TAB> name <TAB> updated_epoch   (from storage.objects)
  r2-files.json [{"Key": ..., "LastModified": ...}] or null (from R2)
Environment: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, BACKUP_PASSPHRASE,
R2_BUCKET, R2_ENDPOINT (+ AWS_* keys for the aws CLI).

Each file is stored at files/<bucket>/<name>.gpg. A file is (re)copied when
R2 has no copy or the app's copy changed after R2's copy was written. Files
deleted in the app are never deleted from R2. The log prints counts only.
"""
import json
import os
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from datetime import datetime


def auth_headers(key):
    """Legacy service_role keys are JWTs and go in both headers; the newer
    sb_secret_... keys go in the apikey header only."""
    if key.startswith("sb_"):
        return {"apikey": key}
    return {"Authorization": f"Bearer {key}", "apikey": key}


def r2_key(bucket, name):
    return f"files/{bucket}/{name}.gpg"


def plan(objects, r2_listing):
    """objects: [(bucket, name, updated_epoch)]; r2_listing: [{"Key","LastModified"}] or None.
    Returns the (bucket, name) pairs that need copying."""
    have = {}
    for item in r2_listing or []:
        stamp = item["LastModified"].replace("Z", "+00:00")
        have[item["Key"]] = datetime.fromisoformat(stamp).timestamp()
    todo = []
    for bucket, name, updated in objects:
        copied_at = have.get(r2_key(bucket, name))
        if copied_at is None or updated > copied_at:
            todo.append((bucket, name))
    return todo


def read_objects(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            bucket, name, updated = line.split("\t")
            rows.append((bucket, name, int(updated)))
    return rows


def download(bucket, name, dest):
    base = os.environ["SUPABASE_URL"].rstrip("/")
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    path = "/".join(urllib.parse.quote(part, safe="") for part in name.split("/"))
    req = urllib.request.Request(
        f"{base}/storage/v1/object/{urllib.parse.quote(bucket, safe='')}/{path}",
        headers=auth_headers(key),
    )
    with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as out:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)


def encrypt(src, dest):
    subprocess.run(
        ["gpg", "--batch", "--yes", "--quiet", "--pinentry-mode", "loopback", "--passphrase-fd", "0",
         "--symmetric", "--cipher-algo", "AES256", "-o", dest, src],
        input=os.environ["BACKUP_PASSPHRASE"].encode(), check=True,
    )


def upload(src, key):
    subprocess.run(
        ["aws", "s3", "cp", "--only-show-errors", "--endpoint-url", os.environ["R2_ENDPOINT"],
         src, f"s3://{os.environ['R2_BUCKET']}/{key}"],
        check=True,
    )


def main(objects_path, r2_path):
    objects = read_objects(objects_path)
    with open(r2_path, encoding="utf-8") as fh:
        listing = json.load(fh)
    todo = plan(objects, listing)
    print(f"Files in the app: {len(objects)}; already backed up and unchanged: {len(objects) - len(todo)}; to copy now: {len(todo)}")
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        plain, sealed = os.path.join(tmp, "f"), os.path.join(tmp, "f.gpg")
        for i, (bucket, name) in enumerate(todo, 1):
            try:
                download(bucket, name, plain)
                encrypt(plain, sealed)
                upload(sealed, r2_key(bucket, name))
            except Exception as exc:  # keep going; report at the end
                failed += 1
                print(f"::warning::file {i} of {len(todo)} in bucket '{bucket}' could not be copied ({type(exc).__name__})")
            finally:
                for p in (plain, sealed):
                    if os.path.exists(p):
                        os.remove(p)
    print(f"Copied {len(todo) - failed} file(s); failed {failed}.")
    if failed:
        print(f"::error::{failed} file(s) were not backed up; they will be retried next run.")
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
