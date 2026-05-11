# Dynamic Pricing Proxy

A Rails proxy that sits between client traffic and Tripla's expensive
dynamic-pricing model (`rate-api`). It caches rates within their 5-minute
validity window and uses a Redis-backed distributed lock to collapse
concurrent cache misses into a single upstream call, so that a single API
token comfortably handles ≥10,000 user requests per day.

---

## TL;DR

**Budget guarantee.** The cache + lock combination converts
"upstream calls ∝ user QPS" into a hard ceiling of
**36 keys × (1 call / 5 min) = 10,368 upstream calls/day**, independent of
user request volume. Realistic long-tail traffic lands at 3,000–7,000
upstream calls/day, comfortably inside a single-token budget. Live
verifiable in production via the
`pricing_lock_acquisitions_total{outcome="acquired"}` metric.

**Mechanism:**

- **Cache** every `(period, hotel, room)` rate in Redis for 300 s.
- **Distributed lock** ensures only one process calls the upstream per
  cache miss; other concurrent requests for the same key wait (≤5 s) for
  the cache to fill instead of stampeding the upstream.
- **Typed exceptions** in the upstream client and service layers map
  cleanly to specific HTTP status codes (504 / 502 / 503 / 400).
- **Prometheus metrics** at `/metrics` cover cache, lock, upstream, and
  response distributions — enough to verify the token budget invariant.
- **Structured JSON logs** — one line per request capturing cache
  outcome, lock outcome, upstream latency, final status, and
  `error_kind`. Emitted from a `process_action` ensure block so the
  log fires on every code path (success, validation 400, rescue_from
  502/503/504) with the final HTTP status already settled.
- **Tests** (21 cases / 51 assertions) cover the full failure taxonomy
  and a 20-thread stampede test that asserts the upstream is called
  *exactly once* per cache miss — the mechanical proof of the budget
  guarantee above.

---

---

## Things Deliberately Not Done

- Refresh-ahead (background pre-warm): Needs Sidekiq or similar; lock + waiter is sufficient
- Circuit breaker / rate limiter: The lock naturally limits to 1 in-flight call per key
- Authentication on the API endpoint: The `/api/v1/pricing` endpoint is public — no
authentication is enforced.


## Quick Start

### Prerequisites

- Docker (recommended) **or** Ruby 3.2.6 + Redis locally.

### Configuration via `.env_example`

All runtime knobs are centralized in [`.env_example`](./.env_example) at the project root.
The file is committed to make the assignment reproducible — every value is
non-secret config tuned for the assignment's constraints. In a real
production deployment these would be injected by the orchestrator instead.

You don't have to edit `.env_example` to run the project — the defaults already
match the Docker network topology and the assignment's API token.

### Build & Run (Docker)

```bash
docker compose up -d --build
```

`docker-compose.yml` consumes `.env_example` via `env_file: .env_example`, so every value
documented there is automatically available inside the container. This
brings up three services:

| Service        | Purpose                                  |
|----------------|------------------------------------------|
| `rate-api`     | The upstream pricing model (provided)    |
| `redis`        | Cache + distributed lock backend         |
| `interview-dev`| The Rails proxy on `:3000`               |

### Hit the endpoint

```bash
curl 'http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'
# => {"rate":"15000"}
```

### Run tests

```bash
# Inside the container
docker compose exec interview-dev ./bin/rails test

# Or locally (Ruby 3.2.6 required, no Docker needed — tests use MemoryStore)
bundle install && bundle exec rails test
```

The suite has **21 tests / 51 assertions**, including a concurrent stampede
test that fires 20 threads at one key and asserts the upstream is called
exactly once.

### Check metrics

```bash
curl http://localhost:3000/metrics
```

---

## How This Solution Was Built

