require_relative "../dhan/client"
require "date"
require_relative "../lib/logger"

class GetDailyOHLCV
  def self.call(security_id:, exchange_segment:, from_date:, to_date:, dhan_client:)
    logger = AgentLogger.init

    # Validate and normalize dates
    begin
      from_date_obj = Date.parse(from_date)
      to_date_obj = Date.parse(to_date)
      today = Date.today

      # Ensure dates are not in the future
      if from_date_obj > today
        logger.warn("GetDailyOHLCV: from_date (#{from_date}) is in the future. Using today instead.")
        from_date_obj = today
        from_date = today.strftime('%Y-%m-%d')
      end

      if to_date_obj > today
        logger.warn("GetDailyOHLCV: to_date (#{to_date}) is in the future. Using today instead.")
        to_date_obj = today
        to_date = today.strftime('%Y-%m-%d')
      end

      # Ensure from_date is before to_date
      if from_date_obj > to_date_obj
        logger.warn("GetDailyOHLCV: from_date (#{from_date}) is after to_date (#{to_date}). Swapping dates.")
        from_date, to_date = to_date, from_date
        from_date_obj, to_date_obj = to_date_obj, from_date_obj
      end

      # Limit date range to max 365 days
      if (to_date_obj - from_date_obj).to_i > 365
        logger.warn("GetDailyOHLCV: Date range exceeds 365 days. Limiting to last 365 days.")
        from_date_obj = to_date_obj - 365
        from_date = from_date_obj.strftime('%Y-%m-%d')
      end

      logger.info("GetDailyOHLCV: Validated dates - From: #{from_date}, To: #{to_date}")
    rescue Date::Error => e
      logger.error("GetDailyOHLCV: Invalid date format - #{e.message}")
      logger.error("GetDailyOHLCV: Using today as fallback")
      today = Date.today
      from_date = (today - 30).strftime('%Y-%m-%d')
      to_date = today.strftime('%Y-%m-%d')
    end

    logger.debug("GetDailyOHLCV: Final parameters - security_id: #{security_id}, exchange_segment: #{exchange_segment}, from_date: #{from_date}, to_date: #{to_date}")

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

