require_relative "../dhan/client"

class FindInstrument
  def self.call(symbol:, segment:, dhan_client:)
    # DhanClient.find_instrument already returns a normalized hash
    dhan_client.find_instrument(symbol: symbol, segment: segment)
  end
end