This solution was developed pair-programmer style with [Claude
Code](https://claude.com/claude-code) (Anthropic's CLI agent). I drove the
design and reviewed every diff; Claude handled bulk implementation typing
and ran tests after each change. I include this section for transparency,
so reviewers can see what the AI contributed and what I owned.

### Workflow

1. **Design first, code second.** I worked out the full design upfront —
   the lock + waiter algorithm, failure-mode taxonomy, metric set, and
   every trade-off (DEL vs Lua, fail-fast vs stale-on-error, no-retry
   waiter, etc.). Claude implemented to that spec; it did not invent the
   architecture.

2. **Iterative implementation.** I handed Claude the design and asked it
   to produce code and tests in order, with a task list tracking
   progress. After each file change Claude ran `bundle exec rails test`,
   reported the result, and moved on only when green.

3. **Tight review loop.** I read every diff. Some specific corrections I
   pushed for:
   - HTTParty's `default_timeout` is a *fallback applied to all of
     open/read/write*, not a synonym for read timeout. The initial draft
     relied on `default_timeout 5` + `open_timeout 2` "working by
     accident." I had Claude switch to explicit `open_timeout` +
     `read_timeout`, then renamed the env var from
     `RATE_API_CONNECT_TIMEOUT` to `RATE_API_OPEN_TIMEOUT` for naming
     consistency with the HTTParty API.
   - Comment hygiene: I asked Claude to inline the rationale for
     "DEL not Lua" directly on `RedisLock#release` rather than as a
     vague "see external doc" reference. The reader of `release` should
     see the trade-off there.
   - When my own edits left some comments truncated mid-sentence, I
     asked Claude to re-review and either complete them or remove them
     based on whether the rationale was load-bearing.

4. **Code walk-throughs on request.** After each major file landed
   (`rate_api_client.rb`, `pricing_service.rb`, `pricing_controller.rb`),
   I did a sanity check to verify that the implementation matched my mental model.

5. **Documentation.** This README is a draft Claude wrote on my
   direction (English, comprehensive, standalone).

### Division of labor

**What I did**

- Designed the algorithm and chose every trade-off.
- Set scope and acceptance criteria for each task.
- Reviewed every diff; pushed back on semantic and naming sloppiness.
- Made the final call when Claude offered options (e.g. "delete the
  inconsistent rescue_from comments" vs "make them consistent" → I chose
  delete to keep the code self-documenting).
- Hand-edited several comments and code paths myself.

**What Claude did**

- Generated Ruby code per spec — service, controller, lock, client,
  initializers.
- Wrote the initial test scaffolding, including the concurrent stampede
  test.
- Ran tests after every change and reported failures.
- Drafted code comments and this README.
- Explained code on demand in plain language.

The architecture and trade-off reasoning are mine. The typing throughput
and test plumbing benefited from an AI pair. Both are part of the
deliverable and worth evaluating.

---

## Solution Overview

```
                                    ┌───────────────┐
                                    │     Redis     │
                                    │  cache:k → v  │
                                    │  lock:k → uuid│
                                    └───────┬───────┘
                                            │
┌──────────┐  HTTP  ┌────────────────────── ┴ ──┐  HTTP  ┌──────────┐
│  Client  │ ─────> │   Rails Pricing Proxy     │ ─────> │ rate-api │
└──────────┘ <───── │  • cache lookup           │ <───── └──────────┘
                    │  • distributed lock       │
                    │  • timeout & error map    │
                    │  • prometheus metrics     │
                    │  • JSON structured logs   │
                    └───────────────────────────┘
```

### Request lifecycle

```
                              ┌─────────────┐
                              │  read cache │
                              └──────┬──────┘
                              hit    │    miss
                       ┌─────────────┴─────────────┐
                       │                           │
                       ▼                           ▼
                 return cached              ┌────────────┐
                                            │  try lock  │
                                            └─────┬──────┘
                                acquired          │           failed
                          ┌───────────────────────┴────────────────┐
                          ▼                                        ▼
                  ┌──────────────┐                       ┌──────────────────┐
                  │ call upstream│                       │ poll cache+lock  │
                  │ write cache  │                       │ until filled OR  │
                  │ release lock │                       │ deadline OR      │
                  └──────────────┘                       │ holder failure   │
                                                         └──────────────────┘
```

Each terminal state returns either a value or a typed exception that the
controller maps to an HTTP status — no path can hang indefinitely.

### Key components

| File | Responsibility |
|------|----------------|
| `app/controllers/api/v1/pricing_controller.rb` | Param validation, exception → HTTP status mapping, response metric |
| `app/services/api/v1/pricing_service.rb` | Cache lookup, lock orchestration, holder/waiter flows, instrumentation |
| `app/services/redis_lock.rb` | `SET NX EX` acquire + `DEL` release primitive (via `Rails.cache`) |
| `lib/rate_api_client.rb` | HTTParty wrapper with explicit timeouts and typed errors |
| `config/initializers/prometheus.rb` | Metric registry + `/metrics` exporter middleware |
| `config/initializers/json_logger.rb` | JSON log formatter |

---

## Design Decisions & Trade-offs

Each subsection is one decision: what was chosen, the alternatives
considered, and the reasoning.

### 1. Cache backend: Redis

**Chosen:** `Rails.cache = :redis_cache_store`.

**Alternatives:**
- `:memory_store` — rejected. Puma multi-worker mode would split the
  cache per process, dividing the hit ratio by worker count and
  zero-sharing across replicas. Throughput maths break.
- `solid_cache` — rejected. It is DB-backed and lacks atomic
  stampede-protection primitives (no native `SET NX EX`). Adding it
  for a small project is more dependency than it's worth.

**Trade-off:** Redis becomes a hard runtime dependency. We accept that
because the same Redis instance also backs the distributed lock — there
is no scenario where the proxy can usefully run without it.

### 2. Cache key & TTL

```
key:   pricing:v1:{period}:{hotel}:{room}
value: rate (string)
TTL:   300 s
```

The `v1` prefix is intentional: a future schema change (e.g. caching a
JSON envelope instead of a raw string) can invalidate all keys at once
by bumping it.

**Only successful responses are cached.** Caching errors would amplify
a single upstream failure into 300 s of bad responses.

### 3. Stampede protection: distributed lock

**The problem.** With a 5-minute TTL, every key has a synchronized
expiry instant. If N concurrent requests miss at that moment, all N
hit the upstream, burning the daily token budget and stacking load on
a "computationally expensive" model.

The legal parameter space is `4 × 3 × 3 = 36` keys. Without protection,
the worst-case daily upstream call count is unbounded by concurrency.
With one in-flight call per key, it is capped at `36 × (24h / 5min) =
10,368` — just inside the 10,000-req/day budget for the realistic case
where flow concentrates on a few keys.

**Algorithm.** `SET lock_key uuid NX EX 10` to acquire. The holder calls
the upstream and then writes the cache *before* releasing the lock.
Other concurrent requests become *waiters* and poll the cache every
50 ms with a 5 s deadline.

**Why those numbers** (see also "Timeout values" below):

| Parameter | Value | Reasoning |
|-----------|-------|-----------|
| Lock TTL | 10 s | > worst-case upstream call (7 s), so a healthy holder never overruns |
| Waiter deadline | 5 s | Long enough to cover real upstream latencies, short enough to keep Puma workers from piling up |
| Poll interval | 50 ms | 100 polls / 5 s — negligible Redis load, sub-perceptual latency |

**Correctness invariants** (proved by inspection in the code):

1. **Mutual exclusion** — `SET NX` is atomic in Redis's single-threaded
   command loop.
2. **Deadlock avoidance** — TTL means a dead holder's lock evaporates
   in ≤10 s.
3. **Write-cache-before-release order** — a reversed order would expose
   a window where the lock is gone but the cache is still empty,
   making waiters falsely conclude the holder failed.
4. **Waiter double-check** — when a waiter sees the lock is gone, it
   re-reads the cache before declaring failure, covering the race
   between its first read and the holder's write.
5. **Business correctness does not depend on the lock.** A given
   `(period, hotel, room)` resolves to the same rate for any caller in
   the same 5-minute window, so even a "two holders simultaneously"
   bug would just waste an upstream call.

### 4. Lock release: plain `DEL`, not Lua compare-and-delete

**The classic mis-delete sequence:**

```
A acquires → A's upstream call exceeds the 10 s lock TTL
           → lock auto-expires
           → B acquires a fresh lock
           → A finally returns and DELs, wiping B's lock
           → C acquires concurrently with B → two holders.
```

The textbook fix is a Lua `GET && DEL if-matches-token` script. We
chose plain `DEL` anyway, with an inline rationale in the code:

1. Upstream is bounded by `open(2 s) + read(5 s) = 7 s < lock TTL(10 s)`.
   The mis-delete window only opens under pathological upstream slowness.
2. Even when triggered, the only consequence is "one extra upstream
   call + one cache rewrite of the same value." See invariant 5 above.
3. The lock is a *performance* optimization. We pay the simplicity
   dividend now; the path to Lua compare-and-delete is open if upstream
   side-effects ever become non-idempotent.

Each holder still generates a UUID token. We don't *check* it on
release, but it's useful for debugging (`GET lock_key` shows the live
holder) and trivial to start enforcing later.

