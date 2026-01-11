# How Tool Responses Are Stored and Accessed

## Overview

The agent uses a **conversation array** that maintains the entire conversation history, including all tool calls and their results. This conversation is sent to the LLM on each iteration, allowing the LLM to see all previous tool results and use them for subsequent tool calls.

## 1. Conversation Array Structure

The conversation is initialized as an array of message hashes:

```ruby
conversation = [
  {
    role: "system",
    content: system_prompt  # Instructions for the LLM
  },
  {
    role: "user",
    content: user_query  # User's initial query
  }
]
```

## 2. How Tool Results Are Stored

When a tool is executed, its result is added to the conversation array with `role: "tool"`:

```ruby
# After tool execution (line 465-469 in trading_agent.rb)
conversation << {
  role: "tool",
  name: tool_call["name"],  # e.g., "find_instrument"
  content: tool_content     # JSON string of the tool result
}
```

### Example Conversation After Tool Calls

```ruby
conversation = [
  { role: "system", content: "..." },
  { role: "user", content: "Get OHLCV data for NIFTY" },
  {
    role: "tool",
    name: "find_instrument",
    content: '{"security_id":"13","exchange_segment":"IDX_I","instrument_type":"INDEX","trading_symbol":"NIFTY"}'
  },
  {
    role: "tool",
    name: "get_daily_ohlcv",
    content: '[{"date":"2025-12-15","open":25930.05,"high":26047.15,...}]'
  }
]
```

## 3. How the LLM Accesses Tool Results

### On Each Iteration

1. **The entire conversation array is sent to the LLM** (line 231):
   ```ruby
   response = @llm.chat(conversation, tools: tools)
   ```

2. **The LLM receives the full conversation history**, including:
   - System prompt
   - User query
   - All previous tool calls and their results
   - Any error messages or instructions

3. **The LLM can read previous tool results** from the conversation and use actual values (like `security_id: "13"`) in subsequent tool calls.

### Example: LLM Using Previous Tool Result

```
Iteration 1:
- LLM calls: find_instrument(symbol="NIFTY", segment="IDX_I")
- Tool returns: {"security_id": "13", "exchange_segment": "IDX_I", ...}
- Added to conversation as: {role: "tool", name: "find_instrument", content: "..."}

Iteration 2:
- LLM receives full conversation (including tool result from iteration 1)
- LLM reads security_id="13" from previous tool result
- LLM calls: get_daily_ohlcv(security_id="13", exchange_segment="IDX_I", ...)
```

## 4. How the Agent Accesses Tool Results

The agent accesses tool results from the conversation array for validation and control flow:

### A. Checking if a Tool Was Called

```ruby
# Line 263: Check if find_instrument was called
find_instrument_called = conversation.any? { |msg|
  msg[:role] == "tool" && msg[:name] == "find_instrument"
}
```

### B. Extracting Values from Tool Results

```ruby
# Line 290-297: Extract security_id from find_instrument result
find_result = conversation.find { |msg|
  msg[:role] == "tool" && msg[:name] == "find_instrument"
}

if find_result && find_result[:content]
  find_data = JSON.parse(find_result[:content])
  security_id = find_data["security_id"] || find_data[:security_id] || "13"
end
```

### C. Checking Multiple Tool Calls

```ruby
# Line 275-277: Check which OHLCV tools were called
find_instrument_called = conversation.any? { |msg|
  msg[:role] == "tool" && msg[:name] == "find_instrument"
}
daily_ohlcv_called = conversation.any? { |msg|
  msg[:role] == "tool" && msg[:name] == "get_daily_ohlcv"
}
intraday_ohlcv_called = conversation.any? { |msg|
  msg[:role] == "tool" && msg[:name] == "get_intraday_ohlcv"
}
```

## 5. Complete Flow Example

### Step-by-Step Execution

```
1. INITIALIZATION
   conversation = [
     {role: "system", content: "..."},
     {role: "user", content: "Get OHLCV data for NIFTY"}
   ]

2. ITERATION 1
   - Agent sends conversation to LLM
   - LLM calls: find_instrument(symbol="NIFTY", segment="IDX_I")
   - Tool executes and returns: {security_id: "13", ...}
   - Agent adds to conversation:
     conversation << {
       role: "tool",
       name: "find_instrument",
       content: '{"security_id":"13","exchange_segment":"IDX_I",...}'
     }

3. ITERATION 2
   - Agent sends updated conversation to LLM (now has 3 messages)
   - LLM reads previous tool result and sees security_id="13"
   - LLM calls: get_daily_ohlcv(security_id="13", exchange_segment="IDX_I", ...)
   - Tool executes and returns: [{date: "...", open: ..., ...}]
   - Agent adds to conversation:
     conversation << {
       role: "tool",
       name: "get_daily_ohlcv",
       content: '[{"date":"2025-12-15","open":25930.05,...}]'
     }

4. ITERATION 3
   - Agent sends updated conversation to LLM (now has 4 messages)
   - LLM can see all previous results
   - LLM provides final response using data from tool results
```

## 6. Key Points

### ✅ What Works Well

1. **Full History**: LLM sees entire conversation, including all tool results
2. **Sequential Access**: Each iteration builds on previous results
3. **JSON Format**: Tool results are stored as JSON strings, easy to parse
4. **Agent Control**: Agent can check conversation state for validation

### ⚠️ Important Notes

1. **Tool results are JSON strings**: The `content` field is a JSON string, not a Ruby object
2. **LLM must parse**: The LLM needs to read and parse the JSON from previous tool results
3. **Sequential execution**: Tools are called one at a time, results added sequentially
4. **No direct access**: The agent doesn't automatically extract values - the LLM must read them

### 🔍 Validation Mechanisms

The agent validates that:
- LLM doesn't use placeholders like `<security_id>` (line 439)
- LLM doesn't call multiple tools at once (line 390)
- LLM uses actual values from previous tool results (line 445)

## 7. Code Locations

- **Conversation initialization**: `agent/trading_agent.rb:203-212`
- **Tool result storage**: `agent/trading_agent.rb:465-469`
- **Sending to LLM**: `agent/trading_agent.rb:231`
- **Agent accessing results**: `agent/trading_agent.rb:263, 275-277, 290-297`
- **LLM receiving conversation**: `llm/ollama_client.rb:49` (messages array)

## 8. Example: Extracting security_id

If you need to extract a value from a previous tool result in the agent code:

```ruby
# Find the find_instrument result
find_result = conversation.find { |msg|
  msg[:role] == "tool" && msg[:name] == "find_instrument"
}

if find_result && find_result[:content]
  begin
    # Parse the JSON string
    find_data = JSON.parse(find_result[:content])

    # Extract security_id
    security_id = find_data["security_id"] || find_data[:security_id]

    # Use it
    puts "Security ID: #{security_id}"  # => "13"
  rescue JSON::ParserError => e
    @logger.error("Failed to parse tool result: #{e.message}")
  end
end
```

## Summary

- **Storage**: Tool results stored in `conversation` array with `role: "tool"`
- **Format**: Results stored as JSON strings in `content` field
- **Access by LLM**: Full conversation sent on each iteration, LLM reads previous results
- **Access by Agent**: Agent searches conversation array using `find` or `any?`
- **Flow**: Sequential - each tool result becomes available for next iteration

