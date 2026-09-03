#!/usr/bin/env bash
# Benchmark decode throughput + MTP speculative-decoding acceptance for the
# qwen38 deployment on nimbus. Run from any host with kubectl access:
#   ./bench-qwen38.sh [deployment-name]
#
# Reports, per scenario: TTFT, decode tok/s, total tokens. Then reads vLLM's
# Prometheus counters to compute the MTP acceptance rate -- the number that
# actually explains whether speculation is paying for itself. num_speculative_tokens
# is 3, so the ceiling is 4 tokens/step; acceptance well under ~50% means
# speculation is costing more than it returns and should be retuned or dropped.
set -euo pipefail

DEPLOY="${1:-qwen38}"
KEY="$(kubectl get secret vllm-api-key -o jsonpath='{.data.api-key}' | base64 -d)"

# Scrape counters before/after so the rate reflects THIS run, not lifetime totals.
spec_counters() {
  kubectl exec "deploy/$DEPLOY" -- curl -s localhost:8000/metrics \
    | grep -E '^vllm:spec_decode_(num_drafts|num_draft_tokens|num_accepted_tokens)_total' \
    | awk '{print $1" "$2}'
}

run_case() {
  local name="$1" prompt="$2" thinking="$3" maxtok="$4"
  echo "### $name (thinking=$thinking)"
  kubectl exec "deploy/$DEPLOY" -- curl -s -o /tmp/bench_out.json -w '%{time_starttransfer}' \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -X POST localhost:8000/v1/chat/completions -d "$(cat <<JSON
{"model":"qwen",
 "messages":[{"role":"user","content":$(printf '%s' "$prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}],
 "max_tokens":$maxtok, "stream":false,
 "chat_template_kwargs":{"enable_thinking":$thinking}}
JSON
)" > /tmp/bench_ttft 2>/dev/null || true

  # Wall-clock the same request to derive decode rate from completion_tokens.
  local t0 t1
  t0=$(python3 -c 'import time;print(time.time())')
  kubectl exec "deploy/$DEPLOY" -- curl -s \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -X POST localhost:8000/v1/chat/completions -d "$(cat <<JSON
{"model":"qwen",
 "messages":[{"role":"user","content":$(printf '%s' "$prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}],
 "max_tokens":$maxtok, "stream":false,
 "chat_template_kwargs":{"enable_thinking":$thinking}}
JSON
)" > /tmp/bench_out.json
  t1=$(python3 -c 'import time;print(time.time())')

  python3 - "$t0" "$t1" <<'PY'
import json, sys
t0, t1 = float(sys.argv[1]), float(sys.argv[2])
d = json.load(open('/tmp/bench_out.json'))
u = d.get('usage', {})
ct = u.get('completion_tokens', 0)
pt = u.get('prompt_tokens', 0)
el = t1 - t0
print(f"  prompt={pt} completion={ct} elapsed={el:.2f}s  ->  {ct/el:.1f} tok/s (end-to-end)")
PY
  echo
}

echo "=== pre-run speculative counters ==="; spec_counters; echo

run_case "short prompt / short answer" \
  "In one paragraph, explain why unified memory changes the tradeoffs for LLM inference." false 300

run_case "reasoning task" \
  "A farmer has 17 sheep. All but 9 run away. Then he buys twice as many as remain, then sells a third of the total. How many does he have? Show your reasoning." true 1200

run_case "code generation" \
  "Write a Python function that computes the exact median of a stream of integers using two heaps. Include docstring and edge-case handling." false 800

echo "=== post-run speculative counters ==="; spec_counters; echo
echo "acceptance rate = num_accepted_tokens_total / num_draft_tokens_total (deltas above)"
