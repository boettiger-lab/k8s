#!/usr/bin/env python3
"""Prefill/decode benchmark for Flash-Next on nimbus, sized for agentic traffic.

Runs INSIDE the vLLM pod against localhost:8000 -- deliberately, for two reasons:
it isolates server performance from Traefik/TLS/WAN, and (the one that bit an
earlier round of benchmarking on cirrus) a client killed by a tool timeout leaves
its request generating server-side, monopolising the GPU and silently corrupting
every later measurement. Launch it detached and poll the output file:

  kubectl exec -n vllm deploy/qwen38-flashnext -- \\
    bash -c 'nohup setsid python3 /tmp/bench.py > /tmp/bench.log 2>&1 & echo started'

Separates prefill from decode by streaming: TTFT is the prefill wall (the first
token cannot arrive until the whole prompt is processed), and the remaining
tokens divided by the remaining time is the true decode rate.

Two things make naive numbers wrong on this deployment:

  * Prefix caching. A repeated prompt skips prefill almost entirely, so every
    "cold" case here carries a short unique head (caching is positional, so a
    few novel tokens at the front invalidate everything after). Both regimes are
    measured, because agentic traffic is mostly WARM -- the geo-agent run on
    cirrus hit 84.9% -- so the warm row is the one that predicts real latency.
  * MTP speculative decoding. vLLM's inter_token_latency is per *step*, and a
    step emits up to 3 tokens (num_speculative_tokens=2 + 1), so deriving
    tok/s from it understates decode. Everything here is wall-clock over
    completion_tokens instead, and the MTP acceptance rate is reported
    separately from the spec_decode counters.
"""
import json, os, random, statistics, string, sys, threading, time, urllib.request

BASE = "http://localhost:8000"
KEY = os.environ["VLLM_API_KEY"]
MODEL = "qwen"
OUT = "/tmp/bench-results.json"

# Prompt sizes spanning agentic traffic. The geo-agent regression slice averaged
# ~36k prompt tokens per call (1,109,583 over 31 calls), so the middle of this
# range is the realistic centre of mass, not the top.
SIZES = [4000, 16000, 32000, 64000, 128000]
# Concurrency: the deployment runs --max-num-seqs 4, so 8 deliberately overruns
# it to show queueing rather than parallelism.
CONCURRENCY = [1, 2, 4, 8]
CONC_SIZE = 32000
GEN_TOKENS = 256

FILLER = ("Watersheds drain precipitation into river networks, and riparian "
          "buffers moderate nutrient flux across the floodplain. ")
# Ask for output long enough to measure a decode rate over. Deliberately NOT
# ignore_eos: on this checkpoint that produces meaningless throughput numbers.
TASK = ("\n\nList 60 short factual bullet points summarising the document above. "
        "One clause per bullet, no preamble.")


