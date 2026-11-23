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
rc_pod <<EOF
set -e
rc bucket create s/$BUCKET --ignore-existing
rc bucket quota set s/$BUCKET $QUOTA
cat > /tmp/p.json <<'JSON'
$POLICY_JSON
JSON
rc admin policy create s $POLICY /tmp/p.json
rc admin user add s $USER '$PASS' >/dev/null
rc admin policy attach s $POLICY --user $USER
echo "== created"; rc admin user info s $USER
EOF

umask 077; mkdir -p ~/tmp
cat > "$OUT" <<EOF
Upload server (FTP over TLS)

  Host:      s3.carlboettiger.info
  Port:      21
  Protocol:  FTP - File Transfer Protocol
  Encryption: Require explicit FTP over TLS
  Username:  $USER
  Password:  $PASS
  Folder:    /$BUCKET   (upload into this folder)

FileZilla: File > Site Manager > New site, enter the values above, Logon Type "Normal",
and on the Advanced tab set "Default remote directory" to /$BUCKET.
Unencrypted FTP is refused. Uploads you finish cannot be changed or deleted from
your side; if one fails, upload that file again.
EOF
echo "Credentials for the partner: $OUT"
echo "Open the ports if not already open: kubectl apply -f platform/rustfs/ftps-public.yaml"
