require_relative "../lib/logger"
require "date"
require "json"

class TradingAgent
  def initialize(llm:, planner_router:)
    @llm = llm
    @planner_router = planner_router
    @logger = AgentLogger.init
  end

  def run(user_query:, account_context:)
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
              from_date: { type: "string", description: "Start date in YYYY-MM-DD format" },
              to_date: { type: "string", description: "End date in YYYY-MM-DD format" }
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
              from_date: { type: "string", description: "Start date in YYYY-MM-DD format" },
              to_date: { type: "string", description: "End date in YYYY-MM-DD format" },
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

    system_prompt = <<~PROMPT
      You are a trading analysis agent. You MUST use the available tools to get real market data.

      ⚠️ STRICT ANTI-HALLUCINATION RULES ⚠️

      FORBIDDEN - DO NOT DO THESE:
      ❌ NEVER use placeholders like [Current Price], [Today's Date], [Strike Price], [RSI Value], [MA Values]
      ❌ NEVER make up or estimate market data (prices, volumes, indicators, ratios)
      ❌ NEVER use generic statements like "approximately" or "around" without real data
      ❌ NEVER provide analysis without calling tools first
      ❌ NEVER return a response that contains placeholder brackets [ ] or generic values
      ❌ NEVER calculate indicators (RSI, Bollinger Bands, etc.) without real OHLCV data
      ❌ NEVER assume or guess market conditions

      REQUIRED - YOU MUST DO THESE:
      ✅ ALWAYS call tools in this exact order: find_instrument → get_daily_ohlcv → get_intraday_ohlcv → get_option_chain → get_ltp
      ✅ ALWAYS use real data from tool responses - quote exact numbers from tool results
      ✅ ALWAYS state "Data not available" if a tool returns empty/null results
      ✅ ALWAYS use actual dates in YYYY-MM-DD format (today is #{Date.today.strftime('%Y-%m-%d')})
      ✅ ALWAYS wait for tool responses before making any analysis
      ✅ ALWAYS cite the source: "According to the data from [tool_name]..."

      WORKFLOW (MANDATORY - COMPLETE ALL 5 STEPS):
      Step 1: Call find_instrument(symbol="NIFTY", segment="IDX_I") - WAIT for result
      Step 2: Use security_id from Step 1 → Call get_daily_ohlcv(security_id, exchange_segment, from_date, to_date) - WAIT for result
      Step 3: Use security_id from Step 1 → Call get_intraday_ohlcv(security_id, exchange_segment, from_date, to_date) - WAIT for result
      Step 4: Use security_id from Step 1 → Call get_option_chain(security_id, exchange_segment) - WAIT for result
      Step 5: Use security_id from Step 1 → Call get_ltp(security_id, exchange_segment) - WAIT for result
      Step 6: ONLY AFTER completing ALL 5 steps → Provide analysis with exact numbers from tool results

      CRITICAL: You MUST complete ALL 5 tool calls (O1→O5) before providing final analysis.
      - If a tool returns empty data, note it and CONTINUE to the next tool
      - Do NOT stop early if one tool returns empty data
      - You must call all 5 tools: find_instrument, get_daily_ohlcv, get_intraday_ohlcv, get_option_chain, get_ltp
      - Only after calling all 5 tools can you provide the final analysis

      DATA AVAILABILITY:
      - If a tool returns empty data or error, state: "Data not available from [tool_name]"
      - If required data is missing, say: "Cannot provide recommendation - required data unavailable"
      - NEVER fill in missing data with estimates or assumptions

      RESPONSE VALIDATION:
      Before returning your final response, verify:
      1. All numbers come from tool responses (not invented)
      2. No placeholder text like [anything] exists
      3. All dates are in YYYY-MM-DD format
      4. All prices/values are exact numbers from tools

      REMEMBER: It's better to say "Data not available" than to hallucinate or estimate.
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
        @logger.info("AGENT: Final content: #{response[:content][0..100]}...")
        
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
        
        # Check if LLM is describing actions instead of calling tools
        if describes_tool_usage?(response[:content]) && tools_called_count < 5
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
        
        # STRICT CHECK: Must complete all 5 steps before final response
        if tools_called_count < 5
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
        @logger.debug("AGENT: Tool result: #{result.inspect[0..200]}...")

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
      /call\s+(get_|find_)/i,
      /step\s+\d+.*call/i,
      /proceed with calling/i,
      /now.*call/i,
      /let's.*call/i,
      /should call/i,
      /need to call/i
    ]
    
    description_patterns.any? { |pattern| content.match?(pattern) }
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