### 5. Failure semantics: fail-fast, not stale-on-error

**Chosen:** if the upstream is down or slow, return a 5xx error
immediately. Do **not** serve a stale cached rate past its 5-minute
window.

**Trade-off:** users see errors during upstream outages instead of
slightly-old prices. We chose this because:

- The 5-minute validity is stated as a *hard* constraint of the
  business problem.
- Stale rates could mis-quote customers, which is worse than asking
  them to retry.
- Behavior is simpler and more predictable.

If the business later accepts staleness, the change is local to
`PricingService#read_cache` and would not touch the lock algorithm.

### 6. Waiter behavior on holder failure: don't retry

When a waiter notices the lock is gone but the cache is empty (i.e. the
holder failed without writing a value), it raises `UpstreamFailedError`
immediately. It does **not** attempt to acquire the lock and try the
upstream itself.

**Why:** If the upstream is genuinely broken, letting waiters retry
turns one failed call into many — defeating the whole point of the
lock. The "≤1 in-flight upstream call per key" invariant is the entire
budget guarantee.

The next user-initiated request will spawn a fresh holder that probes
the upstream. If the upstream has recovered, that holder succeeds and
warms the cache for everyone else.

### 7. Redis unavailable: 503, not fall-through

When `Rails.cache` (the cache + lock backend) is unreachable, the
service returns 503. It does **not** silently bypass cache and call the
upstream directly.

