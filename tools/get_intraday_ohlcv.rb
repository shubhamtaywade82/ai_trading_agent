require_relative "../dhan/client"

class GetIntradayOHLCV
  def self.call(security_id:, exchange_segment:, from_date:, to_date:, dhan_client:, interval: "5")
    result = dhan_client.get_intraday_ohlcv(
      security_id: security_id,
      exchange_segment: exchange_segment,
      from_date: from_date,
      to_date: to_date,
      interval: interval
    )

    # Normalize response format
    if result.is_a?(Array)
      result.map do |row|
        {
          timestamp: row["timestamp"] || row[:timestamp],
          open: row["open"] || row[:open],
          high: row["high"] || row[:high],
          low: row["low"] || row[:low],
          close: row["close"] || row[:close],
          volume: row["volume"] || row[:volume]
        }
      end
    else
      []
    end
  end
end

