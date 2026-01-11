require_relative "../dhan/client"
require "date"
require_relative "../lib/logger"

class GetIntradayOHLCV
  def self.call(security_id:, exchange_segment:, from_date:, to_date:, dhan_client:, interval: "5")
    logger = AgentLogger.init

    # Validate and normalize dates
    begin
      from_date_obj = Date.parse(from_date)
      to_date_obj = Date.parse(to_date)
      today = Date.today

      # Ensure dates are not in the future
      if from_date_obj > today
        logger.warn("GetIntradayOHLCV: from_date (#{from_date}) is in the future. Using today instead.")
        from_date_obj = today
        from_date = today.strftime('%Y-%m-%d')
      end

      if to_date_obj > today
        logger.warn("GetIntradayOHLCV: to_date (#{to_date}) is in the future. Using today instead.")
        to_date_obj = today
        to_date = today.strftime('%Y-%m-%d')
      end

      # Ensure from_date is before to_date
      if from_date_obj > to_date_obj
        logger.warn("GetIntradayOHLCV: from_date (#{from_date}) is after to_date (#{to_date}). Swapping dates.")
        from_date, to_date = to_date, from_date
        from_date_obj, to_date_obj = to_date_obj, from_date_obj
      end

      # Limit date range for intraday (max 7 days for intraday data)
      if (to_date_obj - from_date_obj).to_i > 7
        logger.warn("GetIntradayOHLCV: Date range exceeds 7 days. Limiting to last 7 days.")
        from_date_obj = to_date_obj - 7
        from_date = from_date_obj.strftime('%Y-%m-%d')
      end

      logger.info("GetIntradayOHLCV: Validated dates - From: #{from_date}, To: #{to_date}, Interval: #{interval}")
    rescue Date::Error => e
      logger.error("GetIntradayOHLCV: Invalid date format - #{e.message}")
      logger.error("GetIntradayOHLCV: Using today as fallback")
      today = Date.today
      from_date = today.strftime('%Y-%m-%d')
      to_date = today.strftime('%Y-%m-%d')
    end

    # Validate interval
    valid_intervals = ["1", "5", "15", "30", "60"]
    interval_str = interval.to_s
    unless valid_intervals.include?(interval_str)
      logger.warn("GetIntradayOHLCV: Invalid interval '#{interval_str}'. Using default '5'.")
      interval_str = "5"
    end

    logger.debug("GetIntradayOHLCV: Final parameters - security_id: #{security_id}, exchange_segment: #{exchange_segment}, from_date: #{from_date}, to_date: #{to_date}, interval: #{interval_str}")

    result = dhan_client.get_intraday_ohlcv(
      security_id: security_id,
      exchange_segment: exchange_segment,
      from_date: from_date,
      to_date: to_date,
      interval: interval_str
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