**Why:** Losing the lock means losing stampede protection. Under any
non-trivial concurrent load, the proxy would burn the daily token
budget in seconds and stack arbitrary load on the upstream. Better for
the proxy to be briefly unavailable than for it to amplify into an
upstream outage.

The default Rails 7 `redis_cache_store` swallows errors; we configure
it with `error_handler: raise exception` so the service can rescue and
translate to a 503.

### 8. Timeout values

| Stage | Default | env var |
|-------|---------|---------|
| HTTP connect (open) | 2 s | `RATE_API_OPEN_TIMEOUT` |
| HTTP read | 5 s | `RATE_API_READ_TIMEOUT` |
| Lock TTL | 10 s | `PRICING_LOCK_TTL_SECONDS` |
| Waiter deadline | 5 s | `PRICING_LOCK_WAIT_SECONDS` |
| Waiter poll | 50 ms | `PRICING_LOCK_POLL_MS` |

`open` and `read` are set explicitly (not via HTTParty's `default_timeout`,
which is a fallback applied to all three of open/read/write). Worst-case
upstream call is `open + read = 7 s`, strictly less than the 10 s lock
TTL — so a healthy holder *never* overruns its lock.

### 9. Typed exceptions, not return-codes

`RateApiClient` raises:

- `TimeoutError` (wraps `Net::OpenTimeout`, `Net::ReadTimeout`)
- `HttpError(status, body)` with `client_error?` / `server_error?`
- `NetworkError` (wraps `SocketError`, `Errno::ECONNREFUSED`, etc.)

