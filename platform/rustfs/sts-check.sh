#!/usr/bin/env bash
# Check Dex -> rustfs-s3 STS: GitHub login (device flow) -> Dex ID token ->
# AssumeRoleWithWebIdentity -> temporary keys, then allow/deny tests. Prints the
# token's username and groups, never the token or the keys.
# Needs sts-check-setup.sh first. Tools: curl, jq, aws.
set -euo pipefail
DEX=https://dex.carlboettiger.info
S3=https://s3.carlboettiger.info
CLIENT=rustfs-s3
T=$(mktemp -d); chmod 700 "$T"; trap 'rm -rf "$T"' EXIT

# 1. Device login
curl -sf "$DEX/device/code" -d client_id=$CLIENT -d scope="openid profile email groups" > "$T/dev"
echo "Open: $(jq -r .verification_uri_complete "$T/dev")"
DC=$(jq -r .device_code "$T/dev"); IV=$(jq -r '.interval // 5' "$T/dev")
while :; do
  sleep "$IV"
  curl -s "$DEX/token" -d grant_type=urn:ietf:params:oauth:grant-type:device_code \
    -d device_code="$DC" -d client_id=$CLIENT > "$T/tok"
  jq -e .id_token "$T/tok" >/dev/null 2>&1 && break
  case $(jq -r .error "$T/tok") in authorization_pending|slow_down) ;; *) jq . "$T/tok"; exit 1;; esac
done
jq -j .id_token "$T/tok" > "$T/id"   # -j: no trailing newline, or STS rejects the signature
cut -d. -f2 "$T/id" | tr '_-' '/+' | awk '{n=length($0)%4; if(n) $0=$0 substr("===",1,4-n); print}' \
  | base64 -d 2>/dev/null | jq -c '{preferred_username, aud, groups}'
U=$(cut -d. -f2 "$T/id" | tr '_-' '/+' | awk '{n=length($0)%4; if(n) $0=$0 substr("===",1,4-n); print}' | base64 -d 2>/dev/null | jq -r .preferred_username)

# 2. STS
sts() { curl -s "$S3/" --data-urlencode Action=AssumeRoleWithWebIdentity \
  --data-urlencode Version=2011-06-15 --data-urlencode DurationSeconds=900 \
  --data-urlencode WebIdentityToken@"$1"; }
sts "$T/id" > "$T/sts.xml"
if ! grep -q '<AccessKeyId>' "$T/sts.xml"; then echo "STS FAILED:"; sed 's/<[^>]*Token>[^<]*</<redacted></' "$T/sts.xml"; exit 1; fi
x() { sed -n "s:.*<$1>\(.*\)</$1>.*:\1:p" "$T/sts.xml"; }
export AWS_ACCESS_KEY_ID=$(x AccessKeyId) AWS_SECRET_ACCESS_KEY=$(x SecretAccessKey) AWS_SESSION_TOKEN=$(x SessionToken)
export AWS_DEFAULT_REGION=us-east-1 AWS_CONFIG_FILE="$T/cfg" AWS_SHARED_CREDENTIALS_FILE=/dev/null
printf '[default]\ns3 =\n  addressing_style = path\n' > "$T/cfg"
echo "STS ok: temporary keys issued (expire $(x Expiration))"

# 3. Allow/deny tests
pass=0; fail=0
check() {  # check <expect ok|deny> <label> <cmd...>
  local want=$1 label=$2; shift 2
  if "$@" >/dev/null 2>"$T/err"; then got=ok; else got=deny; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); r=PASS; else fail=$((fail+1)); r=FAIL; fi
  printf '%-4s %-5s %s\n' "$r" "$got" "$label"; [ "$r" = FAIL ] && [ "$got" = deny ] && head -c 300 "$T/err" && echo
  return 0
}
A=(aws --endpoint-url "$S3" s3api)
echo hi > "$T/f"
check ok   "put own prefix   sts-test/users/$U/check.txt" "${A[@]}" put-object --bucket sts-test --key "users/$U/check.txt" --body "$T/f"
check ok   "get own object"                                "${A[@]}" get-object --bucket sts-test --key "users/$U/check.txt" "$T/out"
check ok   "list own prefix"                               "${A[@]}" list-objects-v2 --bucket sts-test --prefix "users/$U/"
check deny "put other user's prefix"                       "${A[@]}" put-object --bucket sts-test --key "users/not-$U/x.txt" --body "$T/f"
check deny "list whole sts-test"                           "${A[@]}" list-objects-v2 --bucket sts-test
check deny "list private-cboettig"                         "${A[@]}" list-objects-v2 --bucket private-cboettig --max-items 1
check deny "put to public-dem"                             "${A[@]}" put-object --bucket public-dem --key sts-check.txt --body "$T/f"
check ok   "delete own object"                             "${A[@]}" delete-object --bucket sts-test --key "users/$U/check.txt"
# A tampered token must be refused.
sed 's/\(.*\)\(.....\)$/\1AAAAA/' "$T/id" > "$T/bad"
if sts "$T/bad" | grep -q '<AccessKeyId>'; then echo "FAIL tampered token accepted"; fail=$((fail+1)); else echo "PASS deny  tampered token refused"; pass=$((pass+1)); fi
echo "$pass passed, $fail failed"
