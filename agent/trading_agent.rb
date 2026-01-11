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

    system_prompt = <<~PROMPT
      You are a trading analysis agent. You MUST use the available tools to get real market data.

      ⚠️ CRITICAL: TODAY'S DATE IS #{today_str} - NEVER USE FUTURE DATES ⚠️

      ⚠️ STRICT ANTI-HALLUCINATION RULES ⚠️

      FORBIDDEN - DO NOT DO THESE:
      ❌ NEVER describe or explain what tools to call - YOU MUST ACTUALLY CALL THEM
      ❌ NEVER write "Step 1: Call find_instrument..." - INSTEAD, ACTUALLY CALL find_instrument
      ❌ NEVER use placeholders like [Current Price], [Today's Date], [Strike Price], [RSI Value], [MA Values]
      ❌ NEVER make up or estimate market data (prices, volumes, indicators, ratios)
      ❌ NEVER use generic statements like "approximately" or "around" without real data
      ❌ NEVER provide analysis without calling tools first
      ❌ NEVER return a response that contains placeholder brackets [ ] or generic values
      ❌ NEVER calculate indicators (RSI, Bollinger Bands, etc.) without real OHLCV data
      ❌ NEVER assume or guess market conditions
      ❌ NEVER use future dates - today is #{today_str}, so dates like 2026-01-12 are FORBIDDEN

      REQUIRED - YOU MUST DO THESE:
      ✅ ALWAYS ACTUALLY CALL tools (don't describe calling them) in this exact order: find_instrument → get_daily_ohlcv → get_intraday_ohlcv → get_option_chain → get_ltp
      ✅ ALWAYS use real data from tool responses - quote exact numbers from tool results
      ✅ ALWAYS state "Data not available" if a tool returns empty/null results
      ✅ ALWAYS use dates that are #{today_str} or earlier - NEVER use future dates
      ✅ For get_daily_ohlcv: use from_date="#{thirty_days_ago_str}" and to_date="#{today_str}"
      ✅ For get_intraday_ohlcv: use from_date="#{today_str}" and to_date="#{today_str}"
      ✅ ALWAYS wait for tool responses before making any analysis
      ✅ ALWAYS cite the source: "According to the data from [tool_name]..."

      WORKFLOW - UNDERSTAND USER INTENT FIRST:

      ⚠️ CRITICAL: Analyze the user's query to determine what they want:

      SIMPLE QUERIES (only call find_instrument):
      - If user asks: "find instrument", "get instrument", "instrument details", "show instrument", "what is [symbol] instrument"
      - ONLY call find_instrument tool
      - Return the instrument details and STOP immediately
      - DO NOT call any other tools (get_daily_ohlcv, get_intraday_ohlcv, get_option_chain, get_ltp)

      ANALYSIS QUERIES (complete all 5 steps):
      - If user asks: "can I buy", "should I buy", "analysis", "recommendation", "trading advice", "buy recommendation"
      - THEN follow the FULL 5-step workflow:
        Step 1: ACTUALLY CALL find_instrument(symbol="NIFTY", segment="IDX_I") - Use tool calling function, don't describe it
        Step 2: Use security_id from Step 1 → ACTUALLY CALL get_daily_ohlcv(security_id, exchange_segment, from_date="#{thirty_days_ago_str}", to_date="#{today_str}")
        Step 3: Use security_id from Step 1 → ACTUALLY CALL get_intraday_ohlcv(security_id, exchange_segment, from_date="#{today_str}", to_date="#{today_str}", interval="5")
        Step 4: Use security_id from Step 1 → ACTUALLY CALL get_option_chain(security_id, exchange_segment)
        Step 5: Use security_id from Step 1 → ACTUALLY CALL get_ltp(security_id, exchange_segment)
        Step 6: ONLY AFTER completing ALL 5 steps → Provide analysis with exact numbers from tool results

      CRITICAL RULES:
      - If user only asks to find/get instrument details → ONLY call find_instrument, then STOP and return result
      - If user asks for analysis/recommendation → THEN complete ALL 5 tool calls (O1→O5) before providing final analysis
      - If a tool returns empty data, note it and CONTINUE to the next tool (only if doing full analysis)
      - DO NOT describe the workflow - ACTUALLY EXECUTE IT by calling tools
      - DO NOT call unnecessary tools if user only wants instrument information

      DATE CONSTRAINTS:
      - Today's date: #{today_str}
      - 30 days ago: #{thirty_days_ago_str}
      - NEVER use dates after #{today_str}
      - For daily OHLCV: from_date should be #{thirty_days_ago_str}, to_date should be #{today_str}
      - For intraday OHLCV: both from_date and to_date should be #{today_str}

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

        @logger.debug("AGENT: Simple query check - query: '#{@user_query}', is_simple_query: #{is_simple_query}, tools_called_count: #{tools_called_count}")

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

        # Check if LLM is describing actions instead of calling tools (only for analysis queries)
        if describes_tool_usage?(response[:content]) && tools_called_count < 5 && !is_simple_query
          @logger.warn("AGENT: WARNING - LLM is describing tool usage instead of calling tools!")
          @logger.warn("AGENT: Tools called so far: #{tools_called_count}/5 - forcing next tool call")

          # Determine which tool should be called next based on tools_called_count
          today = Date.today
          thirty_days_ago = today - 30

          next_tool_instructions = {
            1 => "Call get_daily_ohlcv with security_id=13, exchange_segment='IDX_I', from_date='#{thirty_days_ago.strftime('%Y-%m-%d')}', to_date='#{today.strftime('%Y-%m-%d')}'",
            2 => "Call get_intraday_ohlcv with security_id=13, exchange_segment='IDX_I', from_date='#{today.strftime('%Y-%m-%d')}', to_date='#{today.strftime('%Y-%m-%d')}', interval='5'",
            3 => "Call get_option_chain with security_id=13, exchange_segment='IDX_I'",
            4 => "Call get_ltp with security_id=13, exchange_segment='IDX_I'"
          }

          instruction = next_tool_instructions[tools_called_count] || "Complete the workflow by calling the remaining tools"

          conversation << {
            role: "user",
            content: "You described calling a tool but did not actually call it. You MUST use the tool calling function, not describe it. #{instruction}. Use the tool calling format, not text description."
          }
          next  # Retry the loop
        end

        # STRICT CHECK: Must complete all 5 steps before final response (only for analysis queries)
        if tools_called_count < 5 && !is_simple_query
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
      /result from find_instrument/i,
      /use security_id from step/i,
      /according to the data.*step/i
    ]

    # Also check for markdown code blocks or formatted text that looks like descriptions
    has_code_blocks = content.include?("```") || content.match?(/```json|```ruby|```python/i)
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