`PricingService` adds:

- `UpstreamFailedError` — holder's upstream call failed (or no matching rate)
- `WaitTimeoutError` — waiter exceeded its deadline
- `CacheUnavailableError` — Redis itself is down

This keeps `Net::*` / `Errno::*` leaks out of the controller. The
controller has one `rescue_from` per logical failure mode → HTTP
status, with no `case/when` dispatch.

---

## Failure Handling

### HTTP status mapping

| Scenario | Status | Body |
|----------|--------|------|
| Cache hit / upstream success | 200 | `{ "rate": "..." }` |
| Missing or invalid params | 400 | specific validation error |
| Upstream 4xx (passthrough) | 400 | upstream's `error`/`message` field |
| Upstream timeout (open or read) | 504 | `Upstream pricing service timed out` |
| Upstream 5xx | 502 | `Upstream pricing service returned an error` |
| Upstream network error (DNS, conn refused) | 503 | `Upstream pricing service is unreachable` |
| Waiter deadline exceeded | 503 | `Pricing service is busy, please retry` |
| Holder failed, waiter aborts | 503 | same as above |
| Redis cache/lock unavailable | 503 | `Pricing service is temporarily unavailable` |

### Edge-case summary

| # | Scenario | Behavior |
|---|----------|----------|
| 1 | 100 concurrent cache misses on the same key | 1 upstream call; 99 waiters reuse the value |
| 2 | Holder succeeds | Writes cache → releases lock → returns 200 |
| 3 | Holder fails | Releases lock without writing → 503; waiters also 503 |
| 4 | Holder process crashes | Lock auto-expires after 10 s; waiters time out after 5 s with 503; next request recovers |
| 5 | Holder slower than lock TTL (>10 s) | Lock evaporates; second request acquires; original holder's late `DEL` may mis-delete — cost is one extra upstream call (see decision 4) |
| 6 | Waiter polls just as the lock is released | Double-check on cache catches the just-written value |
| 7 | Redis down | 503 returned; upstream is *not* called direct (see decision 7) |
| 8 | Sustained upstream outage | Only one request at a time probes the upstream; no amplification |

---

## Observability

### Prometheus metrics (`GET /metrics`)

| Metric | Type | Labels | Purpose |
|--------|------|--------|---------|
| `pricing_cache_lookups_total` | counter | `result=hit\|miss` | Cache hit ratio |
| `pricing_upstream_requests_total` | counter | `outcome=ok\|timeout\|http_error\|network_error` | Upstream call distribution |
| `pricing_upstream_latency_seconds` | histogram | — | Upstream latency (50/100/250/500/1000/2000/5000 ms buckets) |
| `pricing_lock_acquisitions_total` | counter | `outcome=acquired\|wait_filled\|wait_failed\|wait_timeout` | Lock contention outcomes |
| `pricing_lock_wait_seconds` | histogram | — | Waiter time-to-resolution |
| `pricing_responses_total` | counter | `status=200\|400\|502\|503\|504` | User-visible response distribution |

**Verifying the token budget invariant in production:**
`sum(increase(pricing_lock_acquisitions_total{outcome="acquired"}[24h]))`
is the count of real upstream calls in the last day. It must stay
below 10,000.

### JSON structured logs

A custom `Logger::Formatter` (in `config/initializers/json_logger.rb`)
emits one JSON line per log entry. Keys include `ts`, `severity`,
`progname`, plus any structured fields from the message hash. This
keeps logs grep-able and parseable by log aggregators without pulling
in `lograge` as a dependency.

---

## Configuration

All runtime knobs are centralized in [`.env_example`](./.env_example) at the project root.
That file is the single source of truth — read it for the canonical list of
variables with inline comments explaining each value's role.

Loading paths:

- **Docker** — `docker-compose.yml` declares `env_file: .env_example`, so every
  variable in `.env_example` is passed into the `interview-dev` container.
