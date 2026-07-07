# nimbus-carbon-api Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy `nimbus-carbon-api`, a carbon-footprint dashboard/API for nimbus, forked from `nrp-carbon-api` and adapted for nimbus's single-node, single-GPU, fixed-location reality — landing at `https://carbon-nimbus.carlboettiger.info`.

**Architecture:** A small Go service (no external dependencies — stdlib only) polls the Prometheus instance from the monitoring-infra plan every 30s, computes CO2 from GPU power × a fixed grid-intensity constant, keeps 7 days of in-memory history, and serves a dashboard + JSON API. Ported from `nrp-carbon-api`, with its multi-institution/multi-node logic stripped down to nimbus's actual topology (verified empirically against nimbus's live Prometheus, not assumed).

**Tech Stack:** Go 1.22 (stdlib only, no external deps), Docker (multi-arch, native amd64+arm64 runners), Kubernetes (Deployment/Service/Ingress), GitHub Actions.

## Global Constraints

- New repo: `boettiger-lab/nimbus-carbon-api`, public, seeded from `boettiger-lab/nrp-carbon-api` (clean git history — this diverges enough that a fresh start with attribution in the README is clearer than inherited unrelated history).
- Module path: `github.com/boettiger-lab/nimbus-carbon-api` (was `github.com/boettiger-lab/carbon-api` upstream). Every internal import must be updated to match.
- Local repo path: `/home/cboettig/Documents/github/boettiger-lab/nimbus-carbon-api` (sibling to `k8s/`, matching this machine's existing `~/Documents/github/boettiger-lab/<repo>` convention).
- Go toolchain: confirmed present locally, `go version go1.22.2 linux/arm64` — matches `go.mod`'s `go 1.22.2` exactly, and matches nimbus's own architecture.
- Prometheus URL (from the already-deployed monitoring-infra plan): `http://prometheus-server.monitoring.svc.cluster.local`. Confirmed live and reachable via `kubectl -n monitoring port-forward svc/prometheus-server 9090:80`.
- **Verified live Prometheus label sets** (checked directly against nimbus's Prometheus before writing this plan — do not re-derive these from nrp-carbon-api's assumptions, they differ):
  - `vllm:generation_tokens_total` carries labels: `model_name`, `namespace="default"`, `node="nimbus"`, `service="vllm-nimbus-service"`, `job="kubernetes-service-endpoints"` — **no `container` label**.
  - `DCGM_FI_DEV_POWER_USAGE` carries labels: `namespace="default"`, `container="vllm"`, `pod`, `Hostname="nimbus"`, `modelName="NVIDIA GB10"`, `job="kubernetes-pods"` — DCGM's own kubelet pod-resources mapping supplies `namespace`/`container`/`pod` automatically (no `kubernetes.enablePodLabels` chart setting needed; that setting controls a different, unrelated feature).
  - Because these two metrics don't share a common `container` label, this plan's scraper joins on **`namespace` alone** (always `"default"` on nimbus) rather than nrp-carbon-api's `namespace+container` composite key. `GPUCount`, `GPUHardware`, and `Container` are hardcoded constants (`1`, `"NVIDIA GB10"`, `"vllm"`) rather than queried — nimbus has exactly one physical GPU and one serving container name, always.
- Grid carbon intensity: fixed constant for Berkeley, CA (CAMX eGRID 2022 subregion), **0.198 kg CO2/kWh** — same value nrp-carbon-api already uses as its California/CAMX default. No per-node lookup table.
- Verification style: this project verifies against the real, already-deployed nimbus Prometheus (port-forwarded locally), not mocks — consistent with how the monitoring-infra plan was verified. There is no existing test suite in nrp-carbon-api to extend; add focused unit tests only where logic is pure and doesn't require a live Prometheus (e.g. `internal/carbon`).
- Ingress host: `carbon-nimbus.carlboettiger.info`, same `cert-manager.io/cluster-issuer: letsencrypt-production` + `ingressClassName: traefik` + `external-dns.alpha.kubernetes.io/cloudflare-proxied: "false"` pattern as `vllm-nimbus.carlboettiger.info` (see `k8s` repo's `vllm/nimbus/ingress.yaml`). Public, no auth.
- CI: per-architecture native runners (`ubuntu-latest` for amd64, `ubuntu-24.04-arm` for arm64), build-by-digest then merge into one multi-arch manifest — the same pattern the `k8s` repo already uses (see its `.github/workflows/docker-image.yml`, commit `5350e06`). No QEMU emulation.
- Image: `ghcr.io/boettiger-lab/nimbus-carbon-api:latest`.
- Resource requests: tiny (100m CPU / 128Mi memory) — this is a lightweight poller, matching nrp-carbon-api's own deployment.

---

### Task 1: Seed the nimbus-carbon-api repository

**Files:**
- Create (new repo): `go.mod`, `README.md`, `LICENSE`, `cmd/main.go`, `cmd/static/dashboard.html`, `cmd/static/methodology.html`, `internal/carbon/intensity.go`, `internal/prom/client.go`, `internal/scraper/scraper.go`, `Dockerfile`

**Interfaces:**
- Produces: a buildable Go module at `/home/cboettig/Documents/github/boettiger-lab/nimbus-carbon-api`, pushed to `github.com/boettiger-lab/nimbus-carbon-api`, with the module path already corrected everywhere. Tasks 2-5 modify files within this repo; none of them need to touch the module path again.

- [ ] **Step 1: Create the GitHub repo**

```bash
gh repo create boettiger-lab/nimbus-carbon-api --public \
  --description "Carbon footprint tracking for LLM inference on nimbus (GB10 DGX Spark)"
```

Expected: prints the new repo's URL, `https://github.com/boettiger-lab/nimbus-carbon-api`.

- [ ] **Step 2: Seed the local working copy from nrp-carbon-api**

```bash
git clone --depth 1 https://github.com/boettiger-lab/nrp-carbon-api.git /tmp/nrp-carbon-api-seed
mkdir -p /home/cboettig/Documents/github/boettiger-lab/nimbus-carbon-api
cp -r /tmp/nrp-carbon-api-seed/. /home/cboettig/Documents/github/boettiger-lab/nimbus-carbon-api/
cd /home/cboettig/Documents/github/boettiger-lab/nimbus-carbon-api
rm -rf .git internal/dashboard k8s .github/workflows/docker.yml
rm -rf /tmp/nrp-carbon-api-seed
```

`internal/dashboard/dashboard.html` is dead code upstream — confirmed by grepping `cmd/main.go`, which only embeds `cmd/static/dashboard.html`, never anything under `internal/dashboard/`. `k8s/` and the CI workflow are removed here because Task 5 replaces both with nimbus-specific versions from scratch.

- [ ] **Step 3: Fix the module path in `go.mod`**

```go
module github.com/boettiger-lab/nimbus-carbon-api

go 1.22.2
```

- [ ] **Step 4: Fix the import path in `cmd/main.go`**

In `cmd/main.go`, change:

```go
	"github.com/boettiger-lab/carbon-api/internal/scraper"
```

to:

```go
	"github.com/boettiger-lab/nimbus-carbon-api/internal/scraper"
```

Also change the default Prometheus URL — find:

```go
	promURL := getenv("PROMETHEUS_URL", "https://prometheus.nrp-nautilus.io")
```

replace with:

```go
	promURL := getenv("PROMETHEUS_URL", "http://prometheus-server.monitoring.svc.cluster.local")
```

- [ ] **Step 5: Fix the import paths in `internal/scraper/scraper.go`**

Change:

```go
	"github.com/boettiger-lab/carbon-api/internal/carbon"
	"github.com/boettiger-lab/carbon-api/internal/prom"
```

to:

```go
	"github.com/boettiger-lab/nimbus-carbon-api/internal/carbon"
	"github.com/boettiger-lab/nimbus-carbon-api/internal/prom"
```

(Leave the rest of `scraper.go` untouched for now — Task 3 rewrites its query logic.)

- [ ] **Step 6: Write `README.md`**

```markdown
# nimbus-carbon-api

A lightweight Go service that estimates the carbon footprint of LLM
inference on `nimbus`, a single GB10 DGX Spark node
(see [boettiger-lab/k8s/vllm/nimbus](https://github.com/boettiger-lab/k8s/tree/main/vllm/nimbus)).

Based on [nrp-carbon-api](https://github.com/boettiger-lab/nrp-carbon-api)
(carbon tracking for the shared NRP Nautilus cluster), adapted for a single
fixed-location, single-GPU node: no multi-institution grid-intensity lookup,
no multi-GPU-per-pod accounting — just one GB10, one grid location
(Berkeley, CA / CAMX), and whichever model is currently deployed.

## How it works

1. **GPU power** is read from [NVIDIA DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter)
   metrics, collected by nimbus's own Prometheus
   (see [boettiger-lab/k8s/monitoring](https://github.com/boettiger-lab/k8s/tree/main/monitoring)).
2. **Token throughput** is read from vLLM's built-in Prometheus metrics.
3. **Grid carbon intensity** is a fixed constant for Berkeley, CA (CAMX
   eGRID 2022 subregion, 0.198 kg CO2/kWh) — see `internal/carbon/intensity.go`.

Carbon = Energy × Grid Intensity. See the
[Methodology](https://carbon-nimbus.carlboettiger.info/methodology) page for
full details.

## Running locally

```bash
export PROMETHEUS_URL=http://prometheus-server.monitoring.svc.cluster.local
go run ./cmd
# → http://localhost:8080
```

## Deploying

```bash
docker build -t ghcr.io/boettiger-lab/nimbus-carbon-api:latest .
docker push ghcr.io/boettiger-lab/nimbus-carbon-api:latest
kubectl apply -f k8s/deployment.yaml
kubectl rollout restart deployment/nimbus-carbon-api
```

## API

| Endpoint | Description |
|---|---|
| `GET /api/v1/carbon` | Current metrics for the active model |
| `GET /api/v1/carbon/timeseries?range=24h\|7d\|30d` | CO2 and power time series |
| `GET /api/v1/carbon/{ns}/{container}/{metric}?range=...` | Per-model time series (`power_watts`, `co2_grams_per_hour`, `co2_mg_per_token`) — useful for comparing models tried over time on the same hardware |
| `GET /healthz` | Health check |

## License

[BSD 2-Clause](LICENSE)
```

- [ ] **Step 7: Verify it builds**

```bash
cd /home/cboettig/Documents/github/boettiger-lab/nimbus-carbon-api
go build ./...
go vet ./...
```

Expected: both commands exit 0 with no output (no external dependencies to fetch — `go.mod` has no `require` block).

- [ ] **Step 8: Commit and push**

```bash
git init
git add -A
git commit -m "Seed nimbus-carbon-api from nrp-carbon-api

Based on github.com/boettiger-lab/nrp-carbon-api, adapted for nimbus's
single-node, single-GPU, fixed-location topology. Module path and
Prometheus default updated; dead code (internal/dashboard) and
NRP-specific k8s/CI removed pending nimbus-specific replacements."
git branch -M main
git remote add origin https://github.com/boettiger-lab/nimbus-carbon-api.git
git push -u origin main
```

---

### Task 2: Fixed grid carbon intensity for Berkeley, CA

**Files:**
- Modify: `internal/carbon/intensity.go`
- Create: `internal/carbon/intensity_test.go`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `carbon.BerkeleyIntensity` (float64 constant, `0.198`), `carbon.GramsPerHour(watts, intensity float64) float64`, `carbon.MgPerToken(watts, intensity, tokensPerSec float64) float64` — Task 3's scraper calls all three.

- [ ] **Step 1: Write the failing test**

Create `internal/carbon/intensity_test.go`:

```go
package carbon

import "testing"

func TestBerkeleyIntensity(t *testing.T) {
	if BerkeleyIntensity != 0.198 {
		t.Errorf("BerkeleyIntensity = %v, want 0.198", BerkeleyIntensity)
	}
}

func TestGramsPerHour(t *testing.T) {
	got := GramsPerHour(100, BerkeleyIntensity)
	want := 19.8
	if got != want {
		t.Errorf("GramsPerHour(100, %v) = %v, want %v", BerkeleyIntensity, got, want)
	}
}

func TestMgPerToken(t *testing.T) {
	got := MgPerToken(100, BerkeleyIntensity, 50)
	want := 100 * BerkeleyIntensity * 0.2778 / 50
	if got != want {
		t.Errorf("MgPerToken(100, %v, 50) = %v, want %v", BerkeleyIntensity, got, want)
	}

	if z := MgPerToken(100, BerkeleyIntensity, 0); z != 0 {
		t.Errorf("MgPerToken with 0 tokens/sec = %v, want 0", z)
	}
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/cboettig/Documents/github/boettiger-lab/nimbus-carbon-api
go test ./internal/carbon/...
```

Expected: FAIL — `undefined: BerkeleyIntensity` (the old file still has `IntensityForNode`/`NRPDefault`/the region map, not this constant).

- [ ] **Step 3: Replace `internal/carbon/intensity.go`**

```go
// Package carbon provides carbon-emission calculations for nimbus.
//
// nimbus is a single, fixed-location GB10 DGX Spark hosted in Berkeley, CA,
// on the CAMX eGRID subregion — the same California grid nrp-carbon-api
// uses as its own California/CAMX default. Unlike nrp-carbon-api (which
// spans institutions across the US and looks up intensity per node),
// nimbus has exactly one node, so the intensity is a fixed constant, not
// a lookup table.
//
// Reference: https://www.epa.gov/egrid
package carbon

// BerkeleyIntensity is the grid carbon intensity for Berkeley, CA (CAMX
// eGRID 2022 subregion).
const BerkeleyIntensity = 0.198 // kg CO2/kWh — CAMX (California)

// GramsPerHour returns grams of CO2 emitted per hour for a given
// power draw (watts) and grid carbon intensity (kg CO2/kWh).
//
//	g/hr = W / 1000 kW  ×  intensity kg/kWh  ×  1000 g/kg
//	     = W × intensity × 1.0
func GramsPerHour(powerWatts, intensityKgPerKWh float64) float64 {
	return powerWatts * intensityKgPerKWh
}

// MgPerToken returns milligrams of CO2 per token (total: prompt + generation).
//
//	mg/token = (W / 3.6e6 kWh/s) × intensity kg/kWh × 1e6 mg/kg / (tokens/s)
//	         = W × intensity × (1e6 / 3.6e6) / tokensPerSec
//	         = W × intensity × 0.2778 / tokensPerSec
func MgPerToken(powerWatts, intensityKgPerKWh, tokensPerSec float64) float64 {
	if tokensPerSec <= 0 {
		return 0
	}
	return powerWatts * intensityKgPerKWh * 0.2778 / tokensPerSec
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
go test ./internal/carbon/... -v
```

Expected: `PASS`, all 3 tests (`TestBerkeleyIntensity`, `TestGramsPerHour`, `TestMgPerToken`) green.

- [ ] **Step 5: Confirm the whole module still builds**

```bash
go build ./...
```

Expected: fails at this point — `internal/scraper/scraper.go` still calls the now-deleted `carbon.IntensityForNode` and `carbon.NRPDefault`. That's expected; Task 3 fixes it. Note the exact error in your report so Task 3's implementer isn't surprised.

- [ ] **Step 6: Commit**

```bash
git add internal/carbon/intensity.go internal/carbon/intensity_test.go
git commit -m "carbon: replace multi-region eGRID lookup with fixed Berkeley/CAMX constant"
git push
```

---

### Task 3: Rewrite scraper queries for nimbus's topology

**Files:**
- Modify: `internal/scraper/scraper.go` (full-file replacement — nearly every function's PromQL query or key-construction logic changes)

**Interfaces:**
- Consumes: `carbon.BerkeleyIntensity`, `carbon.GramsPerHour`, `carbon.MgPerToken` (Task 2).
- Produces: `scraper.New(promURL string, interval time.Duration) *Scraper`, `(*Scraper).Run()`, `(*Scraper).Models() []*ModelMetrics`, `(*Scraper).Series(namespace, container, metric string, since time.Duration) [][2]interface{}`, `(*Scraper).ClusterTimeSeries(rangeBack, step time.Duration) ([]ClusterTimePoint, error)` — Task 1's `cmd/main.go` already calls all of these; signatures are unchanged from upstream, only internals change.

This task fixes the real mismatch found by checking nimbus's live Prometheus labels directly (see Global Constraints): `vllm:generation_tokens_total` has no `container` label, but `DCGM_FI_DEV_POWER_USAGE` does (`container="vllm"`, supplied automatically by dcgm-exporter's kubelet pod-resources mapping). nrp-carbon-api's `namespace+container` join key would silently produce zero results on nimbus. The fix: join on `namespace` alone (always `"default"`), and hardcode the always-true facts about nimbus's hardware (1 GPU, `"NVIDIA GB10"`, container `"vllm"`) instead of querying for them.

- [ ] **Step 1: Replace `internal/scraper/scraper.go` in full**

```go
package scraper

import (
	"log"
	"math"
	"sync"
	"time"

	"github.com/boettiger-lab/nimbus-carbon-api/internal/carbon"
	"github.com/boettiger-lab/nimbus-carbon-api/internal/prom"
)

// nimbus is a single node with exactly one physical GPU (a GB10) and one
// serving container ("vllm", shared by every model deployment — see
// boettiger-lab/k8s/vllm/nimbus/deploy-*.yaml). These are fixed facts, not
// queried, unlike nrp-carbon-api which discovers GPU count/hardware and
// container name per pod across many nodes.
const (
	nimbusNamespace   = "default"
	nimbusGPUCount    = 1
	nimbusGPUHardware = "NVIDIA GB10"
	nimbusContainer   = "vllm"
)

// ModelMetrics holds the latest carbon and performance metrics for the
// currently-active model on nimbus.
type ModelMetrics struct {
	// Identity
	ModelName   string `json:"model_name"`
	Namespace   string `json:"namespace"`
	Container   string `json:"container"`
	GPUHardware string `json:"gpu_hardware"`
	Node        string `json:"node"`

	// Raw
	GPUCount               int     `json:"gpu_count"`
	PowerWatts             float64 `json:"power_watts"`
	PromptTokensPerSec     float64 `json:"prompt_tokens_per_sec"`     // input (prefill) token rate
	GenerationTokensPerSec float64 `json:"generation_tokens_per_sec"` // output (decode) token rate
	TokensPerSec           float64 `json:"tokens_per_sec"`            // total = prompt + generation

	// Carbon
	CarbonIntensity     float64 `json:"carbon_intensity_kg_per_kwh"`
	CO2GramsPerHour     float64 `json:"co2_grams_per_hour"`
	CO2MgPerToken       float64 `json:"co2_mg_per_token,omitempty"`         // 0 when idle (5-min window, ≥5 tok/s)
	CO2MgPerTokenAvg24h float64 `json:"co2_mg_per_token_avg_24h,omitempty"` // token-weighted 24h mean, active periods only
	CO2MgPerTokenAvg7d  float64 `json:"co2_mg_per_token_avg_7d,omitempty"`  // token-weighted 7-day mean, active periods only

	// Time-weighted 24h means (all samples, active + idle).
	PowerWattsAvg24h             float64 `json:"power_watts_avg_24h,omitempty"`
	PromptTokensPerSecAvg24h     float64 `json:"prompt_tokens_per_sec_avg_24h,omitempty"`
	GenerationTokensPerSecAvg24h float64 `json:"generation_tokens_per_sec_avg_24h,omitempty"`

	UpdatedAt time.Time `json:"updated_at"`
}

// History is a fixed-size ring buffer of (time, value) pairs per metric.
type dataPoint struct {
	T time.Time
	V float64
}

// avgBucket holds one hour of aggregates: a token-weighted CO₂/token mean
// (active samples only) plus time-weighted means for power, prompt tok/s,
// and generation tok/s (every reporting sample, active or idle).
type avgBucket struct {
	Hour         int64
	WeightedSum  float64
	TokenSum     float64
	PowerSum     float64
	PromptTokSum float64
	GenTokSum    float64
	SampleCount  int
}

const maxBuckets = 168    // 7 days of hourly buckets
const maxHistory = 20160  // 7 days at 30s scrape intervals (for Series endpoint ring buffers)

type modelHistory struct {
	PowerWatts      []dataPoint
	CO2GramsPerHour []dataPoint
	CO2MgPerToken   []dataPoint
	AvgBuckets      []avgBucket
}

func (h *modelHistory) append(now time.Time, m *ModelMetrics) {
	push := func(buf *[]dataPoint, v float64) {
		*buf = append(*buf, dataPoint{T: now, V: v})
		if len(*buf) > maxHistory {
			*buf = (*buf)[len(*buf)-maxHistory:]
		}
	}
	push(&h.PowerWatts, m.PowerWatts)
	push(&h.CO2GramsPerHour, m.CO2GramsPerHour)
	if m.CO2MgPerToken > 0 {
		push(&h.CO2MgPerToken, m.CO2MgPerToken)
	}
	h.addSample(now, m.PowerWatts, m.PromptTokensPerSec, m.GenerationTokensPerSec, m.CarbonIntensity)
}

func (h *modelHistory) addSample(t time.Time, power, promptTok, genTok, intensity float64) {
	if power <= 0 {
		return
	}
	totalTok := promptTok + genTok
	var co2Weight, co2Tokens float64
	if totalTok > 5.0 {
		co2PerToken := carbon.MgPerToken(power, intensity, totalTok)
		co2Weight = co2PerToken * totalTok
		co2Tokens = totalTok
	}
	hourKey := t.Truncate(time.Hour).Unix()
	for i := len(h.AvgBuckets) - 1; i >= 0; i-- {
		if h.AvgBuckets[i].Hour == hourKey {
			b := &h.AvgBuckets[i]
			b.WeightedSum += co2Weight
			b.TokenSum += co2Tokens
			b.PowerSum += power
			b.PromptTokSum += promptTok
			b.GenTokSum += genTok
			b.SampleCount++
			return
		}
	}
	h.AvgBuckets = append(h.AvgBuckets, avgBucket{
		Hour:         hourKey,
		WeightedSum:  co2Weight,
		TokenSum:     co2Tokens,
		PowerSum:     power,
		PromptTokSum: promptTok,
		GenTokSum:    genTok,
		SampleCount:  1,
	})
	if len(h.AvgBuckets) > maxBuckets {
		h.AvgBuckets = h.AvgBuckets[len(h.AvgBuckets)-maxBuckets:]
	}
}

// Scraper polls Prometheus and maintains in-memory state. Keyed by
// namespace alone (always "default" on nimbus) — see package comment.
type Scraper struct {
	client   *prom.Client
	interval time.Duration

	mu      sync.RWMutex
	models  map[string]*ModelMetrics
	history map[string]*modelHistory
}

func New(promURL string, interval time.Duration) *Scraper {
	return &Scraper{
		client:   prom.NewClient(promURL, 30*time.Second),
		interval: interval,
		models:   make(map[string]*ModelMetrics),
		history:  make(map[string]*modelHistory),
	}
}

func (s *Scraper) Run() {
	s.scrape()
	s.backfill()
	t := time.NewTicker(s.interval)
	defer t.Stop()
	for range t.C {
		s.scrape()
	}
}

// backfill queries Prometheus for 7 days of historical power and token data
// and seeds the hourly average buckets so that 24h/7d averages are
// immediately correct after a restart, rather than starting from zero.
func (s *Scraper) backfill() {
	log.Println("scraper: backfilling 7-day averages from Prometheus...")
	end := time.Now()
	start := end.Add(-7 * 24 * time.Hour)
	step := 5 * time.Minute

	powerSeries, err := s.client.RangeQuery(
		`sum by (namespace) (DCGM_FI_DEV_POWER_USAGE{namespace="default"})`,
		start, end, step,
	)
	if err != nil {
		log.Printf("scraper: backfill power query failed: %v", err)
		return
	}
	promptSeries, err := s.client.RangeQuery(
		`sum by (namespace) (rate(vllm:prompt_tokens_total{namespace="default"}[5m]))`,
		start, end, step,
	)
	if err != nil {
		log.Printf("scraper: backfill prompt token query failed: %v", err)
		return
	}
	genSeries, err := s.client.RangeQuery(
		`sum by (namespace) (rate(vllm:generation_tokens_total{namespace="default"}[5m]))`,
		start, end, step,
	)
	if err != nil {
		log.Printf("scraper: backfill generation token query failed: %v", err)
		return
	}

	type sample struct{ power, promptTok, genTok float64 }
	byKeyTime := make(map[string]map[int64]*sample)

	for _, sr := range powerSeries {
		key := sr.Metric["namespace"]
		if byKeyTime[key] == nil {
			byKeyTime[key] = make(map[int64]*sample)
		}
		for _, pt := range sr.Points {
			ts := pt.Time.Unix()
			if byKeyTime[key][ts] == nil {
				byKeyTime[key][ts] = &sample{}
			}
			byKeyTime[key][ts].power += pt.Value
		}
	}
	for _, sr := range promptSeries {
		key := sr.Metric["namespace"]
		if byKeyTime[key] == nil {
			byKeyTime[key] = make(map[int64]*sample)
		}
		for _, pt := range sr.Points {
			ts := pt.Time.Unix()
			if byKeyTime[key][ts] == nil {
				byKeyTime[key][ts] = &sample{}
			}
			byKeyTime[key][ts].promptTok += pt.Value
		}
	}
	for _, sr := range genSeries {
		key := sr.Metric["namespace"]
		if byKeyTime[key] == nil {
			byKeyTime[key] = make(map[int64]*sample)
		}
		for _, pt := range sr.Points {
			ts := pt.Time.Unix()
			if byKeyTime[key][ts] == nil {
				byKeyTime[key][ts] = &sample{}
			}
			byKeyTime[key][ts].genTok += pt.Value
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	for key, timestamps := range byKeyTime {
		if s.history[key] == nil {
			s.history[key] = &modelHistory{}
		}
		h := s.history[key]
		for ts, samp := range timestamps {
			if samp.power <= 0 {
				continue
			}
			h.addSample(time.Unix(ts, 0), samp.power, samp.promptTok, samp.genTok, carbon.BerkeleyIntensity)
		}
	}

	log.Printf("scraper: backfilled %d key(s) from Prometheus", len(byKeyTime))
}

// Models returns a snapshot of all current model metrics.
func (s *Scraper) Models() []*ModelMetrics {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]*ModelMetrics, 0, len(s.models))
	for _, m := range s.models {
		cp := *m
		out = append(out, &cp)
	}
	return out
}

// Series returns the history for a namespace/metric combination.
// container is accepted for API-compatibility with the
// /api/v1/carbon/{ns}/{container}/{metric} route but is otherwise unused —
// nimbus has exactly one container ("vllm") per namespace, always.
// metric is one of "power_watts", "co2_grams_per_hour", "co2_mg_per_token".
func (s *Scraper) Series(namespace, container, metric string, since time.Duration) [][2]interface{} {
	_ = container
	s.mu.RLock()
	h, ok := s.history[namespace]
	s.mu.RUnlock()
	if !ok {
		return nil
	}

	cutoff := time.Now().Add(-since)
	var buf []dataPoint
	switch metric {
	case "power_watts":
		buf = h.PowerWatts
	case "co2_grams_per_hour":
		buf = h.CO2GramsPerHour
	case "co2_mg_per_token":
		buf = h.CO2MgPerToken
	default:
		return nil
	}

	var out [][2]interface{}
	for _, p := range buf {
		if p.T.After(cutoff) {
			out = append(out, [2]interface{}{p.T.Unix(), p.V})
		}
	}
	return out
}

// ---- internal ----

func (s *Scraper) scrape() {
	powerByKey, err := s.queryPower()
	if err != nil {
		log.Printf("scraper: power query failed: %v", err)
	}

	genTokensByKey, promptTokensByKey, modelNameByKey, err := s.queryTokens()
	if err != nil {
		log.Printf("scraper: token query failed: %v", err)
	}

	keys := make(map[string]struct{})
	for k := range powerByKey {
		keys[k] = struct{}{}
	}
	for k := range genTokensByKey {
		keys[k] = struct{}{}
	}
	for k := range promptTokensByKey {
		keys[k] = struct{}{}
	}

	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()

	for key := range keys {
		power := powerByKey[key]
		intensity := carbon.BerkeleyIntensity

		genTok := genTokensByKey[key]
		promptTok := promptTokensByKey[key]
		totalTok := genTok + promptTok
		modelName := modelNameByKey[key]

		co2PerHour := carbon.GramsPerHour(power, intensity)
		co2PerToken := 0.0
		if totalTok > 5.0 {
			co2PerToken = carbon.MgPerToken(power, intensity, totalTok)
		}

		m := &ModelMetrics{
			ModelName:              modelName,
			Namespace:              key,
			Container:              nimbusContainer,
			GPUHardware:            nimbusGPUHardware,
			Node:                   "nimbus",
			GPUCount:               nimbusGPUCount,
			PowerWatts:             math.Round(power*10) / 10,
			PromptTokensPerSec:     math.Round(promptTok*10) / 10,
			GenerationTokensPerSec: math.Round(genTok*10) / 10,
			TokensPerSec:           math.Round(totalTok*10) / 10,
			CarbonIntensity:        intensity,
			CO2GramsPerHour:        math.Round(co2PerHour*10) / 10,
			UpdatedAt:              now,
		}
		if co2PerToken > 0 {
			m.CO2MgPerToken = math.Round(co2PerToken*1000) / 1000
		}

		s.models[key] = m

		if s.history[key] == nil {
			s.history[key] = &modelHistory{}
		}
		h := s.history[key]
		h.append(now, m)

		var wSum24, tSum24, wSum7d, tSum7d float64
		var powSum24, promptSum24, genSum24 float64
		var nSum24 int
		cutoff24h := now.Add(-24 * time.Hour).Truncate(time.Hour).Unix()
		cutoff7d := now.Add(-7 * 24 * time.Hour).Truncate(time.Hour).Unix()
		for _, b := range h.AvgBuckets {
			if b.Hour >= cutoff7d {
				wSum7d += b.WeightedSum
				tSum7d += b.TokenSum
			}
			if b.Hour >= cutoff24h {
				wSum24 += b.WeightedSum
				tSum24 += b.TokenSum
				powSum24 += b.PowerSum
				promptSum24 += b.PromptTokSum
				genSum24 += b.GenTokSum
				nSum24++
			}
		}
		if tSum24 > 0 {
			m.CO2MgPerTokenAvg24h = math.Round(wSum24/tSum24*1000) / 1000
		}
		if tSum7d > 0 {
			m.CO2MgPerTokenAvg7d = math.Round(wSum7d/tSum7d*1000) / 1000
		}
		if nSum24 > 0 {
			n := float64(nSum24)
			m.PowerWattsAvg24h = math.Round(powSum24/n*10) / 10
			m.PromptTokensPerSecAvg24h = math.Round(promptSum24/n*10) / 10
			m.GenerationTokensPerSecAvg24h = math.Round(genSum24/n*10) / 10
		}
	}
}

// queryPower returns total GPU power (W) keyed by namespace.
func (s *Scraper) queryPower() (map[string]float64, error) {
	results, err := s.client.Query(
		`sum by (namespace) (avg_over_time(DCGM_FI_DEV_POWER_USAGE{namespace="default"}[5m]))`,
	)
	if err != nil {
		return nil, err
	}

	power := make(map[string]float64)
	for _, r := range results {
		power[r.Metric["namespace"]] += r.Value
	}
	return power, nil
}

// queryTokens returns 5-minute prompt and generation token rates keyed by
// namespace, plus the vLLM model_name label for whichever model is
// currently reporting traffic.
func (s *Scraper) queryTokens() (genTokens, promptTokens map[string]float64, names map[string]string, err error) {
	genResults, err := s.client.Query(
		`sum by (namespace, model_name) (rate(vllm:generation_tokens_total{namespace="default"}[5m]))`,
	)
	if err != nil {
		return nil, nil, nil, err
	}
	promptResults, err := s.client.Query(
		`sum by (namespace, model_name) (rate(vllm:prompt_tokens_total{namespace="default"}[5m]))`,
	)
	if err != nil {
		return nil, nil, nil, err
	}

	genTokens = make(map[string]float64)
	promptTokens = make(map[string]float64)
	names = make(map[string]string)
	for _, r := range genResults {
		key := r.Metric["namespace"]
		genTokens[key] += r.Value
		if names[key] == "" {
			names[key] = r.Metric["model_name"]
		}
	}
	for _, r := range promptResults {
		key := r.Metric["namespace"]
		promptTokens[key] += r.Value
		if names[key] == "" {
			names[key] = r.Metric["model_name"]
		}
	}
	return genTokens, promptTokens, names, nil
}

// ClusterTimePoint is one time-step of aggregated cluster-wide carbon data.
type ClusterTimePoint struct {
	Timestamp       int64   `json:"t"`
	PowerWatts      float64 `json:"power_watts"`
	CO2GramsPerHour float64 `json:"co2_grams_per_hour"`
	CO2MgPerToken   float64 `json:"co2_mg_per_token,omitempty"`
}

// ClusterTimeSeries queries Prometheus for historical power + token data and
// returns aggregated totals per time step, using the fixed Berkeley intensity.
func (s *Scraper) ClusterTimeSeries(rangeBack, step time.Duration) ([]ClusterTimePoint, error) {
	end := time.Now()
	start := end.Add(-rangeBack)

	powerSeries, err := s.client.RangeQuery(
		`sum by (namespace) (DCGM_FI_DEV_POWER_USAGE{namespace="default"})`,
		start, end, step,
	)
	if err != nil {
		return nil, err
	}
	tokenSeries, err := s.client.RangeQuery(
		`sum by (namespace) (rate(vllm:generation_tokens_total{namespace="default"}[5m]) + rate(vllm:prompt_tokens_total{namespace="default"}[5m]))`,
		start, end, step,
	)
	if err != nil {
		return nil, err
	}

	type agg struct{ power, co2, tokens float64 }
	byTime := make(map[int64]*agg)

	for _, sr := range powerSeries {
		for _, pt := range sr.Points {
			ts := pt.Time.Unix()
			if byTime[ts] == nil {
				byTime[ts] = &agg{}
			}
			byTime[ts].power += pt.Value
			byTime[ts].co2 += carbon.GramsPerHour(pt.Value, carbon.BerkeleyIntensity)
		}
	}
	for _, sr := range tokenSeries {
		for _, pt := range sr.Points {
			ts := pt.Time.Unix()
			if byTime[ts] == nil {
				byTime[ts] = &agg{}
			}
			byTime[ts].tokens += pt.Value
		}
	}

	out := make([]ClusterTimePoint, 0, len(byTime))
	for ts, a := range byTime {
		pt := ClusterTimePoint{
			Timestamp:       ts,
			PowerWatts:      math.Round(a.power*10) / 10,
			CO2GramsPerHour: math.Round(a.co2*10) / 10,
		}
		if a.tokens > 0.1 {
			pt.CO2MgPerToken = math.Round(a.co2/a.tokens/3.6*1000) / 1000
		}
		out = append(out, pt)
	}
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].Timestamp < out[j-1].Timestamp; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out, nil
}
```

Note what was deliberately dropped versus upstream: `queryGPUInfo()` (GPU count/hardware are hardcoded constants now — always 1× GB10), the `Hostname`/node-based intensity lookup (replaced by the fixed constant), and `splitKey()` (no longer needed — the map key IS the namespace, no composite to split).

- [ ] **Step 2: Verify it builds**

```bash
go build ./...
go vet ./...
```

Expected: both exit 0 (this also resolves the Task 2 Step 5 build failure, since the deleted `carbon.IntensityForNode`/`carbon.NRPDefault` calls are gone).

- [ ] **Step 3: Verify against the live Prometheus**

```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 3
PROMETHEUS_URL=http://localhost:9090 SCRAPE_INTERVAL=10s go run ./cmd &
APP_PID=$!
sleep 15
curl -s http://localhost:8080/api/v1/carbon | python3 -m json.tool
kill $APP_PID
kill %1
```

Expected: JSON with one entry under `models`, `namespace: "default"`, `container: "vllm"`, `gpu_hardware: "NVIDIA GB10"`, `gpu_count: 1`, `model_name: "qwen"` (or whichever model is currently deployed), a nonzero `power_watts` (~10-15W if idle), and `carbon_intensity_kg_per_kwh: 0.198`.

- [ ] **Step 4: Commit**

```bash
git add internal/scraper/scraper.go
git commit -m "scraper: join on namespace alone; hardcode nimbus's fixed GPU/container facts

Fixes a real mismatch found against nimbus's live Prometheus: vllm:generation_tokens_total
carries no container label, but DCGM_FI_DEV_POWER_USAGE does (container=\"vllm\", from
dcgm-exporter's own kubelet pod-resources mapping) — nrp-carbon-api's namespace+container
join key would silently return zero results here."
git push
```

---

### Task 4: Rebrand the dashboard and methodology pages

**Files:**
- Modify: `cmd/static/dashboard.html`
- Modify: `cmd/static/methodology.html`

**Interfaces:**
- Consumes: nothing from other tasks (pure HTML/CSS/JS, embedded verbatim by `cmd/main.go` via `go:embed`, already wired up since Task 1).
- Produces: nothing other tasks depend on — this is the last content-only task before containerizing.

- [ ] **Step 1: Dashboard title**

In `cmd/static/dashboard.html`, change:

```html
<title>NRP Carbon Dashboard</title>
```

to:

```html
<title>nimbus Carbon Dashboard</title>
```

- [ ] **Step 2: Dashboard header — drop the NRP-specific LLM Status link, retitle, fix GitHub link**

Change:

```html
<header>
  <h1>NRP <span>Carbon</span> Dashboard</h1>
  <div class="header-right">
    <a class="method-link" href="/methodology">Methodology</a>
    <a class="method-link" href="https://nrp.ai/llm-status/" target="_blank">LLM Status</a>
    <a class="method-link" href="https://github.com/boettiger-lab/nrp-carbon-api" target="_blank">GitHub</a>
    <button id="theme-btn" onclick="toggleTheme()">Light</button>
    <span id="status">loading…</span>
  </div>
</header>
```

to:

```html
<header>
  <h1>nimbus <span>Carbon</span> Dashboard</h1>
  <div class="header-right">
    <a class="method-link" href="/methodology">Methodology</a>
    <a class="method-link" href="https://github.com/boettiger-lab/nimbus-carbon-api" target="_blank">GitHub</a>
    <button id="theme-btn" onclick="toggleTheme()">Light</button>
    <span id="status">loading…</span>
  </div>
</header>
```

- [ ] **Step 3: Workload-note text**

Change:

```html
  <div class="workload-note" id="bar-note">Green bars: NRP measured CO₂/token. Green ◆: current 5-min rate. Red ✕: what a commercial frontier model (~1.5T MoE on 24× H100) would emit on the <em>same grid</em>. <a href="/methodology" style="color:var(--accent)">Methodology</a></div>
```

to:

```html
  <div class="workload-note" id="bar-note">Green bars: nimbus measured CO₂/token. Green ◆: current 5-min rate. Red ✕: what a commercial frontier model (~1.5T MoE on 24× H100) would emit on the <em>same grid</em>. <a href="/methodology" style="color:var(--accent)">Methodology</a></div>
```

- [ ] **Step 4: Footer — drop the public-Prometheus and LLM-Status links, fix GitHub link**

Change:

```html
<footer>
  Data from <a href="https://prometheus.nrp-nautilus.io" target="_blank">NRP Prometheus</a> (DCGM GPU sensors) ·
  Grid intensity: <a href="https://www.epa.gov/egrid" target="_blank">EPA eGRID 2022</a> ·
  <a href="https://nrp.ai/llm-status/" target="_blank">NRP LLM Status</a> ·
  <a href="/methodology">Methodology &amp; References</a> ·
  <a href="https://github.com/boettiger-lab/nrp-carbon-api" target="_blank">Source on GitHub</a> ·
  Refreshes every 30 s
</footer>
```

to:

```html
<footer>
  Data from nimbus's own Prometheus (DCGM GPU sensors) ·
  Grid intensity: <a href="https://www.epa.gov/egrid" target="_blank">EPA eGRID 2022</a> ·
  <a href="/methodology">Methodology &amp; References</a> ·
  <a href="https://github.com/boettiger-lab/nimbus-carbon-api" target="_blank">Source on GitHub</a> ·
  Refreshes every 30 s
</footer>
```

(nimbus's Prometheus is internal-only — no public URL to link to, unlike NRP's.)

- [ ] **Step 5: Drop the "institution" field from model cards**

Find and delete this line entirely (it derives a per-node hostname string that's meaningless when there's only one possible node):

```html
    const institution = m.node ? m.node.split('.').slice(-3).join('.') : '—';
```

Then in the card-meta block, change:

```html
        <span>${institution}</span>${promptPct != null ? `<span>${fmt(promptPct,0)}% input tokens</span>` : ''}
```

to:

```html
        ${promptPct != null ? `<span>${fmt(promptPct,0)}% input tokens</span>` : ''}
```

- [ ] **Step 6: Replace the multi-region `locationLabel` function with a fixed label**

Find this block (the `LOCATION_PATTERNS` array plus the function that scans it):

```html
// Human-readable location from hostname + intensity value.
// Returns e.g. "SDSC · California (CAMX)" or "US average (fallback)"
const LOCATION_PATTERNS = [
  [/\.sdsc\./,     'SDSC · California',      'CAMX'],
  [/\.csus\./,     'Cal State Sacramento',   'CAMX'],
  [/\.humboldt\./,'Cal Poly Humboldt',       'CAMX'],
  [/\.caltech\./,  'Caltech',                'CAMX'],
  [/\.ucsd\./,     'UCSD',                   'CAMX'],
  [/\.ucla\./,     'UCLA',                   'CAMX'],
  [/\.ucsb\./,     'UCSB',                   'CAMX'],
  [/csumb\./,      'Cal State Monterey Bay', 'CAMX'],
  [/\.unl\./,      'UNL · Nebraska',         'MROW'],
  [/\.nyu\./,      'NYU · New York',         'NYUP'],
  [/\.utexas\./,   'UT Austin',              'ERCO'],
  [/\.tacc\./,     'TACC · Texas',           'ERCO'],
  [/\.hawaii\./,   'Univ. Hawaii',           'HIOA'],
  [/\.clemson\./,  'Clemson',                'SRSO'],
  [/\.ksu\./,      'K-State · Kansas',       'SPSO'],
  [/\.kreonet\./,  'KREONET · Korea',        '—'],
];
function locationLabel(hostname) {
  if (!hostname) return 'Unknown location';
  const h = hostname.toLowerCase();
  for (const [re, inst, region] of LOCATION_PATTERNS) {
    if (re.test(h)) return `${inst} · <a href="/methodology" style="color:inherit;text-decoration:none">${region}</a>`;
  }
  return 'Unknown · US avg (fallback)';
}
```

with:

```html
// nimbus has exactly one fixed location — Berkeley, CA (CAMX eGRID
// subregion) — so this is a constant, not a lookup. hostname is accepted
// (and ignored) to keep the call site at the model card unchanged.
function locationLabel(hostname) {
  return 'Berkeley, CA · <a href="/methodology" style="color:inherit;text-decoration:none">CAMX</a>';
}
```

- [ ] **Step 7: Sweep remaining "NRP" mentions in prose/comments**

Every remaining occurrence of the standalone word "NRP" in `cmd/static/dashboard.html` is either a comment or a user-visible string describing the same measured-power-vs-frontier comparison logic (unchanged) — swap "NRP" → "nimbus" (lowercase, matching this file's own established brand style for "nimbus Carbon Dashboard"). Do **not** touch internal JS identifiers like `nrpW`, `FRONTIER`, `frontierWatts` — only literal comment text and user-visible strings. After Steps 1-6 above, the remaining occurrences are:

- `/* NRP measured bar */` (a CSS comment) → `/* nimbus measured bar */`
- `// For each NRP model we ask: "What would a commercial frontier cluster draw to serve the same tokens?"` → `// For each nimbus model we ask: ...`
- `//   At low batch (B≈1–4, matching typical NRP traffic): ~100–150 W above idle per GPU.` → `... matching typical nimbus traffic ...`
- `// Card border: energy ratio (NRP / Commercial frontier equivalent).` → `// Card border: energy ratio (nimbus / Commercial frontier equivalent).`
- `<div class="token-cmp-label">Power (${windowLabel}): NRP vs. ${FRONTIER.label} for same tokens</div>` → `... nimbus vs. ${FRONTIER.label} ...`
- `<span style="color:#22c55e">NRP: ${nrpW.toLocaleString(...)}...</span>` → `<span style="color:#22c55e">nimbus: ${nrpW.toLocaleString(...)}...</span>`

Run this check after editing to confirm nothing was missed or over-corrected:

```bash
grep -n "NRP" cmd/static/dashboard.html
```

Expected: no output (every occurrence handled above; if this prints a line, it's either a leftover you missed or a case this brief didn't anticipate — read it and use judgment, but do not touch `nrp-carbon-api` inside the GitHub attribution link if one remains anywhere unexpected).

- [ ] **Step 8: Methodology page — title, header, overview**

In `cmd/static/methodology.html`, change:

```html
<title>Methodology — NRP Carbon Dashboard</title>
```

to:

```html
<title>Methodology — nimbus Carbon Dashboard</title>
```

Change:

```html
<header>
  <a href="/">← Dashboard</a>
  <h1>NRP <span>Carbon</span> — Methodology</h1>
</header>
<main>

<h2>Overview</h2>
<p>
  This dashboard estimates the carbon footprint of large language model (LLM) inference
  running on the <a href="https://nrp.ai" target="_blank">National Research Platform (NRP) Nautilus</a> cluster.
  All measurements are derived passively from existing telemetry — no instrumentation of
  the LLM services is required.
</p>
```

to:

```html
<header>
  <a href="/">← Dashboard</a>
  <h1>nimbus <span>Carbon</span> — Methodology</h1>
</header>
<main>

<h2>Overview</h2>
<p>
  This dashboard estimates the carbon footprint of large language model (LLM) inference
  running on <code>nimbus</code>, a single GB10 DGX Spark node
  (<a href="https://github.com/boettiger-lab/k8s/tree/main/vllm/nimbus" target="_blank">boettiger-lab/k8s/vllm/nimbus</a>).
  All measurements are derived passively from existing telemetry — no instrumentation of
  the LLM service is required.
</p>
```

- [ ] **Step 9: Methodology page — Step 1 (GPU power) prose and PromQL**

Change:

```html
<h2>Step 1 — Measuring GPU Power</h2>
<p>
  GPU power draw is read from
  <a href="https://github.com/NVIDIA/dcgm-exporter" target="_blank">NVIDIA DCGM Exporter</a>
  (<em>Data Center GPU Manager</em>), which runs as a DaemonSet on every GPU node in the
  NRP cluster. DCGM reads the hardware power sensor via NVML
  (<code>nvmlDeviceGetPowerUsage</code>) and exports it to Prometheus as:
</p>
<pre><code>DCGM_FI_DEV_POWER_USAGE{namespace, container, Hostname, ...}  # watts, per GPU</code></pre>
<p>
  We aggregate all GPUs belonging to each LLM pod using a PromQL sum:
</p>
<pre><code>sum by (namespace, container, Hostname) (
  avg_over_time(DCGM_FI_DEV_POWER_USAGE{namespace=~"nrp-llm|sdsc-llm"}[5m])
)</code></pre>
<p>
```

to:

```html
<h2>Step 1 — Measuring GPU Power</h2>
<p>
  GPU power draw is read from
  <a href="https://github.com/NVIDIA/dcgm-exporter" target="_blank">NVIDIA DCGM Exporter</a>
  (<em>Data Center GPU Manager</em>), which runs on nimbus's single GPU (a GB10). DCGM
  reads the hardware power sensor via NVML (<code>nvmlDeviceGetPowerUsage</code>) and
  exports it to Prometheus as:
</p>
<pre><code>DCGM_FI_DEV_POWER_USAGE{namespace, container, pod, ...}  # watts, one GPU</code></pre>
<p>
  nimbus has exactly one physical GPU, so no summing across GPUs is needed — just a
  namespace filter:
</p>
<pre><code>sum by (namespace) (
  avg_over_time(DCGM_FI_DEV_POWER_USAGE{namespace="default"}[5m])
)</code></pre>
<p>
```

- [ ] **Step 10: Methodology page — replace Step 3 (multi-region intensity) with the fixed constant**

Change:

```html
<h2>Step 3 — Carbon Intensity by Grid Location</h2>
<p>
  NRP nodes are hosted at universities and research institutions across the United States
  and internationally. Grid carbon intensity varies substantially by location. We use
  <a href="https://www.epa.gov/egrid" target="_blank">EPA eGRID 2022 subregion averages</a>
  matched to each node's <code>Hostname</code> label. When the hostname doesn't match,
  a secondary lookup by Kubernetes namespace prefix is attempted (e.g. <code>sdsc-llm</code>
  maps to California). If neither matches, the fallback is the California CAMX intensity
  (0.198 kg CO₂/kWh), since the majority of NRP Nautilus nodes are hosted at SDSC in
  San Diego:
</p>

<table>
  <tr><th>Institution / Region</th><th>Hostname pattern</th><th>eGRID Subregion</th><th>Intensity (kg CO₂/kWh)</th></tr>
  <tr><td>California (SDSC, CSUS, Caltech, Humboldt, UCSD, UCLA, UCSB, CalIT2, CSUMB)</td><td><code>*.sdsc.*</code>, <code>*.csus.*</code>, <code>*.humboldt.*</code>, <code>*.caltech.*</code>, <code>*.ucsd.*</code>, <code>*.ucla.*</code>, <code>*.ucsb.*</code>, <code>*.calit2.*</code>, <code>csumb.*</code>, <code>nautilus-*</code>, <code>sdsc-*</code></td><td>CAMX</td><td>0.198</td></tr>
  <tr><td>NYU (New York)</td><td><code>*.nyu.*</code></td><td>NYUP</td><td>0.174</td></tr>
  <tr><td>UNL (Nebraska)</td><td><code>*.unl.*</code></td><td>MROW</td><td>0.531</td></tr>
  <tr><td>UT Austin / TACC (Texas)</td><td><code>*.utexas.*</code>, <code>*.tacc.*</code></td><td>ERCO</td><td>0.393</td></tr>
  <tr><td>Clemson (South Carolina)</td><td><code>*.clemson.*</code></td><td>SRSO</td><td>0.423</td></tr>
  <tr><td>University of Hawaii</td><td><code>*.hawaii.*</code></td><td>HIOA</td><td>0.702</td></tr>
  <tr><td>K-State (Kansas)</td><td><code>*.ksu.*</code></td><td>SPSO</td><td>0.555</td></tr>
  <tr><td>KREONET (South Korea)</td><td><code>*.kreonet.*</code></td><td>Korean grid</td><td>0.459</td></tr>
  <tr><td><em>All other nodes</em></td><td>—</td><td>CAMX (California default)</td><td>0.198</td></tr>
</table>

<h2>Step 4 — Carbon Calculations</h2>
```

to:

```html
<h2>Step 3 — Carbon Intensity</h2>
<p>
  nimbus is one machine in one place: Berkeley, CA. Grid carbon intensity is therefore a
  fixed constant rather than a lookup table — the
  <a href="https://www.epa.gov/egrid" target="_blank">EPA eGRID 2022</a> average for the
  CAMX subregion (California):
</p>

<table>
  <tr><th>Location</th><th>eGRID Subregion</th><th>Intensity (kg CO₂/kWh)</th></tr>
  <tr><td>Berkeley, CA</td><td>CAMX</td><td>0.198</td></tr>
</table>

<h2>Step 4 — Carbon Calculations</h2>
```

- [ ] **Step 11: Methodology page — Source Code section and footer**

Change:

```html
<h2>Source Code</h2>
<p>
  This dashboard is open source:
  <a href="https://github.com/boettiger-lab/nrp-carbon-api" target="_blank">github.com/boettiger-lab/nrp-carbon-api</a>.
  The carbon intensity lookup table is in
  <code>internal/carbon/intensity.go</code>.
</p>

</main>
<footer>
  NRP Carbon Dashboard · <a href="/">Back to Dashboard</a>
</footer>
```

to:

```html
<h2>Source Code</h2>
<p>
  This dashboard is open source:
  <a href="https://github.com/boettiger-lab/nimbus-carbon-api" target="_blank">github.com/boettiger-lab/nimbus-carbon-api</a>,
  forked from
  <a href="https://github.com/boettiger-lab/nrp-carbon-api" target="_blank">nrp-carbon-api</a>.
  The fixed carbon intensity constant is in
  <code>internal/carbon/intensity.go</code>.
</p>

</main>
<footer>
  nimbus Carbon Dashboard · <a href="/">Back to Dashboard</a>
</footer>
```

- [ ] **Step 12: Sweep remaining "NRP" mentions in prose**

The remaining occurrences of "NRP" in `cmd/static/methodology.html` are all in prose describing the (unchanged) frontier-comparison methodology — swap the word "NRP" → "nimbus" (lowercase) wherever it appears as a stand-alone word describing the measured system, e.g. "matching NRP traffic" → "matching nimbus traffic", "NRP measured: 783 W" → "nimbus measured: 783 W", "NRP uses 7× less energy" → "nimbus uses 7× less energy", "NRP figures are GPU power only" → "nimbus figures are GPU power only". Do not touch the literal PromQL query text or the `nrp-carbon-api`/`nrp.ai` URLs already handled in Steps 8-11.

Run this check after editing:

```bash
grep -n "NRP" cmd/static/methodology.html
```

Expected: no output. If something prints, read it and decide whether it's a leftover (fix it) or a case not anticipated by this brief (use judgment, and note it in your report either way).

- [ ] **Step 13: Manually verify both pages render**

```bash
cd /home/cboettig/Documents/github/boettiger-lab/nimbus-carbon-api
PROMETHEUS_URL=http://localhost:9090 go run ./cmd &
APP_PID=$!
sleep 2
curl -s http://localhost:8080/ | grep -o "<title>.*</title>"
curl -s http://localhost:8080/methodology | grep -o "<title>.*</title>"
kill $APP_PID
```

Expected: `<title>nimbus Carbon Dashboard</title>` and `<title>Methodology — nimbus Carbon Dashboard</title>`.

- [ ] **Step 14: Commit**

```bash
git add cmd/static/dashboard.html cmd/static/methodology.html
git commit -m "dashboard: rebrand for nimbus, drop multi-institution comparison framing"
git push
```

---

### Task 5: Containerize and add Kubernetes manifests + CI

**Files:**
- Create: `k8s/deployment.yaml`
- Create: `.github/workflows/docker.yml`
- Verify (no change expected): `Dockerfile`

**Interfaces:**
- Consumes: the working `cmd/main.go` binary (Tasks 1-4).
- Produces: a pushable multi-arch Docker image at `ghcr.io/boettiger-lab/nimbus-carbon-api:latest`, and k8s manifests Task 6 applies to the live cluster.

- [ ] **Step 1: Confirm the existing Dockerfile needs no changes**

```bash
cat Dockerfile
```

Expected: `FROM golang:1.22-alpine AS build` and `FROM alpine:3.19` — both official Docker Library images, which ship multi-arch manifests (amd64 + arm64) already. No edits needed; this step is just confirming that fact before moving on, not a place to add QEMU/platform flags.

- [ ] **Step 2: Write `k8s/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nimbus-carbon-api
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nimbus-carbon-api
  template:
    metadata:
      labels:
        app: nimbus-carbon-api
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: nimbus-carbon-api
          image: ghcr.io/boettiger-lab/nimbus-carbon-api:latest
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
          env:
            - name: PROMETHEUS_URL
              value: "http://prometheus-server.monitoring.svc.cluster.local"
            - name: SCRAPE_INTERVAL
              value: "30s"
            - name: LISTEN_ADDR
              value: ":8080"
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: nimbus-carbon-api
  namespace: default
spec:
  selector:
    app: nimbus-carbon-api
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nimbus-carbon-api
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
    external-dns.alpha.kubernetes.io/cloudflare-proxied: "false"
  labels:
    app: nimbus-carbon-api
spec:
  ingressClassName: traefik
  rules:
  - host: carbon-nimbus.carlboettiger.info
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nimbus-carbon-api
            port:
              number: 80
  tls:
  - hosts:
    - carbon-nimbus.carlboettiger.info
    secretName: nimbus-carbon-api-tls
```

- [ ] **Step 3: Write `.github/workflows/docker.yml`**

```yaml
name: Docker Image CI
on:
  push:
    branches: [main]
    paths:
      - 'cmd/**'
      - 'internal/**'
      - 'go.mod'
      - 'Dockerfile'
      - '.github/workflows/docker.yml'
  workflow_dispatch: null

# Build each architecture on its own native runner (arm64 on
# ubuntu-24.04-arm, no QEMU), push by digest, then assemble one multi-arch
# manifest. Matches the pattern in boettiger-lab/k8s's own image workflows
# (commit 5350e06).
env:
  IMAGE: ghcr.io/boettiger-lab/nimbus-carbon-api

jobs:
  build:
    if: github.repository == 'boettiger-lab/nimbus-carbon-api'
    runs-on: ${{ matrix.runner }}
    permissions: write-all
    strategy:
      fail-fast: false
      matrix:
        include:
          - platform: linux/amd64
            runner: ubuntu-latest
          - platform: linux/arm64
            runner: ubuntu-24.04-arm
    steps:
      - name: Prepare platform name
        run: |
          platform=${{ matrix.platform }}
          echo "PLATFORM_PAIR=${platform//\//-}" >> "$GITHUB_ENV"
      - uses: actions/checkout@v4
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      - name: Login to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{github.actor}}
          password: ${{secrets.GITHUB_TOKEN}}
      - name: Build and push by digest
        id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: ${{ matrix.platform }}
          outputs: type=image,name=${{ env.IMAGE }},push-by-digest=true,name-canonical=true,push=true
      - name: Export digest
        run: |
          mkdir -p /tmp/digests
          digest="${{ steps.build.outputs.digest }}"
          touch "/tmp/digests/${digest#sha256:}"
      - name: Upload digest
        uses: actions/upload-artifact@v4
        with:
          name: digests-${{ env.PLATFORM_PAIR }}
          path: /tmp/digests/*
          if-no-files-found: error
          retention-days: 1

  merge:
    if: github.repository == 'boettiger-lab/nimbus-carbon-api'
    runs-on: ubuntu-latest
    needs: build
    permissions: write-all
    steps:
      - name: Download digests
        uses: actions/download-artifact@v4
        with:
          path: /tmp/digests
          pattern: digests-*
          merge-multiple: true
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      - name: Login to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{github.actor}}
          password: ${{secrets.GITHUB_TOKEN}}
      - name: Create multi-arch manifest
        working-directory: /tmp/digests
        run: |
          docker buildx imagetools create -t "${IMAGE}:latest" \
            $(printf "${IMAGE}@sha256:%s " *)
      - name: Inspect
        run: docker buildx imagetools inspect "${IMAGE}:latest"
```

- [ ] **Step 4: Validate the YAML locally**

```bash
kubectl apply --dry-run=client -f k8s/deployment.yaml
```

Expected: `deployment.apps/nimbus-carbon-api created (dry run)`, `service/nimbus-carbon-api created (dry run)`, `ingress.networking.k8s.io/nimbus-carbon-api created (dry run)` — confirms the YAML is well-formed and admissible, without touching the live cluster.

- [ ] **Step 5: Commit**

```bash
git add k8s/deployment.yaml .github/workflows/docker.yml
git commit -m "k8s: add Deployment/Service/Ingress + multi-arch CI workflow"
git push
```

---

### Task 6: Build, deploy, and verify end-to-end on nimbus

**Files:**
- None (this task pushes the already-committed code, waits on CI, and applies the already-committed manifests)

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: the live, public `https://carbon-nimbus.carlboettiger.info` dashboard.

- [ ] **Step 1: Confirm the push from Task 5 triggered CI, and wait for it**

```bash
cd /home/cboettig/Documents/github/boettiger-lab/nimbus-carbon-api
gh run list --limit 3
```

If the most recent run for `Docker Image CI` isn't already `completed`/`success`, watch it:

```bash
gh run watch $(gh run list --limit 1 --json databaseId --jq '.[0].databaseId')
```

Expected: eventually exits with all jobs (`build (linux/amd64, ...)`, `build (linux/arm64, ...)`, `merge`) green.

- [ ] **Step 2: Verify the multi-arch image landed in GHCR**

```bash
docker buildx imagetools inspect ghcr.io/boettiger-lab/nimbus-carbon-api:latest
```

Expected: lists both `linux/amd64` and `linux/arm64` manifests under the `:latest` tag.

- [ ] **Step 3: Deploy to nimbus**

```bash
kubectl apply -f k8s/deployment.yaml
```

Expected: `deployment.apps/nimbus-carbon-api created`, `service/nimbus-carbon-api created`, `ingress.networking.k8s.io/nimbus-carbon-api created`.

- [ ] **Step 4: Verify the pod comes up healthy**

```bash
kubectl -n default get pods -l app=nimbus-carbon-api
kubectl -n default logs -l app=nimbus-carbon-api --tail=30
```

Expected: pod `Running`, `1/1`; logs show `carbon-api listening on :8080 (prometheus=http://prometheus-server.monitoring.svc.cluster.local, interval=30s)` with no query errors after the first scrape cycle.

- [ ] **Step 5: Verify the TLS certificate issues**

```bash
kubectl -n default get certificate nimbus-carbon-api-tls
```

Expected: `READY` becomes `True` within a few minutes (cert-manager + Let's Encrypt, same flow as `vllm-nimbus-tls`). If it's still `False` after 5 minutes, check `kubectl -n default describe certificate nimbus-carbon-api-tls` for the blocking reason before proceeding — don't just wait indefinitely.

- [ ] **Step 6: Verify the public dashboard and API end-to-end**

```bash
curl -s https://carbon-nimbus.carlboettiger.info/healthz
curl -s https://carbon-nimbus.carlboettiger.info/api/v1/carbon | python3 -m json.tool
curl -s https://carbon-nimbus.carlboettiger.info/ | grep -o "<title>.*</title>"
```

Expected: `/healthz` returns 200 (empty body); `/api/v1/carbon` returns real data — `namespace: "default"`, `container: "vllm"`, `model_name` matching whatever is currently deployed, plausible `power_watts` (roughly 10-20W idle, higher under load) and `carbon_intensity_kg_per_kwh: 0.198`; the dashboard's title tag reads `nimbus Carbon Dashboard`.

- [ ] **Step 7: Update this repo's monitoring README with a pointer to the live dashboard**

In the `k8s` repo (not `nimbus-carbon-api`) at `/home/cboettig/Documents/github/boettiger-lab/k8s/monitoring/README.md`, add a line after the existing "## Metrics" section:

```markdown

## Carbon dashboard

Consumed by [nimbus-carbon-api](https://github.com/boettiger-lab/nimbus-carbon-api),
live at <https://carbon-nimbus.carlboettiger.info>.
```

```bash
cd /home/cboettig/Documents/github/boettiger-lab/k8s
git add monitoring/README.md
git commit -m "monitoring: link the live nimbus-carbon-api dashboard"
```

(This closes the loop the final whole-branch reviewer of the monitoring-infra plan flagged as a Minor finding — that README's forward-reference to `nimbus-carbon-api` 404'd because the repo didn't exist yet. It exists now.)

## Self-Review Notes

- **Spec coverage**: every section of `docs/superpowers/specs/2026-07-04-nimbus-carbon-api-design.md`'s "nimbus-carbon-api (fork of nrp-carbon-api)" and "Deployment & ingress" sections is covered — Task 1 (fork/seed), Task 2 (intensity), Task 3 (scraper — went further than the spec anticipated once live labels were checked, see below), Task 4 (dashboard rebrand), Task 5-6 (containerize, deploy, ingress).
- **Correction to the spec's stated design during planning**: the spec's "Power attribution simplification" section predicted needing to attribute DCGM's power reading to "whichever vLLM target is currently reporting nonzero token throughput" as a heuristic, because it assumed DCGM wouldn't know which pod owns the GPU under time-slicing. Checking nimbus's live Prometheus directly (done before writing Task 3) found this pessimism was unwarranted: dcgm-exporter's default kubelet pod-resources mapping already attaches accurate `namespace`/`container`/`pod` labels to `DCGM_FI_DEV_POWER_USAGE` for whichever pod currently holds the GPU allocation — no heuristic needed, just a join-key fix (namespace alone, since vLLM's own metric lacks a `container` label). This plan's Global Constraints section documents the actual verified label sets so this doesn't need re-discovering.
- **Placeholder scan**: no TBDs; every step has literal file content, exact commands, and expected output.
- **Type/interface consistency**: `Scraper.Series(namespace, container, metric string, since time.Duration)` keeps its 4-argument signature (Task 3) so `cmd/main.go`'s `handleSeries` (unchanged since Task 1) doesn't need modification — verified the call site still matches.
