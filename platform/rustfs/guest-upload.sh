#!/usr/bin/env bash
# Temporary upload-only login for an outside partner, used over FTPS (ftps-public.yaml)
# or plain S3. One bucket per partner; the user can list and write that bucket and
# nothing else: no reads, no deletes, no other buckets.
#
#   bash platform/rustfs/guest-upload.sh add NAME [QUOTA]   # default quota 2T
#   bash platform/rustfs/guest-upload.sh remove NAME        # user + policy; bucket kept
#
# Creates bucket incoming-NAME, user guest-NAME, policy guest-upload-NAME. The
# password is generated here, sent to rc over stdin (never in a pod spec or Secret)
# and written only to ~/tmp/guest-NAME-ftps.txt (mode 600) for you to pass on.
# Runs rc in a throwaway pod with the root key from Secret rustfs/rustfs-s3-root.
set -euo pipefail
CMD=${1:-}; NAME=${2:-}; QUOTA=${3:-2T}
[[ "$CMD" =~ ^(add|remove)$ && "$NAME" =~ ^[a-z0-9][a-z0-9-]{1,40}$ ]] \
  || { echo "usage: $0 add|remove NAME [QUOTA]   (NAME: lowercase letters, digits, -)"; exit 1; }
BUCKET=incoming-$NAME USER=guest-$NAME POLICY=guest-upload-$NAME

rc_pod() {   # stdin = shell script run inside the rc pod, alias `s` = root
  kubectl -n rustfs run "rc-guest-$$" --rm -i --restart=Never --quiet --image=rustfs/rc:latest \
    --overrides='{"spec":{"containers":[{"name":"rc","image":"rustfs/rc:latest","stdin":true,
      "command":["sh","-c","rc alias set s http://rustfs-s3.rustfs.svc:9000 \"$AK\" \"$SK\" >/dev/null && sh -s"],
      "env":[{"name":"AK","valueFrom":{"secretKeyRef":{"name":"rustfs-s3-root","key":"access-key"}}},
             {"name":"SK","valueFrom":{"secretKeyRef":{"name":"rustfs-s3-root","key":"secret-key"}}}]}]}}'
}

if [ "$CMD" = remove ]; then
  rc_pod <<EOF
set -x
rc admin policy detach s $POLICY --user $USER || true
rc admin user rm s $USER || true
rc admin policy rm s $POLICY || true
rc admin user ls s | grep -c $USER || true
EOF
  echo "Removed $USER and $POLICY. Bucket $BUCKET and its data are kept."
  echo "If no other partner is uploading: kubectl delete -f platform/rustfs/ftps-public.yaml"
  exit 0
fi

PASS=$(openssl rand -hex 20)
OUT=~/tmp/guest-$NAME-ftps.txt
POLICY_JSON=$(cat <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation","s3:ListBucketMultipartUploads"],
  "Resource":["arn:aws:s3:::$BUCKET"]},
 {"Effect":"Allow","Action":["s3:PutObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],
  "Resource":["arn:aws:s3:::$BUCKET/*"]}]}
EOF
)
# Write the partner's instructions FIRST, so the password survives any later failure.
umask 077; mkdir -p ~/tmp
cat > "$OUT" <<EOF
Sending us your data over secure FTP

We have set up a secure FTP upload for you. It works with any standard FTP
program that supports encryption (FileZilla, WinSCP, Cyberduck). The connection
is encrypted ("FTP over TLS"); plain unencrypted FTP will not connect, so the
FTP built into Windows Explorer cannot be used.

Your connection details
  Host:          s3.carlboettiger.info
  Port:          21
  Protocol:      FTP
  Encryption:    Require explicit FTP over TLS
  Username:      $USER
  Password:      $PASS
  Upload folder: /$BUCKET

FileZilla
  1. File > Site Manager > New site.
  2. General tab: enter Host and Port; Protocol "FTP - File Transfer Protocol";
     Encryption "Require explicit FTP over TLS"; Logon Type "Normal";
     then the Username and Password.
  3. Advanced tab: Default remote directory = /$BUCKET
  4. Connect. If asked to trust the certificate, check it is issued to
     s3.carlboettiger.info and accept.
  5. Drag files from the left pane (your computer) to the right pane (our server).

WinSCP: New Site, File protocol "FTP", Encryption "TLS/SSL Explicit encryption",
then the same host, port, username and password; open the upload folder after
connecting.

Tips for large transfers
  - An interrupted file restarts from the beginning, so many medium-sized files
    are more reliable than one very large file.
  - Maximum size of a single file is about 150 GB.
  - If a file fails, upload it again; it replaces the partial attempt.
  - You can upload into the folder but cannot delete or download from it.
  - If you cannot connect from a work network, your IT team may need to allow
    outgoing connections to s3.carlboettiger.info on port 21 and ports 40000-40019.

Please email us when the upload is finished so we can close the connection.
EOF

# Re-runnable: an existing bucket or policy is kept, an existing user is recreated
# with the new password. Success is judged by the final listing, not exit codes.
RESULT=$(rc_pod <<EOF || true
rc bucket list s 2>/dev/null | grep -q " $BUCKET/" || rc bucket create s/$BUCKET
rc bucket quota set s/$BUCKET $QUOTA
cat > /tmp/p.json <<'JSON'
$POLICY_JSON
JSON
rc admin policy create s $POLICY /tmp/p.json 2>&1 | tail -1
rc admin user rm s $USER >/dev/null 2>&1
rc admin user add s $USER '$PASS' >/dev/null
rc admin policy attach s $POLICY --user $USER
rc admin user ls s 2>&1 | grep -F "$USER (policies: $POLICY" && echo USER-OK
EOF
)
echo "$RESULT"
grep -q USER-OK <<<"$RESULT" || { rm -f "$OUT"; echo "FAILED: $USER not set up (see above)"; exit 1; }
echo "Ready to send to the partner: $OUT"
echo "Open the ports if not already open: kubectl apply -f platform/rustfs/ftps-public.yaml"
