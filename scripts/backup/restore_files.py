"""Put backed-up files back into Supabase Storage (see docs/BACKUPS.md, "Restore").

Usage (on your own computer, after downloading the files/ folder from R2):
  export SUPABASE_URL=https://<project>.supabase.co
  export SUPABASE_SERVICE_ROLE_KEY=...      # of the project you restore INTO
  export BACKUP_PASSPHRASE=...              # the backup password
  python3 restore_files.py path/to/files    # the folder that holds <bucket>/...

Every <bucket>/<name>.gpg is decrypted and uploaded to <bucket>/<name>
(overwriting a file of the same name). Buckets must already exist -- they do
after the database restore. Prints counts only.
"""
import mimetypes
import os
import subprocess
import sys
import urllib.parse
import urllib.request


def auth_headers(key):
    """Legacy service_role keys are JWTs and go in both headers; the newer
    sb_secret_... keys go in the apikey header only."""
    if key.startswith("sb_"):
        return {"apikey": key}
    return {"Authorization": f"Bearer {key}", "apikey": key}


def decrypt(src):
    return subprocess.run(
        ["gpg", "--batch", "--quiet", "--pinentry-mode", "loopback", "--passphrase-fd", "0", "--decrypt", src],
        input=os.environ["BACKUP_PASSPHRASE"].encode() + b"\n", capture_output=True, check=True,
    ).stdout


def upload(bucket, name, data):
    base = os.environ["SUPABASE_URL"].rstrip("/")
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    path = "/".join(urllib.parse.quote(p, safe="") for p in name.split("/"))
    req = urllib.request.Request(
        f"{base}/storage/v1/object/{urllib.parse.quote(bucket, safe='')}/{path}", data=data, method="POST",
        headers={**auth_headers(key), "x-upsert": "true",
                 "Content-Type": mimetypes.guess_type(name)[0] or "application/octet-stream"},
    )
    urllib.request.urlopen(req, timeout=120).read()


def main(root):
    done = failed = 0
    for dirpath, _, files in os.walk(root):
        for f in files:
            if not f.endswith(".gpg"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, f), root).replace(os.sep, "/")
            bucket, _, name = rel[: -len(".gpg")].partition("/")
            try:
                upload(bucket, name, decrypt(os.path.join(dirpath, f)))
                done += 1
            except Exception as exc:
                failed += 1
                print(f"Could not restore a file in '{bucket}' ({type(exc).__name__})")
    print(f"Restored {done} file(s); failed {failed}.")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main(sys.argv[1])
