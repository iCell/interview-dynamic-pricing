require "prometheus/client"
require "prometheus/middleware/exporter"

# Single registry for the whole app. Exposed at /metrics via Rack middleware
# (the exporter intercepts that path and serves the registry contents).
PROMETHEUS_REGISTRY = Prometheus::Client.registry

Rails.application.config.middleware.use Prometheus::Middleware::Exporter

module PricingMetrics
  CACHE_LOOKUPS = PROMETHEUS_REGISTRY.counter(
    :pricing_cache_lookups_total,
    docstring: "Pricing cache lookups, labelled by hit/miss",
    labels: [:result]
  )

  UPSTREAM_REQUESTS = PROMETHEUS_REGISTRY.counter(
    :pricing_upstream_requests_total,
    docstring: "Calls to the upstream rate-api, labelled by outcome",
    labels: [:outcome]
  )

  UPSTREAM_LATENCY = PROMETHEUS_REGISTRY.histogram(
    :pricing_upstream_latency_seconds,
    docstring: "Latency of upstream rate-api calls",
    buckets: [0.05, 0.1, 0.25, 0.5, 1, 2, 5]
  )

  LOCK_ACQUISITIONS = PROMETHEUS_REGISTRY.counter(
    :pricing_lock_acquisitions_total,
    docstring: "Distributed lock outcomes (acquired holders + waiter resolutions)",
    labels: [:outcome]
  )

  LOCK_WAIT = PROMETHEUS_REGISTRY.histogram(
    :pricing_lock_wait_seconds,
    docstring: "Time waiters spent polling for the cache to fill",
    buckets: [0.05, 0.1, 0.25, 0.5, 1, 2, 5]
  )

  RESPONSES = PROMETHEUS_REGISTRY.counter(
    :pricing_responses_total,
    docstring: "Pricing API responses, labelled by HTTP status",
    labels: [:status]
  )
end
