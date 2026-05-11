class Api::V1::PricingController < ApplicationController
  VALID_PERIODS = %w[Summer Autumn Winter Spring].freeze
  VALID_HOTELS = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
  VALID_ROOMS = %w[SingletonRoom BooleanTwin RestfulKing].freeze

  before_action :validate_params

  rescue_from RateApiClient::TimeoutError do |e|
    handle_error(:upstream_timeout, :gateway_timeout, "Upstream pricing service timed out")
  end

  rescue_from RateApiClient::HttpError do |e|
    if e.client_error?
      handle_error(:upstream_4xx, :bad_request,
                   parse_upstream_error(e.body) || "Upstream rejected the request")
    else
      handle_error(:upstream_5xx, :bad_gateway, "Upstream pricing service returned an error")
    end
  end

  rescue_from RateApiClient::NetworkError do |e|
    handle_error(:upstream_network, :service_unavailable, "Upstream pricing service is unreachable")
  end

  rescue_from Api::V1::PricingService::WaitTimeoutError do |e|
    handle_error(:lock_wait_timeout, :service_unavailable, "Pricing service is busy, please retry")
  end

  rescue_from Api::V1::PricingService::UpstreamFailedError do |e|
    handle_error(:holder_failed, :service_unavailable, "Pricing service is busy, please retry")
  end

  rescue_from Api::V1::PricingService::CacheUnavailableError do |e|
    handle_error(:cache_unavailable, :service_unavailable, "Pricing service is temporarily unavailable")
  end

  def index
    @service = Api::V1::PricingService.new(
      period: params[:period],
      hotel: params[:hotel],
      room: params[:room]
    )
    @service.run
    render json: { rate: @service.result }
  end

  # Override process_action so the structured log + response metric fire AFTER
  # rescue_from has dispatched — at that point response.status is finalized.
  # Using after_action would skip both on the rescue_from path entirely
  # (exceptions abort the after_action chain before rescue_from catches them),
  # leaving error responses uncounted and unlogged.
  def process_action(*args)
    super
  ensure
    record_response_metric
    emit_request_log
  end

  private

  def handle_error(kind, status, message)
    @error_kind = kind
    render_error(status, message)
  end

  def record_response_metric
    return unless defined?(PricingMetrics)
    PricingMetrics::RESPONSES.increment(labels: { status: response.status.to_s })
  end

  # One structured log line per request. Captures the request's path/params,
  # final HTTP status, and (when the service got far enough) the cache/lock/
  # upstream outcomes that explain the status. Invoked from the ensure
  # block of process_action so it fires on every path — success,
  # before_action render, and rescue_from.
  def emit_request_log
    payload = {
      event: "pricing_request",
      path: request.path,
      params: { period: params[:period], hotel: params[:hotel], room: params[:room] },
      status: response.status,
      error_kind: @error_kind
    }

    if @service
      payload[:cache] = @service.cache_outcome
      payload[:lock_outcome] = @service.lock_outcome
      payload[:lock_wait_ms] = @service.lock_wait_ms
      payload[:upstream_called] = @service.upstream_called?
      payload[:upstream_latency_ms] = @service.upstream_latency_ms
    end

    Rails.logger.info(payload.compact)
  end

  def render_error(status, message)
    render json: { error: message }, status: status
  end

  def parse_upstream_error(body)
    return nil if body.blank?
    parsed = JSON.parse(body) rescue nil
    parsed.is_a?(Hash) ? parsed["error"] || parsed["message"] : nil
  end

  def validate_params
    unless params[:period].present? && params[:hotel].present? && params[:room].present?
      @error_kind = :param_validation
      return render_error(:bad_request, "Missing required parameters: period, hotel, room")
    end

    unless VALID_PERIODS.include?(params[:period])
      @error_kind = :param_validation
      return render_error(:bad_request, "Invalid period. Must be one of: #{VALID_PERIODS.join(', ')}")
    end

    unless VALID_HOTELS.include?(params[:hotel])
      @error_kind = :param_validation
      return render_error(:bad_request, "Invalid hotel. Must be one of: #{VALID_HOTELS.join(', ')}")
    end

    unless VALID_ROOMS.include?(params[:room])
      @error_kind = :param_validation
      return render_error(:bad_request, "Invalid room. Must be one of: #{VALID_ROOMS.join(', ')}")
    end
  end
end
