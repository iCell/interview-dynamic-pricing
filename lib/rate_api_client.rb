class RateApiClient
  include HTTParty
  base_uri ENV.fetch('RATE_API_URL', 'http://localhost:8080')
  headers "Content-Type" => "application/json"
  headers 'token' => ENV.fetch('RATE_API_TOKEN', '04aa6f42aa03f220c2ae9a276cd68c62')

  # Net::HTTP defaults to "Accept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3"
  # which triggers a bug in the upstream where the response omits the `rate`
  # field. Force identity to keep the contract stable.
  headers "Accept-Encoding" => "identity"

  open_timeout ENV.fetch('RATE_API_OPEN_TIMEOUT', 2).to_i
  read_timeout ENV.fetch('RATE_API_READ_TIMEOUT', 5).to_i

  class Error < StandardError; end
  class TimeoutError < Error; end
  class NetworkError < Error; end

  class HttpError < Error
    attr_reader :status, :body

    def initialize(status, body)
      @status = status
      @body = body
      super("Upstream returned HTTP #{status}")
    end

    def client_error?
      (400..499).cover?(status)
    end

    def server_error?
      (500..599).cover?(status)
    end
  end

  def self.get_rate(period:, hotel:, room:)
    params = {
      attributes: [
        { period: period, hotel: hotel, room: room }
      ]
    }.to_json

    response = post("/pricing", body: params)

    return response if response.success?
    raise HttpError.new(response.code, response.body)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    raise TimeoutError, e.message
  rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH => e
    raise NetworkError, e.message
  end
end
