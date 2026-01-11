require_relative "find_instrument"
require_relative "get_daily_ohlcv"
require_relative "get_intraday_ohlcv"
require_relative "get_option_chain"
require_relative "get_ltp"
require_relative "../lib/logger"

class ToolExecutor
  def self.execute(tool:, payload:, account_context:)
    logger = AgentLogger.init

    logger.info("EXECUTOR: Executing tool '#{tool}'")
    logger.debug("EXECUTOR: Payload: #{payload.inspect}")

    dhan_client = account_context[:dhan_client]

    # Convert payload to hash with symbol keys for keyword arguments
    payload_hash = payload.is_a?(Hash) ? payload : {}
    payload_hash = payload_hash.transform_keys(&:to_sym) if payload_hash.keys.first.is_a?(String)

    logger.debug("EXECUTOR: Converted payload: #{payload_hash.inspect}")

    result = case tool
    when "find_instrument"
      logger.debug("EXECUTOR: Calling FindInstrument")
      FindInstrument.call(**payload_hash, dhan_client: dhan_client)
    when "get_daily_ohlcv"
      logger.debug("EXECUTOR: Calling GetDailyOHLCV")
      GetDailyOHLCV.call(**payload_hash, dhan_client: dhan_client)
    when "get_intraday_ohlcv"
      logger.debug("EXECUTOR: Calling GetIntradayOHLCV")
      GetIntradayOHLCV.call(**payload_hash, dhan_client: dhan_client)
    when "get_option_chain"
      logger.debug("EXECUTOR: Calling GetOptionChain")
      GetOptionChain.call(**payload_hash, dhan_client: dhan_client)
    when "get_ltp"
      logger.debug("EXECUTOR: Calling GetLTP")
      GetLTP.call(**payload_hash, dhan_client: dhan_client)
    else
      logger.error("EXECUTOR: Unknown tool: #{tool}")
      raise "Unknown tool: #{tool}"
    end

    logger.info("EXECUTOR: Tool '#{tool}' completed successfully")
    logger.debug("EXECUTOR: Result type: #{result.class}, size: #{result.inspect.length} chars")

    result
  end
end

