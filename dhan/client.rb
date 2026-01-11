require "dhan_hq"
require_relative "../lib/logger"
require "date"

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
    # Note: The API requires instrument type, using "INDEX" as default for indices
    instrument_type = exchange_segment.start_with?("IDX_") ? "INDEX" : nil

    begin
      # Ensure security_id is a string (API requires string format)
      security_id_str = security_id.to_s

      @logger.debug("DHAN: Calling HistoricalData.daily with:")
      @logger.debug("DHAN:   security_id: #{security_id_str.inspect} (type: #{security_id_str.class})")
      @logger.debug("DHAN:   exchange_segment: #{exchange_segment.inspect}")
      @logger.debug("DHAN:   instrument: #{instrument_type.inspect}")
      @logger.debug("DHAN:   from_date: #{from_date.inspect}")
      @logger.debug("DHAN:   to_date: #{to_date.inspect}")

      result = DhanHQ::Models::HistoricalData.daily(
        security_id: security_id_str,
        exchange_segment: exchange_segment,
        instrument: instrument_type,
        from_date: from_date,
        to_date: to_date
      )

      @logger.debug("DHAN: HistoricalData.daily returned: #{result.class}")
      @logger.debug("DHAN: HistoricalData.daily result structure: #{result.inspect}")

      # Handle different response formats - API might return Hash or Array
      if result.is_a?(Hash)
        # First check for hash with OHLCV arrays (most common format from DhanHQ)
        if (result["open"] || result[:open]) && (result["high"] || result[:high]) && (result["low"] || result[:low]) && (result["close"] || result[:close])
          # Hash with arrays of OHLCV values - convert to array of objects
          @logger.info("DHAN: Found hash with OHLCV arrays - converting to array of objects")
          opens = result["open"] || result[:open] || []
          highs = result["high"] || result[:high] || []
          lows = result["low"] || result[:low] || []
          closes = result["close"] || result[:close] || []
          volumes = result["volume"] || result[:volume] || []
          timestamps = result["timestamp"] || result[:timestamp] || []

          # Convert to array of objects
          result = []
          max_length = [opens.length, highs.length, lows.length, closes.length].max

          max_length.times do |i|
            timestamp = timestamps[i]
            # Convert Unix timestamp to date string if needed
            date_str = if timestamp
              begin
                Time.at(timestamp.to_i).strftime('%Y-%m-%d')
              rescue
                nil
              end
            end

            result << {
              date: date_str,
              timestamp: timestamp,
              open: opens[i],
              high: highs[i],
              low: lows[i],
              close: closes[i],
              volume: volumes[i]
            }
          end

          @logger.info("DHAN: Converted hash with arrays to array of #{result.length} OHLCV objects")
        # Check if it's a hash with data array inside
        elsif result["data"] || result[:data]
          data_array = result["data"] || result[:data]
          @logger.debug("DHAN: Found data array in hash, size: #{data_array.is_a?(Array) ? data_array.length : 'N/A'}")
          result = data_array.is_a?(Array) ? data_array : []
        elsif result["ohlcv"] || result[:ohlcv]
          data_array = result["ohlcv"] || result[:ohlcv]
          @logger.debug("DHAN: Found ohlcv array in hash, size: #{data_array.is_a?(Array) ? data_array.length : 'N/A'}")
          result = data_array.is_a?(Array) ? data_array : []
        else
          # Hash might contain error or other structure - log all keys
          @logger.warn("DHAN: Daily API returned hash but no recognized structure. Keys: #{result.keys.inspect}")
          @logger.warn("DHAN: Full hash content: #{result.inspect}")
          return []
        end
      end

      @logger.debug("DHAN: Final processed result type: #{result.class}, size: #{result.is_a?(Array) ? result.length : 'N/A'}")
    rescue DhanHQ::InputExceptionError => e
      @logger.warn("DHAN: API error for daily data - #{e.message}")
      @logger.warn("DHAN: Full error details: #{e.inspect}")
      @logger.warn("DHAN: Returning empty array - data may not be available for these dates")
      return []
    rescue => e
      @logger.error("DHAN: Unexpected error getting daily data - #{e.class}: #{e.message}")
      @logger.error("DHAN: Full error backtrace: #{e.backtrace.join("\n")}")
      return []
    end

    # Normalize response format
    if result.is_a?(Array) && result.any?
      result.map do |row|
        {
          date: row["date"] || row[:date] || row["timestamp"] || row[:timestamp],
          open: row["open"] || row[:open],
          high: row["high"] || row[:high],
          low: row["low"] || row[:low],
          close: row["close"] || row[:close],
          volume: row["volume"] || row[:volume]
        }
      end
    else
      @logger.warn("DHAN: Daily API returned empty or invalid data structure")
      []
    end
  end

  def get_intraday_ohlcv(security_id:, exchange_segment:, from_date:, to_date:, interval: "5")
    @logger.info("DHAN: Getting intraday OHLCV - Security: #{security_id}, Segment: #{exchange_segment}, Interval: #{interval}min, From: #{from_date}, To: #{to_date}")
    # Use DhanHQ::Models::HistoricalData.intraday
    # interval: "1", "5", "15", "30", or "60" minutes
    instrument_type = exchange_segment.start_with?("IDX_") ? "INDEX" : nil

    begin
      # Ensure security_id is a string (API requires string format)
      security_id_str = security_id.to_s

      # Ensure interval is a string
      interval_str = interval.to_s

      @logger.debug("DHAN: Calling HistoricalData.intraday with:")
      @logger.debug("DHAN:   security_id: #{security_id_str.inspect} (type: #{security_id_str.class})")
      @logger.debug("DHAN:   exchange_segment: #{exchange_segment.inspect}")
      @logger.debug("DHAN:   instrument: #{instrument_type.inspect}")
      @logger.debug("DHAN:   interval: #{interval_str.inspect}")
      @logger.debug("DHAN:   from_date: #{from_date.inspect}")
      @logger.debug("DHAN:   to_date: #{to_date.inspect}")

      result = DhanHQ::Models::HistoricalData.intraday(
        security_id: security_id_str,
        exchange_segment: exchange_segment,
        instrument: instrument_type,
        interval: interval_str,
        from_date: from_date,
        to_date: to_date
      )

      @logger.debug("DHAN: HistoricalData.intraday returned: #{result.class}")
      @logger.debug("DHAN: HistoricalData.intraday result structure: #{result.inspect}")
      @logger.info("DHAN: Interval parameter '#{interval_str}' minutes was used for intraday data fetch")

      # Handle different response formats
      if result.is_a?(Hash)
        # Check if it's a hash with data array inside
        if result["data"] || result[:data]
          data_array = result["data"] || result[:data]
          @logger.debug("DHAN: Found data array in hash, size: #{data_array.is_a?(Array) ? data_array.length : 'N/A'}")
          result = data_array.is_a?(Array) ? data_array : []
        elsif result["ohlcv"] || result[:ohlcv]
          data_array = result["ohlcv"] || result[:ohlcv]
          @logger.debug("DHAN: Found ohlcv array in hash, size: #{data_array.is_a?(Array) ? data_array.length : 'N/A'}")
          result = data_array.is_a?(Array) ? data_array : []
        elsif result["open"] && result["high"] && result["low"] && result["close"]
          # Hash with arrays of OHLCV values - convert to array of objects
          @logger.debug("DHAN: Found hash with OHLCV arrays - converting to array of objects")
          opens = result["open"] || result[:open] || []
          highs = result["high"] || result[:high] || []
          lows = result["low"] || result[:low] || []
          closes = result["close"] || result[:close] || []
          volumes = result["volume"] || result[:volume] || []
          timestamps = result["timestamp"] || result[:timestamp] || []

          # Convert to array of objects
          result = []
          max_length = [opens.length, highs.length, lows.length, closes.length].max

          max_length.times do |i|
            timestamp = timestamps[i]
            # Convert Unix timestamp to datetime string if needed
            datetime_str = if timestamp
              begin
                Time.at(timestamp.to_i).strftime('%Y-%m-%d %H:%M:%S')
              rescue
                nil
              end
            end

            result << {
              timestamp: timestamp,
              datetime: datetime_str,
              open: opens[i],
              high: highs[i],
              low: lows[i],
              close: closes[i],
              volume: volumes[i]
            }
          end

          @logger.info("DHAN: Converted hash with arrays to array of #{result.length} intraday OHLCV objects")
        else
          # Hash might contain error or other structure
          @logger.warn("DHAN: Intraday API returned hash but no recognized structure. Keys: #{result.keys.inspect}")
          @logger.warn("DHAN: Full hash content: #{result.inspect}")
          return []
        end
      end

      @logger.debug("DHAN: Final processed result type: #{result.class}, size: #{result.is_a?(Array) ? result.length : 'N/A'}")
    rescue DhanHQ::InputExceptionError => e
      @logger.warn("DHAN: API error for intraday data - #{e.message}")
      @logger.warn("DHAN: Full error details: #{e.inspect}")
      @logger.warn("DHAN: Interval used was: #{interval_str} minutes")
      @logger.warn("DHAN: Returning empty array - data may not be available for these dates")
      return []
    rescue => e
      @logger.error("DHAN: Unexpected error getting intraday data - #{e.class}: #{e.message}")
      @logger.error("DHAN: Full error backtrace: #{e.backtrace.join("\n")}")
      return []
    end

    # Normalize response format
    if result.is_a?(Array) && result.any?
      result.map do |row|
        {
          timestamp: row["timestamp"] || row[:timestamp] || row["date"] || row[:date],
          open: row["open"] || row[:open],
          high: row["high"] || row[:high],
          low: row["low"] || row[:low],
          close: row["close"] || row[:close],
          volume: row["volume"] || row[:volume]
        }
      end
    else
      @logger.warn("DHAN: Intraday API returned empty or invalid data structure")
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


        pp "expiries---------------------------------------------------------------------------------------------------------"
        pp expiries
        pp expiries.is_a?(Array)
        pp expiries.any?
        pp expiries.inspect
        pp expiries.length
        pp expiries.first
        pp expiries.last
        pp expiries.first.inspect
        pp expiries.last.inspect
        # Find the latest next expiry date (earliest future date)
        if expiries.is_a?(Array) && expiries.any?
          @logger.debug("DHAN: Fetched expiry list: #{expiries.inspect}")

          # Extract all expiry dates and parse them
          expiry_dates = []
          expiries.each do |expiry_item|
            expiry_str = if expiry_item.is_a?(Hash)
              expiry_item["expiry"] || expiry_item[:expiry] || expiry_item["expiry_date"] || expiry_item[:expiry_date]
            else
              expiry_item.to_s
            end

            if expiry_str
              begin
                # Try to parse the date - handle multiple formats
                parsed_date = if expiry_str.match?(/^\d{4}-\d{2}-\d{2}$/)
                  # YYYY-MM-DD format
                  Date.parse(expiry_str)
                elsif expiry_str.match?(/^\d{2}-\d{2}-\d{4}$/)
                  # DD-MM-YYYY format
                  Date.strptime(expiry_str, '%d-%m-%Y')
                elsif expiry_str.match?(/^\d{2}\/\d{2}\/\d{4}$/)
                  # DD/MM/YYYY format
                  Date.strptime(expiry_str, '%d/%m/%Y')
                else
                  # Try generic parse
                  Date.parse(expiry_str)
                end
                expiry_dates << { date: parsed_date, string: expiry_str }
              rescue => e
                @logger.warn("DHAN: Could not parse expiry date '#{expiry_str}': #{e.message}")
              end
            end
          end

          if expiry_dates.any?
            today = Date.today
            # Filter to only future dates (>= today)
            future_expiries = expiry_dates.select { |ed| ed[:date] >= today }

            if future_expiries.any?
              # Find the earliest future date (latest next expiry)
              next_expiry = future_expiries.min_by { |ed| ed[:date] }
              expiry = next_expiry[:string]
              @logger.info("DHAN: Found #{future_expiries.length} future expiry(ies). Using next expiry: #{expiry} (#{next_expiry[:date]})")
            else
              # If no future dates, use the latest expiry (closest to today)
              next_expiry = expiry_dates.max_by { |ed| ed[:date] }
              expiry = next_expiry[:string]
              @logger.warn("DHAN: No future expiries found. Using latest expiry: #{expiry} (#{next_expiry[:date]})")
            end

            if expiry
              result = DhanHQ::Models::OptionChain.fetch(
                underlying_scrip: security_id.to_i,
                underlying_seg: exchange_segment,
                expiry: expiry
              )
            else
              @logger.warn("DHAN: Could not determine expiry from expiry list")
              return { atm: nil, ce: [], pe: [], expiry_dates: [], strikes: [] }
            end
          else
            @logger.warn("DHAN: Could not parse any expiry dates from: #{expiries.inspect}")
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

