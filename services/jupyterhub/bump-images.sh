#!/bin/bash
# Pin the hub's notebook images to their current builds (k8s#220).
#
#   ./bump-images.sh      # rewrite public-config.yaml, show the diff
#   ./up.sh               # deploy: the hook pre-puller pulls the new images
#                         # onto every node BEFORE the hub switches to them
#
# Each image becomes repo:TAG@sha256:DIGEST: the digest makes it immutable (so
# pullPolicy IfNotPresent is safe), the tag says which build it is. TAG is the
# newest dated CI tag (YYYYMMDD-rN, see docker-image.yml) or `latest` for images
# that have none (third-party ml-spatial). Anonymous ghcr API, no credentials.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG=public-config.yaml
REPOS="boettiger-lab/k8s boettiger-lab/k8s-gpu rocker-org/ml-spatial"
ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

for repo in $REPOS; do
  token=$(curl -fsS "https://ghcr.io/token?scope=repository:${repo}:pull" | jq -r .token)
  tag=$(curl -fsS -H "Authorization: Bearer $token" "https://ghcr.io/v2/${repo}/tags/list?n=10000" \
        | jq -r '[.tags[] | select(test("^[0-9]{8}-r[0-9]+$"))]
                 | sort_by(split("-r")[1] | tonumber) | last // "latest"')
  digest=$(curl -fsSI -H "Authorization: Bearer $token" -H "Accept: $ACCEPT" \
           "https://ghcr.io/v2/${repo}/manifests/${tag}" \
           | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "no digest for ${repo}:${tag}" >&2; exit 1; }
  ref="ghcr.io/${repo}:${tag}@${digest}"
  # Match the repo exactly: `k8s:` must not match `k8s-gpu:`.
  n=$(grep -cE "image: *\"ghcr\.io/${repo}:[^\"]*\"" "$CONFIG" || true)
  [ "$n" = 1 ] || { echo "expected 1 image line for ${repo} in ${CONFIG}, found ${n}" >&2; exit 1; }
  sed -i -E "s|(image: *\")ghcr\.io/${repo}:[^\"]*(\")|\1${ref}\2|" "$CONFIG"
  echo "${repo} -> ${tag} ${digest:0:19}"
done
git --no-pager diff -- "$CONFIG" || true
