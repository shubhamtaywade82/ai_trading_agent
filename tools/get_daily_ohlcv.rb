require_relative "../dhan/client"

class GetDailyOHLCV
  def self.call(security_id:, exchange_segment:, from_date:, to_date:, dhan_client:)
    result = dhan_client.get_daily_ohlcv(
      security_id: security_id,
      exchange_segment: exchange_segment,
      from_date: from_date,
      to_date: to_date
    )

    # Normalize response format
    if result.is_a?(Array)
      result.map do |row|
        {
          date: row["date"] || row[:date],
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

