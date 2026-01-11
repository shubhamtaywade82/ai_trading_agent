require_relative "../dhan/client"
require "date"
require_relative "../lib/logger"

class GetIntradayOHLCV
  def self.last_trading_day(date = Date.today)
    # Get the most recent weekday (Monday-Friday)
    # If date is Saturday (6) or Sunday (0), go back to Friday
    last_day = date
    while last_day.saturday? || last_day.sunday?
      last_day -= 1
    end
    last_day
  end

  def self.call(security_id:, exchange_segment:, from_date:, to_date:, dhan_client:, interval: "5")
    logger = AgentLogger.init

    # Validate and normalize dates
    begin
      from_date_obj = Date.parse(from_date)
      to_date_obj = Date.parse(to_date)
      today = Date.today
      last_trading = last_trading_day(today)

      # Ensure dates are not in the future
      if from_date_obj > today
        logger.warn("GetIntradayOHLCV: from_date (#{from_date}) is in the future. Using last trading day - 1 day instead.")
        from_date_obj = last_trading - 1
        # If adjusted date is a weekend, go back to previous Friday
        while from_date_obj.saturday? || from_date_obj.sunday?
          from_date_obj -= 1
        end
        from_date = from_date_obj.strftime('%Y-%m-%d')
      end

      if to_date_obj > today
        logger.warn("GetIntradayOHLCV: to_date (#{to_date}) is in the future. Using today instead.")
        to_date_obj = today
        to_date = today.strftime('%Y-%m-%d')
      end

      # Ensure from_date is strictly before to_date (from_date < to_date, not equal)
      if from_date_obj >= to_date_obj
        logger.warn("GetIntradayOHLCV: from_date (#{from_date}) must be < to_date (#{to_date}). Adjusting from_date to be 1 day before to_date.")
        from_date_obj = to_date_obj - 1
        from_date = from_date_obj.strftime('%Y-%m-%d')
      end

      # Ensure from_date is < last trading day (not weekends)
      if from_date_obj >= last_trading
        logger.warn("GetIntradayOHLCV: from_date (#{from_date}) must be < last trading day (#{last_trading.strftime('%Y-%m-%d')}). Adjusting from_date.")
        from_date_obj = last_trading - 1
        # If adjusted date is a weekend, go back to previous Friday
        while from_date_obj.saturday? || from_date_obj.sunday?
          from_date_obj -= 1
        end
        from_date = from_date_obj.strftime('%Y-%m-%d')
      end

      # Limit date range for intraday (max 7 days for intraday data)
      if (to_date_obj - from_date_obj).to_i > 7
        logger.warn("GetIntradayOHLCV: Date range exceeds 7 days. Limiting to last 7 days.")
        from_date_obj = to_date_obj - 7
        from_date = from_date_obj.strftime('%Y-%m-%d')
      end

      logger.info("GetIntradayOHLCV: Validated dates - From: #{from_date}, To: #{to_date}, Interval: #{interval}, Last Trading Day: #{last_trading.strftime('%Y-%m-%d')}")
    rescue Date::Error => e
      logger.error("GetIntradayOHLCV: Invalid date format - #{e.message}")
      logger.error("GetIntradayOHLCV: Using last trading day - 1 day and today as fallback")
      today = Date.today
      last_trading = last_trading_day(today)
      from_date_obj = last_trading - 1
      # If adjusted date is a weekend, go back to previous Friday
      while from_date_obj.saturday? || from_date_obj.sunday?
        from_date_obj -= 1
      end
      from_date = from_date_obj.strftime('%Y-%m-%d')
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

