require_relative "../dhan/client"

class GetLTP
  def self.call(security_id:, exchange_segment:, dhan_client:)
    result = dhan_client.get_ltp(
      security_id: security_id,
      exchange_segment: exchange_segment
    )

    # Normalize response format
    if result.is_a?(Hash)
      {
        ltp: result["ltp"] || result[:ltp],
        ltt: result["ltt"] || result[:ltt],
        security_id: result["security_id"] || result[:security_id] || security_id,
        exchange_segment: result["exchange_segment"] || result[:exchange_segment] || exchange_segment
      }
    else
      { ltp: result, ltt: nil, security_id: security_id, exchange_segment: exchange_segment }
    end
  end
end

