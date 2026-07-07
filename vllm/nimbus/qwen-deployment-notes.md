# Qwen3.6-35B-A3B-NVFP4 on DGX Spark — status & open issues

_Last updated 2026-07-04. Companion to `sglang-migration-issue.md` (Nemotron's equivalent log)._

## Current status

`nvidia/Qwen3.6-35B-A3B-NVFP4` is the **current default served model** on nimbus (`deploy-qwen.yaml`, pod runs in the `default` k8s namespace). ~106 tok/s single-stream decode, MTP spec-decode working well (mean acceptance length ~3.5, ~80-90% draft acceptance). Quality trial vs. Nemotron-3-Super in progress as of 2026-07-03.

## Upstream source of our recipe

Our `deploy-qwen.yaml` args are the **NVIDIA model card's own DGX Spark command, verbatim**:

**[nvidia/Qwen3.6-35B-A3B-NVFP4 · Hugging Face](https://huggingface.co/nvidia/Qwen3.6-35B-A3B-NVFP4)** — "Supported Runtime Engine(s): vLLM". The card's DGX Spark serve command matches our manifest flag-for-flag: `--attention-backend flashinfer --moe-backend marlin --kv-cache-dtype fp8 --gpu-memory-utilization 0.4 --speculative-config '{"method":"mtp","num_speculative_tokens":3,"moe_backend":"triton"}' --reasoning-parser qwen3 --tool-call-parser qwen3_xml --enable-auto-tool-choice`.

Unlike Nemotron-3-Super, **there is no custom `--reasoning-parser-plugin` for Qwen** — it uses vLLM's built-in `qwen3` reasoning parser and built-in `qwen3_xml` tool-call parser. The `super_v3`/`nano_v3` reasoning-parser-plugin pattern (`super_v3_reasoning_parser.py`) is Nemotron-only.

Native FP4 MoE compute is not available on GB10 for this checkpoint in vLLM either (`--moe-backend flashinfer_cutlass` is rejected by vLLM's backend oracle — group-16 NVFP4 + FP8-block-scale scheme unimplemented, same conclusion as Nemotron). Marlin (weight-only, BF16 MMA) is correct and is what NVIDIA's own command uses.

## Known issue: qwen3_xml tool-call parser bug (upstream, not ours)

**Symptom:** intermittent "inconsistent tool use parsing" reported 2026-07-04.

**Confirmed in our own qwen pod logs** (21h+ uptime, NGC `vllm:26.05.post1-py3`, vLLM `0.21.0+2325b6f0.nvinternal.26.5.post1`):
- Repeated `qwen3xml_tool_parser.py:303` WARNINGs: "junk after document element", "mismatched tag".
- One concrete client-facing failure: a follow-up turn replayed a prior malformed `tool_call.arguments` string back as conversation history; vLLM's `_postprocess_messages` did an unguarded `json.loads()` on it, hit an uncaught `json.decoder.JSONDecodeError: Extra data: line 1 column 23`, and returned **HTTP 400 Bad Request** to the client — killing that turn.

**Root cause, traced against the actual parser source pulled from the running pod** (`vllm/tool_parsers/qwen3xml_tool_parser.py`): when the model emits **multiple `<function=...>` blocks inside one `<tool_call>` element**, `StreamingXMLToolCallParser._end_element("function")` closes the JSON (`}` or `{}`) but never resets `current_function_name` / `parameters`, and `tool_call_index` is only incremented on `<tool_call>` open — not per sibling `<function>`. So the second function's delta stream inherits the first function's leftover `parameters` dict and lands in the *same* OpenAI `tool_calls[]` slot, producing malformed/duplicated JSON (extra `}`, concatenated JSON objects).

**Tracked upstream:** [vLLM #43713](https://github.com/vllm-project/vllm/issues/43713) — open as of 2026-07-04; reporter measured ~6-7% of calls affected on Qwen3.6-27B and has an unmerged patch cutting the error rate to 0%. Related: [vLLM #39056](https://github.com/vllm-project/vllm/issues/39056) (tool calls lost when XML lands inside `<think>`), [vLLM #31871](https://github.com/vllm-project/vllm/issues/31871) (streaming state bugs in other parsers).

Not a nimbus misconfiguration — our recipe matches NVIDIA's own command exactly.

## Mitigation: patched tool-call parser (deployed 2026-07-04)

vLLM supports `--tool-parser-plugin <path>` (analogous to Nemotron's `--reasoning-parser-plugin`), so a fix can be mounted the same way `super_v3_reasoning_parser.py` is mounted for Nemotron. Drafted at `qwen36_tool_call_parser.py`: subclasses `StreamingXMLToolCallParser`, and on `</function>` additionally resets `current_function_name`/`parameters`, mints a fresh `current_call_id`, and bumps `tool_call_index` — so a sibling `<function>` in the same `<tool_call>` can't inherit stale state or collide on the same slot. Registered under a new name (`qwen3_xml_patched`) rather than overriding the stock parser, so it's opt-in.

Deployed by applying this diff to `deploy-qwen.yaml`:

```yaml
        args:
          # ...
          - --reasoning-parser
          - qwen3
          - --tool-parser-plugin          # NEW
          - /tool-parser/qwen36_tool_call_parser.py
          - --tool-call-parser
          - qwen3_xml_patched             # was: qwen3_xml
          - --enable-auto-tool-choice
        volumeMounts:
          # ...existing dshm/hf-cache mounts...
          - name: tool-parser              # NEW
            mountPath: /tool-parser
            readOnly: true
      volumes:
        # ...existing dshm/hf-cache volumes...
        - name: tool-parser                # NEW
          hostPath:
            path: /home/cboettig/Documents/github/boettiger-lab/k8s/vllm/nimbus
            type: Directory
```

**Status:** live on the `default`-namespace qwen pod since 2026-07-04. Loaded cleanly (`PatchedQwen3XMLToolParser` registered, no import errors), a manual multi-tool-call smoke test passed, and no recurrence of the `qwen3xml_tool_parser.py:303` warnings or the `JSONDecodeError`/400 pattern in the post-deploy window. **Not yet proven at scale** — we haven't forced the actual trigger (two `<function>` blocks inside one `<tool_call>`, a probabilistic ~6-7% model quirk not directly controllable via the API), so confidence comes from watching real production traffic over time, not a single test. If the warning signature reappears, the patch needs revisiting; if it stays clean for a day+ of real usage, treat it as confirmed. Track [#43713](https://github.com/vllm-project/vllm/issues/43713) regardless — drop this patch once an upstream fix merges and ships in an NGC image.

## Known issue: high-variance tool-call decisions & reasoning length (root-caused 2026-07-06)

**Symptom:** reports of "highly variable response strategy and tool use" — same/similar prompts sometimes trigger a tool call, sometimes a direct answer; reasoning length swings widely; occasional malformed/truncated `tool_calls[].function.arguments` JSON.

**Investigation:** vLLM's k8s logs carry no message content by default (verified empirically with a unique marker string — didn't appear in logs). Turned on `--enable-log-requests --enable-log-outputs` + `VLLM_LOGGING_LEVEL=DEBUG` (temporary, still live) to get prompt/output visibility.

**Root causes found, both confirmed by direct reproduction against the live pod:**

1. **Default sampling was `temperature=1.0, top_p=0.95, top_k=20`** — not a nimbus misconfig, this is `nvidia/Qwen3.6-35B-A3B-NVFP4`'s own shipped `generation_config.json`, applied whenever a client doesn't override it. At temp=1.0, repeated identical borderline prompts (e.g. "What is 12 + 7?" with a calculator tool offered) flipped between `TOOL_CALL` and `DIRECT_ANSWER` (3/5 vs 2/5 in one trial) and reasoning length varied ~4x run to run (122–1050 tokens).
2. **Malformed tool-call JSON was a `max_tokens` truncation artifact**, not a parser bug: when the (highly variable, per #1) reasoning ran long, it could eat the entire token budget before the tool-call's JSON finished streaming, cutting it off mid-string (e.g. `{"expr": "`). vLLM mislabels `finish_reason` as `"tool_calls"` in this case instead of `"length"`, so clients can't detect the truncation from finish_reason alone. Reproduced directly: `max_tokens=250` → truncated/malformed args on run 4/5; `max_tokens=2000` on the same prompt → 8/8 well-formed.

**Fix (deployed 2026-07-06):** added `--override-generation-config '{"temperature": 0.0}'` to `deploy-qwen.yaml` so the server forces greedy decoding regardless of client-supplied sampling params. Verified: repeated "What is 12 + 7?" test now hits `TOOL_CALL` 8/8 (was 3/5). Reasoning length still varies somewhat run-to-run (325–781 tokens in an 8-run sample) — this residual variance is expected under continuous batching + MTP speculative decoding (batch-composition-dependent floating-point rounding cascading through long autoregressive chains); it is not eliminable via sampling config, and did not manifest as a wrong tool-call decision in this sample.

**Caveat / follow-up:** greedy decoding trades off output diversity/quality for determinism — worth watching whether response quality regresses on tasks that benefit from sampling. `--enable-log-requests`/`--enable-log-outputs`/`VLLM_LOGGING_LEVEL=DEBUG` are still on for continued monitoring; drop them (they add log volume) once confidence is established. Consider filing the `finish_reason` mislabeling-on-truncation behavior upstream — it silently masks truncated tool calls from any client that trusts `finish_reason`.

## Alternate deployment routes NVIDIA blesses for this model

**Short answer: no, not for this NVFP4 checkpoint on Spark.** The [HF model card](https://huggingface.co/nvidia/Qwen3.6-35B-A3B-NVFP4) states "Supported Runtime Engine(s): vLLM" — no TensorRT-LLM or SGLang recipe is documented for `nvidia/Qwen3.6-35B-A3B-NVFP4` specifically, unlike Nemotron-3-Super where NVIDIA blesses **both** vLLM-Marlin and TRT-LLM (see `sglang-migration-issue.md`).

There is a separate **[Qwen3.6-35B-A3B NIM container](https://catalog.ngc.nvidia.com/orgs/nim/teams/qwen/containers/qwen3.6-35b-a3b)** on NGC — but it's a different artifact: a general-purpose OpenAI-compatible microservice "powered by the SGLang backend across supported NVIDIA GPU platforms," for the base (non-NVFP4-checkpoint-specific) model. It doesn't mention DGX Spark/GB10/SM121 support explicitly, and it's not the recipe tied to our NVFP4 checkpoint — so it's not a validated alternate route for what we're running, just a fact worth knowing exists if we ever need an NVIDIA-supported managed-container path instead of hand-rolled vLLM.

## Reference: cluster commands

```bash
kubectl get pods -n default -l k8s-app=vllm-nimbus-nemotron   # same label selector routes to qwen too
kubectl logs -n default qwen-<pod-hash> --tail=100

API_KEY=$(kubectl get secret vllm-api-key -o jsonpath='{.data.api-key}' | base64 -d)
curl -s -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
  http://169.229.53.67:8000/v1/chat/completions \
  -d '{"model":"qwen","messages":[{"role":"user","content":"hi"}],"max_tokens":32}'
```
