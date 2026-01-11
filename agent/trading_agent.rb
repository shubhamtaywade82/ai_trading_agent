require_relative "../lib/logger"
require "date"
require "json"

class TradingAgent
  def initialize(llm:, planner_router:)
    @llm = llm
    @planner_router = planner_router
    @logger = AgentLogger.init
    @user_query = nil  # Will be set in run method
  end

  def run(user_query:, account_context:)
    @user_query = user_query  # Store for later use
    @logger.info("=" * 60)
    @logger.info("AGENT: Starting execution")
    @logger.info("AGENT: User query: #{user_query}")
    @logger.info("=" * 60)

    # Build tool definitions for Ollama
    tools = [
      {
        type: "function",
        function: {
          name: "find_instrument",
          description: "Find an instrument by symbol and exchange segment. This is the FIRST step (O1) - you MUST call this first.",
          parameters: {
            type: "object",
            properties: {
              symbol: { type: "string", description: "Trading symbol (e.g., 'NIFTY', 'RELIANCE')" },
              segment: { type: "string", description: "Exchange segment (e.g., 'IDX_I' for indices, 'NSE_EQ' for equity, 'NSE_FNO' for F&O)" }
            },
            required: ["symbol", "segment"]
          }
        }
      },
      {
        type: "function",
        function: {
          name: "get_daily_ohlcv",
          description: "Get daily OHLCV (Open, High, Low, Close, Volume) data. This is step O2 - call after find_instrument.",
          parameters: {
            type: "object",
            properties: {
              security_id: { type: "string", description: "Security ID from find_instrument result" },
              exchange_segment: { type: "string", description: "Exchange segment from find_instrument result" },
              from_date: { type: "string", description: "Start date in YYYY-MM-DD format. MUST be today (#{Date.today.strftime('%Y-%m-%d')}) or earlier. NEVER use future dates. Recommended: #{((Date.today - 30).strftime('%Y-%m-%d'))}" },
              to_date: { type: "string", description: "End date in YYYY-MM-DD format. MUST be today (#{Date.today.strftime('%Y-%m-%d')}) or earlier. NEVER use future dates. Recommended: #{Date.today.strftime('%Y-%m-%d')}" }
            },
            required: ["security_id", "exchange_segment", "from_date", "to_date"]
          }
        }
      },
      {
        type: "function",
        function: {
          name: "get_intraday_ohlcv",
          description: "Get intraday OHLCV data. This is step O3 - call after get_daily_ohlcv.",
          parameters: {
            type: "object",
            properties: {
              security_id: { type: "string", description: "Security ID from find_instrument result" },
              exchange_segment: { type: "string", description: "Exchange segment from find_instrument result" },
              from_date: { type: "string", description: "Start date in YYYY-MM-DD format. MUST be today (#{Date.today.strftime('%Y-%m-%d')}) or earlier. NEVER use future dates. For intraday, use today's date: #{Date.today.strftime('%Y-%m-%d')}" },
              to_date: { type: "string", description: "End date in YYYY-MM-DD format. MUST be today (#{Date.today.strftime('%Y-%m-%d')}) or earlier. NEVER use future dates. For intraday, use today's date: #{Date.today.strftime('%Y-%m-%d')}" },
              interval: { type: "string", description: "Interval in minutes: '1', '5', '15', '30', or '60' (default: '5')" }
            },
            required: ["security_id", "exchange_segment", "from_date", "to_date"]
          }
        }
      },
      {
        type: "function",
        function: {
          name: "get_option_chain",
          description: "Get option chain data for an underlying. This is step O4 - call after get_intraday_ohlcv.",
          parameters: {
            type: "object",
            properties: {
              security_id: { type: "string", description: "Security ID from find_instrument result" },
              exchange_segment: { type: "string", description: "Exchange segment from find_instrument result" },
              expiry: { type: "string", description: "Expiry date in YYYY-MM-DD format (optional, will use nearest if not provided)" }
            },
            required: ["security_id", "exchange_segment"]
          }
        }
      },
      {
        type: "function",
        function: {
          name: "get_ltp",
          description: "Get Last Traded Price (LTP) for an instrument. This is step O5 - call after get_option_chain.",
          parameters: {
            type: "object",
            properties: {
              security_id: { type: "string", description: "Security ID from find_instrument result" },
              exchange_segment: { type: "string", description: "Exchange segment from find_instrument result" }
            },
            required: ["security_id", "exchange_segment"]
          }
        }
      }
    ]

    today_str = Date.today.strftime('%Y-%m-%d')
    thirty_days_ago_str = (Date.today - 30).strftime('%Y-%m-%d')

    # Calculate last trading day (most recent weekday, excluding weekends)
    last_trading_day_obj = Date.today
    while last_trading_day_obj.saturday? || last_trading_day_obj.sunday?
      last_trading_day_obj -= 1
    end
    last_trading_day_str = last_trading_day_obj.strftime('%Y-%m-%d')

    # Calculate last trading day - 1 (for intraday from_date)
    last_trading_day_minus_one_obj = last_trading_day_obj - 1
    while last_trading_day_minus_one_obj.saturday? || last_trading_day_minus_one_obj.sunday?
      last_trading_day_minus_one_obj -= 1
    end
    last_trading_day_minus_one_str = last_trading_day_minus_one_obj.strftime('%Y-%m-%d')

    system_prompt = <<~PROMPT
      You are a trading analysis agent. You MUST use the available tools to get real market data.

      ⚠️ CRITICAL: TODAY'S DATE IS #{today_str} - NEVER USE FUTURE DATES ⚠️

      ⚠️ STRICT ANTI-HALLUCINATION RULES ⚠️

      FORBIDDEN - DO NOT DO THESE:
      ❌ NEVER describe or explain what tools to call - YOU MUST ACTUALLY CALL THEM
      ❌ NEVER write "Step 1: Call find_instrument..." - INSTEAD, ACTUALLY CALL find_instrument
      ❌ NEVER write code examples (Python, Ruby, JSON) showing how to call tools - ACTUALLY CALL THEM
      ❌ NEVER write "I will call..." or "Now I will call..." - ACTUALLY CALL THE TOOL
      ❌ NEVER write "Please wait for the result" - ACTUALLY CALL THE TOOL and the system will wait automatically
      ❌ NEVER use placeholders like [Current Price], [Today's Date], <security_id>, <from find_instrument result>
      ❌ NEVER make up or estimate market data (prices, volumes, indicators, ratios)
      ❌ NEVER use generic statements like "approximately" or "around" without real data
      ❌ NEVER provide analysis without calling tools first
      ❌ NEVER return a response that contains placeholder brackets [ ] or generic values
      ❌ NEVER calculate indicators (RSI, Bollinger Bands, etc.) without real OHLCV data
      ❌ NEVER assume or guess market conditions
      ❌ NEVER use future dates - today is #{today_str}, so dates like 2026-01-12 are FORBIDDEN

      REQUIRED - YOU MUST DO THESE:
      ✅ ALWAYS ACTUALLY CALL tools using the tool calling function - DO NOT describe them, DO NOT write code examples
      ✅ ALWAYS use the tool_calls format - when you want to call a tool, use the tool calling mechanism, not text description
      ✅ ALWAYS use real data from tool responses - quote exact numbers from tool results
      ✅ ALWAYS extract actual values from previous tool results (e.g., if find_instrument returns security_id="13", use "13" directly)
      ✅ ALWAYS state "Data not available" if a tool returns empty/null results
      ✅ ALWAYS use dates that are #{today_str} or earlier - NEVER use future dates
      ✅ For get_daily_ohlcv: use from_date="#{thirty_days_ago_str}" and to_date="#{today_str}" (from_date MUST be < to_date, from_date MUST be < last trading day)
      ✅ For get_intraday_ohlcv: use from_date="#{last_trading_day_minus_one_str}" and to_date="#{today_str}" (from_date MUST be < to_date, from_date MUST be < last trading day)
      ✅ ALWAYS wait for tool responses before making any analysis
      ✅ ALWAYS cite the source: "According to the data from [tool_name]..."

      WORKFLOW - UNDERSTAND USER INTENT FIRST:

      ⚠️ CRITICAL: Analyze the user's query to determine what they want:

      SIMPLE QUERIES (only call find_instrument):
      - If user asks: "find instrument", "get instrument", "instrument details", "show instrument", "what is [symbol] instrument"
      - ONLY call find_instrument tool
      - Return the instrument details and STOP immediately
      - DO NOT call any other tools

      OHLCV QUERIES (find_instrument + OHLCV data):
      - If user asks: "ohlcv", "daily ohlcv", "intraday ohlcv", "get ohlcv", "show ohlcv", "ohlcv data", "price data", "historical data"
      - ⚠️ CRITICAL: You MUST call tools ONE AT A TIME using the tool calling function - DO NOT describe them, DO NOT write code
      - Step 1: ACTUALLY CALL find_instrument(symbol="NIFTY", segment="IDX_I") using tool_calls - WAIT for result
      - Step 2: Read the security_id from Step 1 result (it will be in the conversation), then:
        * If user asks for "daily" or "daily ohlcv" → ACTUALLY CALL get_daily_ohlcv using tool_calls with the actual security_id value (e.g., "13") from Step 1, from_date="#{thirty_days_ago_str}", to_date="#{today_str}" (from_date MUST be < to_date, from_date MUST be < last trading day)
        * If user asks for "intraday" or "1 minute" or "5 minute" or "15 minute" → ACTUALLY CALL get_intraday_ohlcv using tool_calls with appropriate interval:
          - "1 minute" or "1min" → interval="1"
          - "5 minute" or "5min" → interval="5"
          - "15 minute" or "15min" → interval="15"
          - from_date MUST be < to_date, from_date MUST be < last trading day (e.g., from_date="#{last_trading_day_minus_one_str}", to_date="#{today_str}")
      - Step 3: If user asks for multiple intervals, call get_intraday_ohlcv ONCE per interval using tool_calls, WAITING for each result before calling the next
      - Return the OHLCV data and STOP (do NOT call get_option_chain or get_ltp)
      - ⚠️ NEVER use placeholders like <security_id> or <from find_instrument result> - you MUST use the actual value (e.g., "13") from the previous tool result
      - ⚠️ NEVER call multiple tools at once - call ONE tool using tool_calls, wait for result, then call the next
      - ⚠️ NEVER describe tools or write code examples - ACTUALLY CALL THEM using tool_calls

      ANALYSIS QUERIES (complete all 5 steps):
      - If user asks: "can I buy", "should I buy", "analysis", "recommendation", "trading advice", "buy recommendation"
      - THEN follow the FULL 5-step workflow:
        Step 1: ACTUALLY CALL find_instrument(symbol="NIFTY", segment="IDX_I") - Use tool calling function, don't describe it
        Step 2: Use security_id from Step 1 → ACTUALLY CALL get_daily_ohlcv(security_id, exchange_segment, from_date="#{thirty_days_ago_str}", to_date="#{today_str}") - from_date MUST be < to_date, from_date MUST be < last trading day
        Step 3: Use security_id from Step 1 → ACTUALLY CALL get_intraday_ohlcv(security_id, exchange_segment, from_date="#{last_trading_day_minus_one_str}", to_date="#{today_str}", interval="5") - from_date MUST be < to_date, from_date MUST be < last trading day
        Step 4: Use security_id from Step 1 → ACTUALLY CALL get_option_chain(security_id, exchange_segment)
        Step 5: Use security_id from Step 1 → ACTUALLY CALL get_ltp(security_id, exchange_segment)
        Step 6: ONLY AFTER completing ALL 5 steps → Provide analysis with exact numbers from tool results

      CRITICAL RULES:
      - If user only asks to find/get instrument details → ONLY call find_instrument, then STOP
      - If user asks for OHLCV data → Call find_instrument, then get_daily_ohlcv and/or get_intraday_ohlcv (with requested intervals), then STOP
      - If user asks for analysis/recommendation → THEN complete ALL 5 tool calls (O1→O5) before providing final analysis
      - If a tool returns empty data, note it and CONTINUE to the next tool (only if doing full analysis)
      - DO NOT describe the workflow - ACTUALLY EXECUTE IT by calling tools
      - DO NOT call unnecessary tools if user only wants specific data

      DATE CONSTRAINTS:
      - Today's date: #{today_str}
      - Last trading day (excluding weekends): #{last_trading_day_str}
      - 30 days ago: #{thirty_days_ago_str}
      - NEVER use dates after #{today_str}
      - to_date can be today (#{today_str}) or earlier
      - from_date MUST be < to_date (cannot be equal)
      - from_date MUST be < last trading day (excluding weekends) - cannot be on or after last trading day
      - For daily OHLCV: from_date should be #{thirty_days_ago_str}, to_date should be #{today_str} (from_date < to_date, from_date < last trading day)
      - For intraday OHLCV: from_date should be #{last_trading_day_minus_one_str}, to_date should be #{today_str} (from_date < to_date, from_date < last trading day)

      DATA AVAILABILITY:
      - If a tool returns empty data or error, state: "Data not available from [tool_name]"
      - If required data is missing, say: "Cannot provide recommendation - required data unavailable"
      - NEVER fill in missing data with estimates or assumptions

      RESPONSE VALIDATION:
      Before returning your final response, verify:
      1. All numbers come from tool responses (not invented)
      2. No placeholder text like [anything] exists
      3. All dates are #{today_str} or earlier (never future dates)
      4. All prices/values are exact numbers from tools

      REMEMBER: It's better to say "Data not available" than to hallucinate or estimate.
      REMEMBER: DO NOT DESCRIBE CALLING TOOLS - ACTUALLY CALL THEM USING THE TOOL CALLING FUNCTION.
    PROMPT

    conversation = [
      {
        role: "system",
        content: system_prompt
      },
      {
        role: "user",
        content: user_query
      }
    ]

    iteration = 0
    max_iterations = 20
    tools_called_count = 0

    loop do
      iteration += 1

      if iteration > max_iterations
        @logger.error("AGENT: Maximum iterations (#{max_iterations}) reached. Stopping.")
        return "Error: Maximum iterations reached. Please check the logs for details."
      end

      @logger.info("-" * 60)
      @logger.info("AGENT: Iteration ##{iteration}")
      @logger.debug("AGENT: Sending to LLM - #{conversation.length} messages in conversation")
      @logger.debug("AGENT: Tools called so far: #{tools_called_count}")

      response = @llm.chat(conversation, tools: tools)

      @logger.info("AGENT: Received LLM response")
      @logger.debug("AGENT: Response content length: #{response[:content]&.length || 0} chars")
      @logger.debug("AGENT: Tool calls: #{response[:tool_calls] ? response[:tool_calls].length : 0}")

      # TERMINAL RESPONSE
      if response[:tool_calls].nil? || response[:tool_calls].empty?
        @logger.info("AGENT: Terminal response received (no tool calls)")
        @logger.info("AGENT: Final content: #{response[:content]}")

        # STRICT CHECK: If no tools were called yet, force tool usage
        if tools_called_count == 0
          @logger.warn("AGENT: WARNING - No tools called yet but LLM returned response!")
          @logger.warn("AGENT: This is FORBIDDEN - forcing tool usage")

          conversation << {
            role: "user",
            content: "STOP. You MUST call tools to get real data. You cannot provide analysis without calling find_instrument first. Call find_instrument(symbol='NIFTY', segment='IDX_I') immediately."
          }
          next  # Retry the loop
        end

        # Check if user query is simple (just finding instrument) - CHECK THIS FIRST
        user_query_lower = @user_query.downcase
        is_simple_query = user_query_lower.match?(/find.*instrument|get.*instrument|instrument.*details|show.*instrument|what.*instrument|fing.*instrument/i)
        is_ohlcv_query = user_query_lower.match?(/ohlcv|daily.*ohlcv|intraday.*ohlcv|get.*ohlcv|show.*ohlcv|ohlcv.*data|price.*data|historical.*data|1.*minute|5.*minute|15.*minute|1min|5min|15min/i)

        @logger.debug("AGENT: Query type check - query: '#{@user_query}', is_simple_query: #{is_simple_query}, is_ohlcv_query: #{is_ohlcv_query}, tools_called_count: #{tools_called_count}")

        # If it's a simple query and we've found the instrument, allow early termination
        if is_simple_query && tools_called_count >= 1
          find_instrument_called = conversation.any? { |msg| msg[:role] == "tool" && msg[:name] == "find_instrument" }
          @logger.debug("AGENT: find_instrument_called check: #{find_instrument_called}")
          if find_instrument_called
            @logger.info("AGENT: Simple query detected - user only asked for instrument details. Allowing early termination.")
            return response[:content]
          else
            @logger.debug("AGENT: Simple query detected but find_instrument not found in conversation yet")
          end
        end

        # If it's an OHLCV query, check if we've completed the required steps
        if is_ohlcv_query && tools_called_count >= 1
          find_instrument_called = conversation.any? { |msg| msg[:role] == "tool" && msg[:name] == "find_instrument" }
          daily_ohlcv_called = conversation.any? { |msg| msg[:role] == "tool" && msg[:name] == "get_daily_ohlcv" }
          intraday_ohlcv_called = conversation.any? { |msg| msg[:role] == "tool" && msg[:name] == "get_intraday_ohlcv" }

          # Check if user wants daily data
          wants_daily = user_query_lower.match?(/daily/i)
          # Check if user wants intraday data (and which intervals)
          wants_intraday = user_query_lower.match?(/intraday|1.*minute|5.*minute|15.*minute|1min|5min|15min/i)

          # If user asked for daily and we've called it, or if user asked for intraday and we've called it, allow termination
          if find_instrument_called && ((wants_daily && daily_ohlcv_called) || (wants_intraday && intraday_ohlcv_called) || (!wants_daily && !wants_intraday && (daily_ohlcv_called || intraday_ohlcv_called)))
            @logger.info("AGENT: OHLCV query detected - user asked for OHLCV data. Allowing early termination after OHLCV tools.")
            return response[:content]
          end
        end

        # Check if LLM is describing actions instead of calling tools
        if describes_tool_usage?(response[:content]) && !is_simple_query
          @logger.warn("AGENT: WARNING - LLM is describing tool usage instead of calling tools!")
          @logger.warn("AGENT: Response contains descriptions/placeholders instead of actual tool calls")

          # Extract security_id and exchange_segment from previous tool result if available
          security_id = "13"  # Default
          exchange_segment = "IDX_I"  # Default
          find_result = conversation.find { |msg| msg[:role] == "tool" && msg[:name] == "find_instrument" }
          if find_result && find_result[:content]
            begin
              find_data = JSON.parse(find_result[:content])
              security_id = find_data["security_id"] || find_data[:security_id] || "13"
              exchange_segment = find_data["exchange_segment"] || find_data[:exchange_segment] || "IDX_I"
            rescue
              # Keep defaults
            end
          end

          today = Date.today
          thirty_days_ago = today - 30

          # Determine which tool should be called next
          if tools_called_count == 0
            instruction = "You MUST call find_instrument(symbol='NIFTY', segment='IDX_I') using the tool calling function. Do NOT describe it, do NOT write code, do NOT use placeholders - ACTUALLY CALL IT."
          elsif tools_called_count == 1 && is_ohlcv_query
            wants_daily = @user_query.downcase.match?(/daily/i)
            if wants_daily
              instruction = "You MUST call get_daily_ohlcv(security_id='#{security_id}', exchange_segment='#{exchange_segment}', from_date='#{thirty_days_ago.strftime('%Y-%m-%d')}', to_date='#{today.strftime('%Y-%m-%d')}') using the tool calling function. Use the actual security_id='#{security_id}' and exchange_segment='#{exchange_segment}' from the previous result, not a placeholder."
            else
              instruction = "You MUST call get_intraday_ohlcv(security_id='#{security_id}', exchange_segment='#{exchange_segment}', from_date='#{today.strftime('%Y-%m-%d')}', to_date='#{today.strftime('%Y-%m-%d')}', interval='1') using the tool calling function. Use the actual security_id='#{security_id}' and exchange_segment='#{exchange_segment}' from the previous result."
            end
          else
            instruction = "You described calling a tool but did not actually call it. You MUST use the tool calling function (tool_calls), not describe it in text, not write code examples, not use placeholders. ACTUALLY CALL THE TOOL with real values from previous tool results."
          end

          # Provide explicit example of tool calling format
          tool_call_example = if tools_called_count == 0
            "Use tool_calls like: {\"function\": {\"name\": \"find_instrument\", \"arguments\": {\"symbol\": \"NIFTY\", \"segment\": \"IDX_I\"}}}"
          elsif tools_called_count == 1 && is_ohlcv_query && @user_query.downcase.match?(/daily/i)
            "Use tool_calls like: {\"function\": {\"name\": \"get_daily_ohlcv\", \"arguments\": {\"security_id\": \"#{security_id}\", \"exchange_segment\": \"#{exchange_segment}\", \"from_date\": \"#{thirty_days_ago.strftime('%Y-%m-%d')}\", \"to_date\": \"#{today.strftime('%Y-%m-%d')}\"}}}"
          else
            "Use the tool_calls format with actual values from previous tool results."
          end

          conversation << {
            role: "user",
            content: "STOP. #{instruction} You are FORBIDDEN from describing tools, writing code examples, or using placeholders. You MUST use the tool calling function (tool_calls) with actual values. Example format: #{tool_call_example}. If you see security_id='#{security_id}' and exchange_segment='#{exchange_segment}' in a previous tool result, use '#{security_id}' and '#{exchange_segment}' directly in your tool call, not '<security_id>' or '<from find_instrument result>'."
          }
          next  # Retry the loop
        end

        # STRICT CHECK: Must complete all 5 steps before final response (only for analysis queries)
        if tools_called_count < 5 && !is_simple_query && !is_ohlcv_query
          @logger.warn("AGENT: WARNING - Only #{tools_called_count}/5 tools called. Forcing continuation.")

          # Get the last tool result to extract security_id
          last_tool_result = conversation.reverse.find { |msg| msg[:role] == "tool" }
          security_id = "13"  # Default from find_instrument

          if last_tool_result && last_tool_result[:content]
            begin
              tool_data = JSON.parse(last_tool_result[:content])
              security_id = tool_data["security_id"] || tool_data[:security_id] || "13"
            rescue
              # If parsing fails, try to extract from find_instrument result
              find_result = conversation.find { |msg| msg[:role] == "tool" && msg[:name] == "find_instrument" }
              if find_result
                begin
                  find_data = JSON.parse(find_result[:content])
                  security_id = find_data["security_id"] || find_data[:security_id] || "13"
                rescue
                end
              end
            end
          end

          today = Date.today
          thirty_days_ago = today - 30

          next_tool_map = {
            1 => { name: "get_daily_ohlcv", args: { security_id: security_id, exchange_segment: "IDX_I", from_date: thirty_days_ago.strftime('%Y-%m-%d'), to_date: today.strftime('%Y-%m-%d') } },
            2 => { name: "get_intraday_ohlcv", args: { security_id: security_id, exchange_segment: "IDX_I", from_date: today.strftime('%Y-%m-%d'), to_date: today.strftime('%Y-%m-%d'), interval: "5" } },
            3 => { name: "get_option_chain", args: { security_id: security_id, exchange_segment: "IDX_I" } },
            4 => { name: "get_ltp", args: { security_id: security_id, exchange_segment: "IDX_I" } }
          }

          next_tool = next_tool_map[tools_called_count]

          if next_tool
            @logger.info("AGENT: Forcing call to #{next_tool[:name]} (step #{tools_called_count + 1}/5)")
            conversation << {
              role: "user",
              content: "You must complete ALL 5 steps. You have only completed #{tools_called_count}/5. You MUST call #{next_tool[:name]} next. Even if previous tools returned empty data, you must continue. Call #{next_tool[:name]}(#{next_tool[:args].map { |k, v| "#{k}='#{v}'" }.join(', ')}) now."
            }
          else
            conversation << {
              role: "user",
              content: "You must complete all 5 tool calls before providing final analysis. Continue with the remaining tools."
            }
          end
          next  # Retry the loop
        end

        # Validate response for hallucination
        if contains_hallucinated_data?(response[:content])
          @logger.warn("AGENT: WARNING - Response contains hallucinated data (placeholders detected)!")
          @logger.warn("AGENT: Re-requesting with stronger anti-hallucination instruction")

          # Add a follow-up message to force tool usage
          conversation << {
            role: "user",
            content: "Your response contains placeholders like [Current Price] or [Today's Date]. This is FORBIDDEN. You must use ONLY real data from tool responses. If data is not available, say 'Data not available' - do NOT make up values."
          }
          next  # Retry the loop
        end

        @logger.info("AGENT: Response validated - no hallucination detected")
        return response[:content]
      end

      # If LLM tries to call multiple tools at once, reject and instruct to call one at a time
      # This enforces sequential execution and prevents placeholders
      if response[:tool_calls].length > 1
        @logger.warn("AGENT: WARNING - LLM tried to call #{response[:tool_calls].length} tools at once!")
        @logger.warn("AGENT: This is not allowed - tools must be called sequentially. Tool calls attempted: #{response[:tool_calls].map { |tc| tc['name'] || tc[:name] }.join(', ')}")

        # Check if any tool call uses placeholders
        has_placeholders = response[:tool_calls].any? do |tc|
          args = tc["arguments"] || tc[:arguments] || {}
          args_str = args.to_json
          args_str.match?(/<security_id>|<from_step1>|placeholder/i)
        end

        if has_placeholders
          @logger.warn("AGENT: WARNING - LLM used placeholders in tool arguments!")
          conversation << {
            role: "user",
            content: "STOP. You tried to call multiple tools at once and used placeholders like <security_id>. This is FORBIDDEN. You MUST call tools ONE AT A TIME. First, call find_instrument(symbol='NIFTY', segment='IDX_I') and WAIT for the result. Then use the actual security_id value from that result (e.g., '13') to call the next tool. Never use placeholders - always use real values from previous tool results."
          }
        else
          conversation << {
            role: "user",
            content: "STOP. You tried to call #{response[:tool_calls].length} tools at once. This is FORBIDDEN. You MUST call tools ONE AT A TIME. Call the first tool (find_instrument), WAIT for the result, then use that result to call the next tool. Never call multiple tools simultaneously."
          }
        end
        next  # Retry the loop
      end

      # Track that tools are being called
      tools_called_count += response[:tool_calls].length

      @logger.info("AGENT: Processing #{response[:tool_calls].length} tool call(s)")

      response[:tool_calls].each_with_index do |tool_call, idx|
        tool_name = tool_call["name"] || tool_call[:name] || ""
        tool_args = tool_call["arguments"] || tool_call[:arguments] || {}

        @logger.info("AGENT: Tool call ##{idx + 1}: #{tool_name}")
        @logger.debug("AGENT: Tool arguments: #{tool_args.inspect}")

        # Validate tool call has a name
        if tool_name.empty?
          @logger.error("AGENT: ERROR - Tool call has empty name! Raw: #{tool_call.inspect}")
          @logger.error("AGENT: Skipping invalid tool call and requesting retry")

          conversation << {
            role: "user",
            content: "The tool call you made was invalid (empty tool name). Please call find_instrument(symbol='NIFTY', segment='IDX_I') with the correct format."
          }
          next
        end

        # Validate tool call doesn't use placeholders
        tool_args_str = (tool_args || {}).to_json
        if tool_args_str.match?(/<security_id>|<from_step1>|placeholder/i)
          @logger.error("AGENT: ERROR - Tool call uses placeholders! Tool: #{tool_name}, Args: #{tool_args_str}")
          @logger.error("AGENT: You must use actual values from previous tool results, not placeholders")

          conversation << {
            role: "user",
            content: "STOP. You used a placeholder like <security_id> in your tool call. This is FORBIDDEN. You MUST use the actual security_id value from the previous find_instrument result. Look at the tool results in the conversation and use the real security_id value (e.g., '13' for NIFTY), not a placeholder."
          }
          next
        end

        result = @planner_router.handle!(
          tool_call: { "name" => tool_name, "arguments" => tool_args },
          account_context: account_context
        )

        @logger.info("AGENT: Tool '#{tool_call['name']}' completed")
        @logger.debug("AGENT: Tool result: #{result.inspect}")

        # Format tool result for Ollama - content should be a string (JSON)
        tool_content = if result.is_a?(Hash) || result.is_a?(Array)
          result.to_json
        else
          result.to_s
        end

        conversation << {
          role: "tool",
          name: tool_call["name"],
          content: tool_content
        }
      end
    end
  end

  private

  def describes_tool_usage?(content)
    # Check if LLM is describing tool calls instead of making them
    description_patterns = [
      /step\s+\d+.*call/i,
      /step\s+\d+:.*call/i,
      /proceed with calling/i,
      /now.*call/i,
      /let's.*call/i,
      /should call/i,
      /need to call/i,
      /will call/i,
      /going to call/i,
      /wait.*call/i,
      /i will call/i,
      /now i will/i,
      /result from find_instrument/i,
      /use security_id from step/i,
      /according to the data.*step/i,
      /extract.*from.*result/i,
      /please wait/i,
      /wait for.*result/i,
      /assuming.*result/i,
      /import\s+\w+/i,  # Python imports like "import tool_calling_function"
      /tcf\./i,  # tool_calling_function references
      /define.*parameter/i,
      /here.*function call/i,
      /here.*sequence/i,
      /here.*json/i,
      /note that.*not filled/i,
      /```(json|ruby|python|javascript)/i  # Code blocks
    ]

    # Also check for markdown code blocks or formatted text that looks like descriptions
    has_code_blocks = content.include?("```") || content.match?(/```json|```ruby|```python|```javascript/i)
    has_step_formatting = content.match?(/^Step \d+:/i) || content.match?(/Step \d+:/i)

    description_patterns.any? { |pattern| content.match?(pattern) } || has_code_blocks || has_step_formatting
  end

  def contains_hallucinated_data?(content)
    # Check for common hallucination patterns
    hallucination_patterns = [
      /\[.*?\]/,  # Placeholder brackets like [Current Price]
      /₹\[.*?\]/,  # Currency with placeholder
      /approximately.*?₹/i,  # Approximate prices without data
      /around.*?₹/i,  # Around prices without data
      /\[Today's Date\]/i,
      /\[Current Price\]/i,
      /\[Strike Price\]/i,
      /\[RSI Value\]/i,
      /\[MA Values\]/i,
      /\[Support Level.*?\]/i,
      /\[Resistance Level.*?\]/i,
      /\[Put-Call Ratio\]/i,
      /\[Stop-Loss Price\]/i,
      /\[Expiry Date\]/i,
      /\[BB Values\]/i,
      /\[Current Time\]/i
    ]

    hallucination_patterns.any? { |pattern| content.match?(pattern) }
  end
end

