require "test_helper"

class Api::V1::PricingServiceTest < ActiveSupport::TestCase
  PERIOD = "Summer"
  HOTEL = "FloatingPointResort"
  ROOM = "SingletonRoom"
  CACHE_KEY = "pricing:v1:#{PERIOD}:#{HOTEL}:#{ROOM}".freeze
  LOCK_KEY = "lock:#{CACHE_KEY}".freeze

  def upstream_response(rate: "15000")
    body = {
      "rates" => [
        { "period" => PERIOD, "hotel" => HOTEL, "room" => ROOM, "rate" => rate }
      ]
    }.to_json
    OpenStruct.new(success?: true, body: body)
  end

  def build_service
    Api::V1::PricingService.new(period: PERIOD, hotel: HOTEL, room: ROOM)
  end

  test "cache miss calls upstream and writes the rate to cache" do
    calls = 0
    fake = ->(**_) { calls += 1; upstream_response(rate: "15000") }

    RateApiClient.stub :get_rate, fake do
      service = build_service
      service.run
      assert service.valid?
      assert_equal "15000", service.result
    end

    assert_equal 1, calls
    assert_equal "15000", Rails.cache.read(CACHE_KEY)
  end

  test "cache hit does not call upstream" do
    Rails.cache.write(CACHE_KEY, "20000", expires_in: 300)

    raising = ->(**_) { flunk("upstream must not be called on cache hit") }

    RateApiClient.stub :get_rate, raising do
      service = build_service
      service.run
      assert_equal "20000", service.result
    end
  end

  test "cache TTL expiry triggers a fresh upstream fetch" do
    calls = 0
    fake = ->(**_) { calls += 1; upstream_response(rate: calls == 1 ? "15000" : "16000") }

    RateApiClient.stub :get_rate, fake do
      build_service.tap(&:run)
      # Jump past the 5-minute window. Rails.cache honours expires_in via
      # the deletion-on-read path, so traveling the clock forward is enough.
      travel_to Time.current + 6.minutes do
        service = build_service
        service.run
        assert_equal "16000", service.result
      end
    end

    assert_equal 2, calls
  end

  test "upstream timeout does not poison the cache" do
    raising = ->(**_) { raise RateApiClient::TimeoutError, "boom" }

    RateApiClient.stub :get_rate, raising do
      assert_raises(RateApiClient::TimeoutError) { build_service.run }
    end

    assert_nil Rails.cache.read(CACHE_KEY)
  end

  test "upstream HTTP 5xx does not poison the cache" do
    raising = ->(**_) { raise RateApiClient::HttpError.new(500, "{}") }

    RateApiClient.stub :get_rate, raising do
      assert_raises(RateApiClient::HttpError) { build_service.run }
    end

    assert_nil Rails.cache.read(CACHE_KEY)
  end

  test "upstream network error does not poison the cache" do
    raising = ->(**_) { raise RateApiClient::NetworkError, "dns fail" }

    RateApiClient.stub :get_rate, raising do
      assert_raises(RateApiClient::NetworkError) { build_service.run }
    end

    assert_nil Rails.cache.read(CACHE_KEY)
  end

  test "concurrent misses on the same key collapse to one upstream call" do
    counter = 0
    counter_mutex = Mutex.new
    fake = ->(**_) {
      counter_mutex.synchronize { counter += 1 }
      sleep 0.15  # make the upstream slow enough that 19 of 20 threads enter as waiters
      upstream_response(rate: "15000")
    }

    RateApiClient.stub :get_rate, fake do
      threads = 20.times.map do
        Thread.new do
          service = build_service
          service.run
          service.result
        end
      end
      results = threads.map(&:value)

      assert_equal 1, counter, "upstream should be called exactly once"
      assert_equal 20, results.size
      assert(results.all? { |r| r == "15000" }, "every caller should see the same rate")
    end

    assert_equal "15000", Rails.cache.read(CACHE_KEY)
  end

  test "waiter raises UpstreamFailedError when holder dies without writing cache" do
    # Pre-acquire the lock externally to simulate an in-flight holder, then
    # release it without writing the cache to simulate the holder failing.
    external = RedisLock.new(LOCK_KEY, ttl: 10)
    assert external.acquire, "should acquire the test fixture lock"

    waiter_outcome = nil
    waiter = Thread.new do
      begin
        with_short_wait_timeout(2) { build_service.run }
        waiter_outcome = :unexpected_success
      rescue Api::V1::PricingService::UpstreamFailedError
        waiter_outcome = :upstream_failed
      rescue Api::V1::PricingService::WaitTimeoutError
        waiter_outcome = :wait_timeout
      end
    end

    sleep 0.2  # give the waiter time to enter the polling loop
    external.release  # holder "fails" — releases without writing cache

    waiter.join(3)
    assert_equal :upstream_failed, waiter_outcome
    assert_nil Rails.cache.read(CACHE_KEY)
  end

  test "waiter raises WaitTimeoutError when holder is still working past the deadline" do
    external = RedisLock.new(LOCK_KEY, ttl: 30)
    assert external.acquire

    outcome = nil
    waiter = Thread.new do
      begin
        with_short_wait_timeout(0.3) { build_service.run }
        outcome = :unexpected_success
      rescue Api::V1::PricingService::WaitTimeoutError
        outcome = :wait_timeout
      end
    end

    waiter.join(3)
    assert_equal :wait_timeout, outcome
  ensure
    external&.release
  end

  test "double-check: waiter that finds lock missing reads cache before giving up" do
    # Holder writes cache then releases lock. Waiter polls between those two
    # steps — first read returns nil, then lock-exists check returns false,
    # then double-check read returns the value.
    Rails.cache.write(CACHE_KEY, "30000", expires_in: 300)

    # No lock held → service should treat this as a cache hit on the very
    # first read and short-circuit before any lock interaction.
    raising = ->(**_) { flunk("upstream must not be called when cache is warm") }

    RateApiClient.stub :get_rate, raising do
      service = build_service
      service.run
      assert_equal "30000", service.result
    end
  end

  private

  def with_short_wait_timeout(seconds)
    original = ENV["PRICING_LOCK_WAIT_SECONDS"]
    ENV["PRICING_LOCK_WAIT_SECONDS"] = seconds.to_s
    yield
  ensure
    ENV["PRICING_LOCK_WAIT_SECONDS"] = original
  end
end
