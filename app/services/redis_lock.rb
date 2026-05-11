require "securerandom"

# Distributed lock backed by Rails.cache. The cache store is Redis in
# dev/prod (so SET NX EX is honored across Puma workers and replicas) and
# MemoryStore in test (so threads inside one process serialize correctly).
class RedisLock
  attr_reader :key, :token

  def initialize(key, ttl:)
    @key = key
    @ttl = ttl
    @token = SecureRandom.uuid
  end

  def acquire
    # unless_exist + expires_in maps to SET NX EX on RedisCacheStore.
    Rails.cache.write(@key, @token, unless_exist: true, expires_in: @ttl)
  end

  # Plain delete, no "GET-and-DEL-if-token-matches" Lua check. The classic
  # mis-delete sequence is:
  #
  #   A acquires → A's upstream call exceeds the lock TTL → lock auto-expires
  #   → B acquires fresh lock → A finally returns and DELs, wiping B's lock
  #   → C acquires concurrently with B → two holders running at once.
  #
  # We accept that risk here because:
  #   1. The upstream is bounded by open(2s) + read(5s) = 7s < lock TTL(10s),
  #      so the "A overran the TTL" window only opens under pathologically
  #      slow upstream behavior.
  #   2. Even when two holders run, both call the same upstream with the same
  #      inputs and cache the same value — the rate is idempotent within its
  #      validity window. Cost: one extra upstream call. No data corruption.
  #   3. The lock is a performance optimization (collapse stampedes), not a
  #      correctness primitive. We pay the simplicity dividend now and can
  #      upgrade to a Lua compare-and-delete later if upstream side-effects
  #      ever become non-idempotent.
  def release
    Rails.cache.delete(@key)
  end

  def held?
    Rails.cache.exist?(@key)
  end
end
