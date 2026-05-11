module Api::V1
  class PricingService < BaseService
    # Errors raised by PricingService. Each one maps to a specific HTTP
    # status in the controller. They live nested under PricingService so
    # Zeitwerk autoloads them via the parent file.
    class Error < StandardError; end
    class UpstreamFailedError < Error; end       # holder's upstream call failed
    class WaitTimeoutError < Error; end          # waiter exceeded its deadline
    class CacheUnavailableError < Error; end     # Redis (cache + lock) is down

    CACHE_KEY_PREFIX = "pricing:v1".freeze

    # Diagnostic state populated as `run` progresses. The controller reads
    # these in its after_action to emit a single structured log line per
    # request. They are nil until the corresponding stage has been reached,
    # so callers should treat absence as "didn't happen."
    attr_reader :cache_outcome, :lock_outcome, :upstream_latency_ms, :lock_wait_ms

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel = hotel
      @room = room
    end

    def upstream_called?
      !@upstream_latency_ms.nil?
    end

    def run
      cached = read_cache
      if cached
        record_cache(:hit)
        @result = cached
        return
      end
      record_cache(:miss)

      lock = RedisLock.new(lock_key, ttl: lock_ttl)

      if lock.acquire
        record_lock(:acquired, 0)
        run_as_holder(lock)
      else
        run_as_waiter
      end
    rescue Redis::BaseError => e
      # Cache or lock backend itself is unreachable. We deliberately do NOT
      # fall through to a direct upstream call: losing the stampede guard
      # would burn the daily token budget within seconds.
      raise CacheUnavailableError, e.message
    end

    private

    def run_as_holder(lock)
      rate = call_upstream

      if rate.nil?
        # Upstream returned 200 but no entry matched our triple. Surface as
        # an UpstreamFailedError so waiters give up rather than spin.
        raise UpstreamFailedError, "Upstream response missing rate for #{@period}/#{@hotel}/#{@room}"
      end

      # Write the cache BEFORE releasing the lock so waiters who notice
      # "lock gone" can read the value. Reverse order would expose a window
      # where the lock is released but the cache is still empty, making
      # waiters falsely conclude the holder failed.
      write_cache(rate)
      @result = rate
    ensure
      lock.release
    end

    def call_upstream
      started = monotonic_now
      response = RateApiClient.get_rate(period: @period, hotel: @hotel, room: @room)
      record_upstream(:ok, monotonic_now - started)
      extract_rate(response)
    rescue RateApiClient::TimeoutError
      record_upstream(:timeout, monotonic_now - started)
      raise
    rescue RateApiClient::HttpError
      record_upstream(:http_error, monotonic_now - started)
      raise
    rescue RateApiClient::NetworkError
      record_upstream(:network_error, monotonic_now - started)
      raise
    end

    def run_as_waiter
      started = monotonic_now
      deadline = started + wait_timeout
      poll_seconds = poll_ms / 1000.0

      loop do
        sleep(poll_seconds)

        cached = read_cache
        if cached
          record_lock(:wait_filled, monotonic_now - started)
          @result = cached
          return
        end

        unless Rails.cache.exist?(lock_key)
          # Holder finished or died. Double-check the cache to cover the
          # race where they wrote+released between our two reads above.
          cached = read_cache
          if cached
            record_lock(:wait_filled, monotonic_now - started)
            @result = cached
            return
          end
          # Lock is gone and cache is empty → holder failed. Don't retry,
          # let the user retry instead so we keep the
          # "≤1 in-flight upstream call per key" invariant.
          record_lock(:wait_failed, monotonic_now - started)
          raise UpstreamFailedError, "Lock holder failed without writing cache"
        end

        if monotonic_now > deadline
          record_lock(:wait_timeout, monotonic_now - started)
          raise WaitTimeoutError, "Timed out waiting for cache fill"
        end
      end
    end

    def extract_rate(response)
      parsed = JSON.parse(response.body)
      parsed["rates"]
        &.detect { |r| r["period"] == @period && r["hotel"] == @hotel && r["room"] == @room }
        &.dig("rate")
    rescue JSON::ParserError
      nil
    end

    def cache_key
      "#{CACHE_KEY_PREFIX}:#{@period}:#{@hotel}:#{@room}"
    end

    def lock_key
      "lock:#{cache_key}"
    end

    def read_cache
      Rails.cache.read(cache_key)
    end

    def write_cache(value)
      Rails.cache.write(cache_key, value, expires_in: cache_ttl)
    end

    def record_cache(result)
      @cache_outcome = result
      return unless defined?(PricingMetrics)
      PricingMetrics::CACHE_LOOKUPS.increment(labels: { result: result.to_s })
    end

    def record_upstream(outcome, latency)
      @upstream_latency_ms = (latency * 1000).round
      return unless defined?(PricingMetrics)
      PricingMetrics::UPSTREAM_REQUESTS.increment(labels: { outcome: outcome.to_s })
      PricingMetrics::UPSTREAM_LATENCY.observe(latency)
    end

    def record_lock(outcome, wait_seconds)
      @lock_outcome = outcome
      @lock_wait_ms = (wait_seconds * 1000).round if outcome != :acquired
      return unless defined?(PricingMetrics)
      PricingMetrics::LOCK_ACQUISITIONS.increment(labels: { outcome: outcome.to_s })
      PricingMetrics::LOCK_WAIT.observe(wait_seconds) if outcome != :acquired
    end

    def cache_ttl
      ENV.fetch("PRICING_CACHE_TTL_SECONDS", 300).to_i
    end

    def lock_ttl
      ENV.fetch("PRICING_LOCK_TTL_SECONDS", 10).to_i
    end

    def wait_timeout
      ENV.fetch("PRICING_LOCK_WAIT_SECONDS", 5).to_f
    end

    def poll_ms
      ENV.fetch("PRICING_LOCK_POLL_MS", 50).to_i
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
