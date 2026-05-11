ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require "ostruct"

class ActiveSupport::TestCase
  parallelize(workers: 1)

  fixtures :all

  setup do
    # Each test starts with an empty cache (and therefore no leftover lock
    # entries from previous tests, since the lock lives in the same store).
    Rails.cache.clear
  end
end