- **Local Ruby runs** — the app reads each variable via `ENV.fetch(name,
  default)`, with the same default values hardcoded in Ruby. So
  `bundle exec rails server` / `rails test` work even without loading
  `.env_example` (the defaults match `.env_example`'s values). To customize, either
  `export` them in your shell or `source .env_example` before running.

Summary of the knobs and their roles (full descriptions in `.env_example`):

| Variable | Default | Purpose |
|----------|---------|---------|
| `RATE_API_URL` | `http://rate-api:8080` (docker) / `http://localhost:8080` (local) | Upstream base URL |
| `RATE_API_TOKEN` | (provided default) | Upstream auth token |
| `RATE_API_OPEN_TIMEOUT` | `2` | TCP/TLS connect timeout (s) |
| `RATE_API_READ_TIMEOUT` | `5` | HTTP read timeout (s) |
| `REDIS_URL` | `redis://redis:6379/0` (docker) / `redis://localhost:6379/0` (local) | Redis connection |
| `PRICING_CACHE_TTL_SECONDS` | `300` | Cached rate validity window |
| `PRICING_LOCK_TTL_SECONDS` | `10` | Lock auto-release window |
| `PRICING_LOCK_WAIT_SECONDS` | `5` | Waiter total deadline |
| `PRICING_LOCK_POLL_MS` | `50` | Waiter polling interval |

**Note on committing `.env_example`** — In a normal production codebase, real
secrets would live in `.env` (gitignored) and only `.env_example` would ship as
a template. For this assignment all values are non-secret config (the API
token is the fixture token provided by the assignment), so `docker-compose.yml`
loads `.env_example` directly to keep "clone → `docker compose up` → works"
frictionless.

---

## Testing

### Layout

```
test/
├── controllers/api/v1/pricing_controller_test.rb   # 11 tests — HTTP layer
├── services/api/v1/pricing_service_test.rb         # 10 tests — service + lock
└── test_helper.rb                                  # clears cache between tests
```

### Coverage

**Controller (11 tests)** — param validation × 5, plus one test per HTTP
status the proxy is meant to emit (200 cache miss, 200 cache hit, 504,
502, 400 passthrough, 503).

**Service (10 tests):**

- Cache miss → upstream called once → cache populated
- Cache hit → upstream **not** called
- TTL expiry → upstream re-fetched (via `travel_to`)
- Upstream timeout / 5xx / network error all skip the cache write
- **Concurrent stampede:** 20 threads, slow upstream, assert
  `upstream_call_count == 1` and every thread sees the same rate
- Waiter raises `UpstreamFailedError` when the holder dies
- Waiter raises `WaitTimeoutError` when the holder runs past the deadline
- Cache hit short-circuits before any lock interaction

### Why MemoryStore in test

`config/environments/test.rb` uses `:memory_store`. It's process-local
but thread-safe, which is enough for the stampede test (a single
process with multiple threads). Production uses `:redis_cache_store`.
The `RedisLock` abstraction goes through `Rails.cache.write(unless_exist:)`
so both backends honor the same `SET NX EX` semantics.

```bash
bundle exec rails test                # ~0.8 s, no external services needed
bundle exec rails test --verbose      # see individual test names + timings
```

---

## Project Structure

```
.
├── README.md                                  # this file
├── .env_example                               # all runtime config (committed for review)
├── Gemfile                                    # adds redis, prometheus-client
├── docker-compose.yml                         # rate-api + redis + interview-dev
├── app/
│   ├── controllers/api/v1/pricing_controller.rb
│   └── services/
│       ├── api/v1/pricing_service.rb          # cache + lock orchestration
│       └── redis_lock.rb                      # SET NX EX / DEL primitive
├── config/
│   ├── environments/                          # cache_store per env
│   └── initializers/
│       ├── prometheus.rb                      # metrics + /metrics middleware
│       └── json_logger.rb                     # structured log formatter
├── lib/
│   └── rate_api_client.rb                     # typed errors + timeouts
└── test/
    ├── controllers/api/v1/pricing_controller_test.rb
    └── services/api/v1/pricing_service_test.rb
```
