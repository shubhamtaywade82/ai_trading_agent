require_relative "../dhan/client"

class GetOptionChain
  def self.call(security_id:, exchange_segment:, dhan_client:, expiry: nil)
    result = dhan_client.get_option_chain(
      security_id: security_id,
      exchange_segment: exchange_segment,
      expiry: expiry
    )

    # Normalize response format
    if result.is_a?(Hash)
      {
        atm: result["atm"] || result[:atm],
        ce: result["ce"] || result[:ce] || [],
        pe: result["pe"] || result[:pe] || [],
        expiry_dates: result["expiry_dates"] || result[:expiry_dates] || [],
        strikes: result["strikes"] || result[:strikes] || []
      }
    else
      { atm: nil, ce: [], pe: [], expiry_dates: [], strikes: [] }
    end
  end
end