def post_stream(prompt, max_tokens=GEN_TOKENS, timeout=1800):
    """Return (ttft, total_s, n_chunks, usage). Streaming, so TTFT is real."""
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True,
        "stream_options": {"include_usage": True},
    }).encode()
    req = urllib.request.Request(
        BASE + "/v1/chat/completions", data=body,
        headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    t0 = time.perf_counter()
    ttft = None
    chunks = 0
    usage = {}
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                break
            try:
                d = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if d.get("usage"):
                usage = d["usage"]
            ch = d.get("choices") or []
            if ch:
                delta = ch[0].get("delta") or {}
                # This build streams thinking in `reasoning` (NOT
                # `reasoning_content`, which is the non-streaming field name),
                # and the very first chunk is a role marker carrying
                # content:"" -- falsy. Checking the wrong key here silently
                # produced ttft=None for every case and therefore no prefill
                # number at all, while decode still looked plausible.
                if delta.get("content") or delta.get("reasoning") \
                        or delta.get("reasoning_content"):
                    if ttft is None:
                        ttft = time.perf_counter() - t0
                    chunks += 1
    return ttft, time.perf_counter() - t0, chunks, usage


_TOK_PER_FILLER = None


def tokens_per_filler():
    """Calibrate against the real tokenizer instead of guessing chars/token."""
    global _TOK_PER_FILLER
    if _TOK_PER_FILLER is None:
        body = json.dumps({"model": MODEL, "prompt": FILLER * 20}).encode()
        req = urllib.request.Request(
            BASE + "/tokenize", data=body,
            headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            _TOK_PER_FILLER = json.load(r)["count"] / 20.0
    return _TOK_PER_FILLER


def make_prompt(target_tokens, cold):
    """Size against the real tokenizer; actual size is still read back from usage."""
    n = max(1, int(round(target_tokens / tokens_per_filler())))
    head = ""
    if cold:
        # Prefix caching is positional, so a few unique tokens at the very front
        # invalidate every block after them. A short head is all that is needed
        # -- an earlier version padded 9000 random chars here, which bought
        # nothing and inflated a "4k" case to 7,432 real prompt tokens.
        head = "Session %s.\n\n" % "".join(random.choices(string.ascii_lowercase, k=16))
    return head + (FILLER * n) + TASK


def metrics():
    with urllib.request.urlopen(BASE + "/metrics", timeout=30) as r:
        txt = r.read().decode()
    out = {}
    for line in txt.splitlines():
        if line.startswith("#") or " " not in line:
            continue
        name, _, val = line.rpartition(" ")
        try:
            out[name.split("{")[0]] = out.get(name.split("{")[0], 0.0) + float(val)
        except ValueError:
            pass
    return out


def spec_rate(before, after):
    d = after.get("vllm:spec_decode_num_draft_tokens_total", 0) - \
        before.get("vllm:spec_decode_num_draft_tokens_total", 0)
    a = after.get("vllm:spec_decode_num_accepted_tokens_total", 0) - \
        before.get("vllm:spec_decode_num_accepted_tokens_total", 0)
    return (a / d) if d else None


def one(prompt, label):
    m0 = metrics()
    ttft, total, chunks, usage = post_stream(prompt)
    m1 = metrics()
    pt = usage.get("prompt_tokens", 0)
    ct = usage.get("completion_tokens", 0)
    dec_s = max(total - (ttft or 0), 1e-6)
    r = {
        "label": label,
        "prompt_tokens": pt,
        "completion_tokens": ct,
        "ttft_s": round(ttft, 3) if ttft else None,
        "total_s": round(total, 3),
        # Prefill rate: the whole prompt had to be processed before token one.
        "prefill_tok_s": round(pt / ttft, 1) if ttft else None,
        # Decode rate: everything after the first token, wall-clock.
        "decode_tok_s": round((ct - 1) / dec_s, 1) if ct > 1 else None,
        "mtp_acceptance": spec_rate(m0, m1),
    }
    print(json.dumps(r), flush=True)
    return r


def concurrent(n, size):
    """n simultaneous cold streams; reports per-stream and aggregate."""
    prompts = [make_prompt(size, cold=True) for _ in range(n)]
    res, lock = [], threading.Lock()
    m0 = metrics()

    def worker(p, i):
        try:
            ttft, total, _, usage = post_stream(p)
            ct = usage.get("completion_tokens", 0)
            with lock:
                res.append({"i": i, "ttft_s": ttft, "total_s": total,
                            "prompt_tokens": usage.get("prompt_tokens", 0),
                            "completion_tokens": ct,
                            "decode_tok_s": (ct - 1) / max(total - ttft, 1e-6) if ct > 1 else None})
        except Exception as e:
            with lock:
                res.append({"i": i, "error": repr(e)})

    t0 = time.perf_counter()
    ts = [threading.Thread(target=worker, args=(p, i)) for i, p in enumerate(prompts)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    wall = time.perf_counter() - t0
    m1 = metrics()
    ok = [r for r in res if "error" not in r]
    gen = sum(r["completion_tokens"] for r in ok)
    out = {
        "concurrency": n,
        "wall_s": round(wall, 2),
        "errors": [r for r in res if "error" in r],
        "ttft_s_median": round(statistics.median([r["ttft_s"] for r in ok]), 2) if ok else None,
        "ttft_s_max": round(max(r["ttft_s"] for r in ok), 2) if ok else None,
        "decode_tok_s_per_stream_median": round(
            statistics.median([r["decode_tok_s"] for r in ok if r["decode_tok_s"]]), 1) if ok else None,
        # What the endpoint delivers in total -- the number that matters for
        # "can N people use this at once".
        "aggregate_decode_tok_s": round(gen / wall, 1) if wall else None,
        "mtp_acceptance": spec_rate(m0, m1),
    }
    print(json.dumps(out), flush=True)
    return out


def main():
    random.seed(1234)
    results = {"single_stream": [], "concurrent": []}

    print("=== single stream: cold vs warm prefix ===", flush=True)
    for size in SIZES:
        p = make_prompt(size, cold=True)
        results["single_stream"].append(one(p, f"{size//1000}k cold"))
        # Immediately repeat the identical prompt: now the prefix is cached.
        results["single_stream"].append(one(p, f"{size//1000}k warm"))
        with open(OUT, "w") as f:
            json.dump(results, f, indent=2)

    print("=== concurrency (cold, %dk each) ===" % (CONC_SIZE // 1000), flush=True)
    for n in CONCURRENCY:
        results["concurrent"].append(concurrent(n, CONC_SIZE))
        with open(OUT, "w") as f:
            json.dump(results, f, indent=2)

    print("=== done ===", flush=True)


if __name__ == "__main__":
    main()
