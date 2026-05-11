require "test_helper"

class Api::V1::PricingControllerTest < ActionDispatch::IntegrationTest
  VALID_PARAMS = {
    period: "Summer",
    hotel: "FloatingPointResort",
    room: "SingletonRoom"
  }.freeze

  def upstream_response(rate: "15000")
    body = {
      "rates" => [VALID_PARAMS.transform_keys(&:to_s).merge("rate" => rate)]
    }.to_json
    OpenStruct.new(success?: true, body: body)
  end

  test "returns 200 with rate on cache miss + upstream success" do
    fake = ->(**_) { upstream_response(rate: "15000") }

    RateApiClient.stub(:get_rate, fake) do
      get api_v1_pricing_url, params: VALID_PARAMS
    end

    assert_response :success
    assert_equal "15000", JSON.parse(@response.body)["rate"]
  end

  test "second request hits the cache and skips upstream" do
    upstream_calls = 0
    fake = ->(**_) { upstream_calls += 1; upstream_response(rate: "15000") }

    RateApiClient.stub(:get_rate, fake) do
      get api_v1_pricing_url, params: VALID_PARAMS
      assert_response :success

      get api_v1_pricing_url, params: VALID_PARAMS
      assert_response :success
    end

    assert_equal 1, upstream_calls, "second request should be served from cache"
  end

  test "upstream timeout maps to 504" do
    raising = ->(**_) { raise RateApiClient::TimeoutError, "boom" }

    RateApiClient.stub(:get_rate, raising) do
      get api_v1_pricing_url, params: VALID_PARAMS
    end

    assert_response :gateway_timeout
    assert_match(/timed out/i, JSON.parse(@response.body)["error"])
  end

  test "upstream 5xx maps to 502" do
    raising = ->(**_) { raise RateApiClient::HttpError.new(500, '{"error":"boom"}') }

    RateApiClient.stub(:get_rate, raising) do
      get api_v1_pricing_url, params: VALID_PARAMS
    end

    assert_response :bad_gateway
  end

  test "upstream 4xx is passed through as 400 with the upstream message" do
    raising = ->(**_) { raise RateApiClient::HttpError.new(422, '{"error":"Rate not found"}') }

    RateApiClient.stub(:get_rate, raising) do
      get api_v1_pricing_url, params: VALID_PARAMS
    end

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Rate not found"
  end

  test "upstream network error maps to 503" do
    raising = ->(**_) { raise RateApiClient::NetworkError, "DNS failure" }

    RateApiClient.stub(:get_rate, raising) do
      get api_v1_pricing_url, params: VALID_PARAMS
    end

    assert_response :service_unavailable
  end

  test "rejects request without any parameters" do
    get api_v1_pricing_url
    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Missing required parameters"
  end

  test "rejects request with empty parameters" do
    get api_v1_pricing_url, params: { period: "", hotel: "", room: "" }
    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Missing required parameters"
  end

  test "rejects invalid period" do
    get api_v1_pricing_url, params: VALID_PARAMS.merge(period: "summer-2024")
    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Invalid period"
  end

  test "rejects invalid hotel" do
    get api_v1_pricing_url, params: VALID_PARAMS.merge(hotel: "InvalidHotel")
    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Invalid hotel"
  end

  test "rejects invalid room" do
    get api_v1_pricing_url, params: VALID_PARAMS.merge(room: "InvalidRoom")
    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Invalid room"
  end

  test "response metric is incremented on rescue_from error paths" do
    before = PricingMetrics::RESPONSES.get(labels: { status: "504" })
    raising = ->(**_) { raise RateApiClient::TimeoutError, "boom" }

    RateApiClient.stub(:get_rate, raising) do
      get api_v1_pricing_url, params: VALID_PARAMS
    end

    assert_response :gateway_timeout
    after = PricingMetrics::RESPONSES.get(labels: { status: "504" })
    assert_equal before + 1, after, "504 response should be counted in the metric"
  end
end
