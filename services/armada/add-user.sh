#!/bin/bash
# Give a lab member their own Armada queue on cirrus.
#
#   ./add-user.sh <github-login> [queue-name]      # queue name defaults to the login, lowercased
#   ./add-user.sh --dry-run <github-login> [queue-name]
#
# Armada's username is the Dex `sub`, not the GitHub login: base64url of the
# protobuf {1: "<GitHub numeric user id>", 2: "github"}. It is computed here from
# the GitHub id, so the queue works on the user's first login. Only that user may
# submit to, cancel in, reprioritize or watch the queue; lab owners can act on
# every queue (permissionGroupMapping in armada-server.yaml).
#
# Running it again updates the queue's permissions (idempotent).
# Needs: gh (any login), python3, armadactl with a `cirrus` context, and an
# Armada login in boettiger-lab:owners (only owners may create queues).
set -euo pipefail

DRY=""
if [ "${1:-}" = "--dry-run" ]; then DRY="--dry-run"; shift; fi
LOGIN="${1:?usage: $0 [--dry-run] <github-login> [queue-name]}"
QUEUE="${2:-$(printf '%s' "$LOGIN" | tr '[:upper:]' '[:lower:]')}"
CONTEXT="${ARMADA_CONTEXT:-cirrus}"

GHID=$(gh api "users/$LOGIN" -q .id)
SUB=$(python3 - "$GHID" <<'PY'
import base64, sys
u, c = sys.argv[1].encode(), b"github"
raw = bytes([0x0a, len(u)]) + u + bytes([0x12, len(c)]) + c
print(base64.urlsafe_b64encode(raw).decode().rstrip("="))
PY
)

f=$(mktemp --suffix=.yaml)
trap 'rm -f "$f"' EXIT
cat > "$f" <<EOF
apiVersion: armadaproject.io/v1beta1
kind: Queue
name: $QUEUE
labels:
  boettiger-lab/github-login: $LOGIN
permissions:
  - subjects:
      - kind: User
        name: $SUB
    verbs: [submit, cancel, reprioritize, watch]
priorityFactor: 1
EOF

echo "github=$LOGIN id=$GHID sub=$SUB queue=$QUEUE"
if [ -n "$DRY" ]; then cat "$f"; fi
if armadactl -c "$CONTEXT" get queue "$QUEUE" >/dev/null 2>&1; then
  armadactl -c "$CONTEXT" update $DRY -f "$f"
else
  armadactl -c "$CONTEXT" create $DRY -f "$f"
fi
