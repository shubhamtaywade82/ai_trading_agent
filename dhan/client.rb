require "dhan_hq"
require_relative "../lib/logger"

class DhanClient
  def initialize
    @logger = AgentLogger.init
    @logger.info("DHAN: Initializing DhanHQ client")

    # DhanHQ gem uses configure_with_env which reads from ENV
    # Requires CLIENT_ID and ACCESS_TOKEN environment variables
    DhanHQ.configure_with_env
    DhanHQ.logger.level = (ENV["DHAN_LOG_LEVEL"] || "INFO").upcase.then { |level| Logger.const_get(level) }
    @logger.info("DHAN: Client initialized successfully")
  end

  def find_instrument(symbol:, segment:)
    @logger.info("DHAN: Finding instrument - Symbol: #{symbol}, Segment: #{segment}")
    # Use DhanHQ::Models::Instrument.find(segment, symbol)
    instrument = DhanHQ::Models::Instrument.find(segment, symbol)

    if instrument
      # DhanHQ Instrument model uses symbol_name, not trading_symbol
      trading_symbol = instrument.respond_to?(:symbol_name) ? instrument.symbol_name :
                      (instrument.respond_to?(:display_name) ? instrument.display_name : symbol)

      result = {
        security_id: instrument.security_id.to_s,
        exchange_segment: instrument.exchange_segment,
        instrument_type: instrument.instrument_type,
        trading_symbol: trading_symbol || symbol
      }

      @logger.debug("DHAN: Found instrument - #{result.inspect}")
      result
    else
      raise "Instrument not found: #{symbol} in #{segment}"
    end
  end

  def get_daily_ohlcv(security_id:, exchange_segment:, from_date:, to_date:)
    @logger.info("DHAN: Getting daily OHLCV - Security: #{security_id}, Segment: #{exchange_segment}, From: #{from_date}, To: #{to_date}")
    # Use DhanHQ::Models::HistoricalData.daily
    # Note: The API may require instrument type, using "INDEX" as default for indices
    instrument_type = exchange_segment.start_with?("IDX_") ? "INDEX" : nil

    begin
      result = DhanHQ::Models::HistoricalData.daily(
        security_id: security_id,
        exchange_segment: exchange_segment,
        instrument: instrument_type,
        from_date: from_date,
        to_date: to_date
      )
    rescue DhanHQ::InputExceptionError => e
      @logger.warn("DHAN: API error for daily data - #{e.message}")
      @logger.warn("DHAN: Returning empty array - data may not be available for these dates")
      return []
    rescue => e
      @logger.error("DHAN: Unexpected error getting daily data - #{e.class}: #{e.message}")
      return []
    end

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

  def get_intraday_ohlcv(security_id:, exchange_segment:, from_date:, to_date:, interval: "5")
    @logger.info("DHAN: Getting intraday OHLCV - Security: #{security_id}, Segment: #{exchange_segment}, Interval: #{interval}min, From: #{from_date}, To: #{to_date}")
    # Use DhanHQ::Models::HistoricalData.intraday
    # interval: "1", "5", "15", "30", or "60" minutes
    instrument_type = exchange_segment.start_with?("IDX_") ? "INDEX" : nil

    begin
      result = DhanHQ::Models::HistoricalData.intraday(
        security_id: security_id,
        exchange_segment: exchange_segment,
        instrument: instrument_type,
        interval: interval,
        from_date: from_date,
        to_date: to_date
      )
    rescue DhanHQ::InputExceptionError => e
      @logger.warn("DHAN: API error for intraday data - #{e.message}")
      @logger.warn("DHAN: Returning empty array - data may not be available for these dates")
      return []
    rescue => e
      @logger.error("DHAN: Unexpected error getting intraday data - #{e.class}: #{e.message}")
      return []
    end

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

  def get_option_chain(security_id:, exchange_segment:, expiry: nil)
    @logger.info("DHAN: Getting option chain - Security: #{security_id}, Segment: #{exchange_segment}, Expiry: #{expiry || 'auto'}")
    # Use DhanHQ::Models::OptionChain.fetch
    # Requires underlying_scrip (security_id), underlying_seg (exchange_segment), and expiry
    begin
      if expiry
        result = DhanHQ::Models::OptionChain.fetch(
          underlying_scrip: security_id.to_i,
          underlying_seg: exchange_segment,
          expiry: expiry
        )
      else
        # If no expiry provided, fetch expiry list first
        expiries = DhanHQ::Models::OptionChain.fetch_expiry_list(
          underlying_scrip: security_id.to_i,
          underlying_seg: exchange_segment
        )

        # Use nearest expiry if available
        if expiries.is_a?(Array) && expiries.any?
          expiry_value = expiries.first
          # Handle both hash and string formats
          expiry = if expiry_value.is_a?(Hash)
            expiry_value["expiry"] || expiry_value[:expiry] || expiry_value["expiry_date"] || expiry_value[:expiry_date]
          else
            expiry_value.to_s
          end

          if expiry
            result = DhanHQ::Models::OptionChain.fetch(
              underlying_scrip: security_id.to_i,
              underlying_seg: exchange_segment,
              expiry: expiry
            )
          else
            @logger.warn("DHAN: Could not extract expiry from: #{expiries.first.inspect}")
            return { atm: nil, ce: [], pe: [], expiry_dates: [], strikes: [] }
          end
        else
          @logger.warn("DHAN: No expiries found for option chain")
          return { atm: nil, ce: [], pe: [], expiry_dates: [], strikes: [] }
        end
      end
    rescue DhanHQ::InputExceptionError => e
      @logger.warn("DHAN: API error for option chain - #{e.message}")
      return { atm: nil, ce: [], pe: [], expiry_dates: [], strikes: [] }
    rescue => e
      @logger.error("DHAN: Unexpected error getting option chain - #{e.class}: #{e.message}")
      return { atm: nil, ce: [], pe: [], expiry_dates: [], strikes: [] }
    end

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

  def get_ltp(security_id:, exchange_segment:)
    @logger.info("DHAN: Getting LTP - Security: #{security_id}, Segment: #{exchange_segment}")
    # Use DhanHQ::Models::MarketFeed.ltp
    begin
      result = DhanHQ::Models::MarketFeed.ltp(
        security_id: security_id,
        exchange_segment: exchange_segment
      )
    rescue DhanHQ::InputExceptionError => e
      @logger.warn("DHAN: API error for LTP - #{e.message}")
      return { ltp: nil, ltt: nil, security_id: security_id, exchange_segment: exchange_segment }
    rescue => e
      @logger.error("DHAN: Unexpected error getting LTP - #{e.class}: #{e.message}")
      return { ltp: nil, ltt: nil, security_id: security_id, exchange_segment: exchange_segment }
    end

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

