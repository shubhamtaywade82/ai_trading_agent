# AI Trading Agent

A production-ready Ruby trading agent that combines LLM reasoning (via Ollama) with real-time market data (via DhanHQ) to analyze and execute trading strategies. The agent uses a strict planner-based architecture with tool calling to ensure deterministic, step-by-step execution.

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Trading Agent                            │
│                                                              │
│  ┌──────────────┐      ┌──────────────┐                    │
│  │ Ollama Client │◄────►│ Agent Loop  │                    │
│  │ (LLM)        │      │ (Orchestrator)│                    │
│  └──────────────┘      └──────┬───────┘                    │
│                                │                             │
│                                ▼                             │
│                       ┌──────────────┐                       │
│                       │ Planner Router│                      │
│                       │ (Gatekeeper)  │                       │
│                       └──────┬───────┘                       │
│                                │                             │
│                                ▼                             │
│                       ┌──────────────┐                       │
│                       │ Tool Guard   │                       │
│                       │ (Validator)  │                       │
│                       └──────┬───────┘                       │
│                                │                             │
│                                ▼                             │
│                       ┌──────────────┐                       │
│                       │ Tool Executor│                       │
│                       └──────┬───────┘                       │
│                                │                             │
│        ┌──────────────────────┼──────────────────────┐      │
│        │                      │                      │      │
│        ▼                      ▼                      ▼      │
│  ┌──────────┐         ┌──────────┐          ┌──────────┐   │
│  │ Tools    │         │ Tools    │          │ Tools    │   │
│  │ (DhanHQ) │         │ (DhanHQ) │          │ (DhanHQ)  │   │
│  └──────────┘         └──────────┘          └──────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Key Components

1. **TradingAgent** - Main orchestration loop that manages LLM ↔ Tools interaction
2. **OllamaClient** - Wrapper around Ollama for LLM tool calling
3. **PlannerRouter** - Enforces strict step-by-step execution flow
4. **OptionsBuyingPlanner** - Implements O1→O5 flow for options trading
5. **ToolGuard** - Validates tool calls against current planner step
6. **ToolExecutor** - Routes tool calls to appropriate DhanHQ operations
7. **DhanClient** - Wrapper around DhanHQ gem for market data access

## 📋 Prerequisites

- Ruby 3.0+ (recommended: 3.1+)
- Bundler
- Ollama installed and running locally (default: `http://localhost:11434`)
- DhanHQ account with API credentials

## 🚀 Installation

### 1. Clone and Setup

```bash
cd ai_trading_agent
bundle install
```

### 2. Configure Ollama

Ensure Ollama is running with a model that supports tool calling:

```bash
# Install a recommended model for trading
ollama pull nemesis-options-analyst:latest  # Specialized for options analysis
# OR
ollama pull llama3.1:8b                     # General purpose
# OR
ollama pull qwen2.5-coder:7b                # Coding focused

# Verify Ollama is running
curl http://localhost:11434/api/tags
```

**Recommended Models:**
- `nemesis-options-analyst:latest` - Specialized for options trading analysis (recommended)
- `nemesis-coder:latest` - General purpose coding
- `llama3.1:8b` - General purpose, good tool calling support
- `qwen2.5-coder:7b` - Coding focused with good reasoning
- `deepseek-coder:6.7b` - Strong coding capabilities

### 3. Configure DhanHQ

Create a `.env` file from the template:

```bash
cp .env.example .env
```

Edit `.env` with your DhanHQ credentials:

```bash
CLIENT_ID=your_dhan_client_id
ACCESS_TOKEN=your_dhan_access_token
DHAN_LOG_LEVEL=INFO
```

**Note:** The `.env` file is automatically loaded by `dotenv` when you run `main.rb`. The `.env` file is gitignored for security.

**Alternative:** You can also set environment variables directly:

```bash
export CLIENT_ID="your_dhan_client_id"
export ACCESS_TOKEN="your_dhan_access_token"
export DHAN_LOG_LEVEL="INFO"
```

## 📖 Usage

### Basic Usage

```bash
ruby main.rb
```

This runs the agent with a default query: "Can I buy NIFTY CE today?"

### Custom Query

Edit `main.rb` to change the query:

```ruby
result = agent.run(
  user_query: "Analyze NIFTY 50 options for today and suggest a call option",
  account_context: {
    capital: 500_000,
    max_risk_per_trade: 0.5,
    dhan_client: dhan_client
  }
)
```

### Programmatic Usage

```ruby
require_relative "llm/ollama_client"
require_relative "agent/trading_agent"
require_relative "planner/planner_router"
require_relative "dhan/client"

# Initialize components
dhan_client = DhanClient.new
llm = TradingOllamaClient.new(model: "llama3.1", url: "http://localhost:11434")
planner = PlannerRouter.new

# Create agent
agent = TradingAgent.new(llm: llm, planner_router: planner)

# Run query
result = agent.run(
  user_query: "Can I buy NIFTY CE today?",
  account_context: {
    capital: 500_000,
    max_risk_per_trade: 0.5,
    dhan_client: dhan_client
  }
)

puts result
```

## 🔧 Configuration

### Ollama Configuration

Configure via `.env` file (recommended):

```bash
OLLAMA_MODEL=nemesis-options-analyst:latest
OLLAMA_URL=http://localhost:11434
```

Or pass directly when initializing:

```ruby
llm = TradingOllamaClient.new(
  model: "nemesis-options-analyst:latest",  # Model name
  url: "http://localhost:11434"             # Ollama server URL
)
```

**Available Models:**
- `nemesis-options-analyst:latest` - Best for options trading (default, recommended)
- `nemesis-coder:latest` - General coding
- `llama3.1:8b` - General purpose
- `llama3.2:3b` - Smaller, faster
- `qwen2.5-coder:7b` - Coding focused
- `deepseek-coder:6.7b` - Strong coding
- `mistral:7b-instruct` - Good instruction following
- `codellama:7b-instruct` - Code generation

### DhanHQ Configuration

The DhanHQ client automatically reads from environment variables. Optional overrides:

```bash
export DHAN_BASE_URL="https://api.dhan.co"  # API base URL
export DHAN_WS_VERSION="1"                   # WebSocket version
export DHAN_LOG_LEVEL="DEBUG"                # Logging level
```

### Planner Configuration

The `OptionsBuyingPlanner` enforces a strict 5-step flow:

- **O1**: Find instrument (`find_instrument`)
- **O2**: Get daily OHLCV (`get_daily_ohlcv`)
- **O3**: Get intraday OHLCV (`get_intraday_ohlcv`)
- **O4**: Get option chain (`get_option_chain`)
- **O5**: Get LTP (`get_ltp`)

Each step must complete before the next can begin. The planner will halt if tools are called out of order.

## 🛠️ Available Tools

### 1. `find_instrument`

Searches for an instrument by symbol and exchange segment.

**Parameters:**
- `symbol` (string) - Trading symbol (e.g., "NIFTY", "RELIANCE")
- `segment` (string) - Exchange segment (e.g., "IDX_I", "NSE_EQ", "NSE_FNO")

**Returns:**
```ruby
{
  security_id: "13",
  exchange_segment: "IDX_I",
  instrument_type: "INDEX",
  trading_symbol: "NIFTY"
}
```

**Example:**
```ruby
FindInstrument.call(
  symbol: "NIFTY",
  segment: "IDX_I",
  dhan_client: dhan_client
)
```

### 2. `get_daily_ohlcv`

Fetches daily OHLCV (Open, High, Low, Close, Volume) data.

**Parameters:**
- `security_id` (string) - Security identifier
- `exchange_segment` (string) - Exchange segment
- `from_date` (string) - Start date (YYYY-MM-DD)
- `to_date` (string) - End date (YYYY-MM-DD)

**Returns:**
```ruby
[
  {
    date: "2024-01-15",
    open: 22000.0,
    high: 22100.0,
    low: 21950.0,
    close: 22050.0,
    volume: 1000000
  },
  # ... more days
]
```

### 3. `get_intraday_ohlcv`

Fetches intraday OHLCV data at specified intervals.

**Parameters:**
- `security_id` (string) - Security identifier
- `exchange_segment` (string) - Exchange segment
- `from_date` (string) - Start date (YYYY-MM-DD)
- `to_date` (string) - End date (YYYY-MM-DD)
- `interval` (string, optional) - Interval in minutes: "1", "5", "15", "30", "60" (default: "5")

**Returns:**
```ruby
[
  {
    timestamp: "2024-01-15 09:15:00",
    open: 22000.0,
    high: 22050.0,
    low: 21980.0,
    close: 22020.0,
    volume: 50000
  },
  # ... more candles
]
```

### 4. `get_option_chain`

Fetches option chain data for a given underlying.

**Parameters:**
- `security_id` (string) - Underlying security identifier
- `exchange_segment` (string) - Exchange segment
- `expiry` (string, optional) - Expiry date (YYYY-MM-DD). If not provided, uses nearest expiry.

**Returns:**
```ruby
{
  atm: 22500,
  ce: [22500, 22600, 22700],  # Call option strikes
  pe: [22400, 22300, 22200],  # Put option strikes
  expiry_dates: ["2024-01-25", "2024-02-29"],
  strikes: [22000, 22100, 22200, ...]
}
```

### 5. `get_ltp`

Fetches Last Traded Price (LTP) for an instrument.

**Parameters:**
- `security_id` (string) - Security identifier
- `exchange_segment` (string) - Exchange segment

**Returns:**
```ruby
{
  ltp: 22050.0,
  ltt: "2024-01-15 15:30:00",  # Last traded time
  security_id: "13",
  exchange_segment: "IDX_I"
}
```

## 🔄 Planner Flow

The `OptionsBuyingPlanner` enforces a strict sequential flow:

```
O1: find_instrument
  ↓
O2: get_daily_ohlcv
  ↓
O3: get_intraday_ohlcv
  ↓
O4: get_option_chain
  ↓
O5: get_ltp
  ↓
DONE
```

**Key Rules:**
- Each step must complete before the next can begin
- Tools can only be called in the correct order
- Attempting to call a tool out of order raises `PlannerHalt`
- The planner advances automatically after each tool execution

## 📝 Example Workflow

### Example 1: Analyze NIFTY Options

```ruby
agent.run(
  user_query: "Can I buy NIFTY CE today?",
  account_context: {
    capital: 500_000,
    max_risk_per_trade: 0.5,
    dhan_client: dhan_client
  }
)
```

**What happens:**
1. LLM receives query and decides to call `find_instrument` for "NIFTY"
2. Planner validates: O1 allows `find_instrument` ✅
3. Tool executes: Returns NIFTY instrument details
4. Planner advances to O2
5. LLM calls `get_daily_ohlcv` for historical context
6. Process continues through O3, O4, O5
7. LLM analyzes all data and returns final recommendation

### Example 2: Custom Analysis

```ruby
agent.run(
  user_query: "Analyze RELIANCE stock for intraday trading. Get last 5 days of data and current LTP.",
  account_context: {
    capital: 100_000,
    max_risk_per_trade: 0.3,
    dhan_client: dhan_client
  }
)
```

## 🏛️ Directory Structure

```
ai_trading_agent/
├── Gemfile                 # Dependencies
├── main.rb                 # Entry point
├── README.md              # This file
├── agent/
│   └── trading_agent.rb   # Main agent loop
├── planner/
│   ├── base_planner.rb    # Base planner with halt mechanism
│   ├── options_buying_planner.rb  # O1→O5 flow
│   └── planner_router.rb  # Gatekeeper router
├── tools/
│   ├── tool_guard.rb      # Tool validation
│   ├── tool_executor.rb   # Tool router
│   ├── find_instrument.rb
│   ├── get_daily_ohlcv.rb
│   ├── get_intraday_ohlcv.rb
│   ├── get_option_chain.rb
│   └── get_ltp.rb
├── llm/
│   └── ollama_client.rb   # Ollama wrapper
└── dhan/
    └── client.rb          # DhanHQ wrapper
```

## 🐛 Troubleshooting

### Ollama Connection Issues

**Error:** `Connection refused` or `Model not found`

**Solutions:**
1. Verify Ollama is running: `curl http://localhost:11434/api/tags`
2. Check model is installed: `ollama list`
3. Install model if missing: `ollama pull llama3.1`
4. Update URL in `TradingOllamaClient.new(url: "...")` if using remote server

### DhanHQ Authentication Issues

**Error:** `CLIENT_ID` or `ACCESS_TOKEN` missing

**Solutions:**
1. Ensure `.env` file exists: `cp .env.example .env` and edit with your credentials
2. Verify environment variables are set: `echo $CLIENT_ID`
3. Check `.env` file is in the project root directory
4. Verify `.env` file format (no quotes needed, no spaces around `=`)
5. Verify credentials in DhanHQ console
6. Check `DHAN_LOG_LEVEL=DEBUG` for detailed error messages
7. If using environment variables directly, ensure they're exported before running

### Planner Halt Errors

**Error:** `Tool X not allowed at step Y`

**Solutions:**
1. This is expected behavior - tools must be called in order
2. Check LLM is following the correct flow
3. Verify planner step sequence: O1 → O2 → O3 → O4 → O5
4. Review tool call sequence in logs

### Tool Execution Errors

**Error:** `Instrument not found` or API errors

**Solutions:**
1. Verify symbol and segment are correct
2. Check DhanHQ API status
3. Review `DHAN_LOG_LEVEL=DEBUG` output
4. Ensure market is open (for real-time data)
5. Check date formats (YYYY-MM-DD)

### Bundle Install Issues

**Error:** `Could not find gem`

**Solutions:**
1. Both gems are from GitHub, not RubyGems
2. Ensure git is installed: `git --version`
3. Check network connectivity
4. Try: `bundle update`

## 🔒 Security Best Practices

1. **Never commit credentials:**
   - The `.env` file is already in `.gitignore` (automatically excluded)
   - Only commit `.env.example` as a template
   - Use environment variables or secrets management for production
   - Rotate access tokens regularly
   - Never share `.env` files or commit them to version control

2. **Validate inputs:**
   - The `ToolGuard` validates tool calls
   - Planner enforces step sequence
   - DhanHQ client validates API parameters

3. **Error handling:**
   - All tools have error handling
   - Planner halts on invalid operations
   - Logs are sanitized (no tokens in logs)

## 🧪 Testing

### Manual Testing

```ruby
# Test individual tools
require_relative "dhan/client"

dhan_client = DhanClient.new

# Test find_instrument
result = dhan_client.find_instrument(symbol: "NIFTY", segment: "IDX_I")
puts result

# Test get_ltp
ltp = dhan_client.get_ltp(security_id: "13", exchange_segment: "IDX_I")
puts ltp
```

### Integration Testing

```ruby
# Test full agent flow
require_relative "main"

# Run with test query
# Modify main.rb temporarily for testing
```

## 📚 Additional Resources

- [Ollama Documentation](https://ollama.ai/docs)
- [DhanHQ API Documentation](https://dhan.co/api-docs)
- [DhanHQ Ruby Client](https://github.com/shubhamtaywade82/dhanhq-client)
- [Ollama Ruby Client](https://github.com/shubhamtaywade82/ollama-client)

## 🤝 Contributing

This is a production-ready skeleton. To extend:

1. **Add new planners:** Create classes inheriting from `BasePlanner`
2. **Add new tools:** Create tool classes in `tools/` and register in `ToolExecutor`
3. **Customize agent:** Modify `TradingAgent` for different conversation patterns
4. **Add validations:** Extend `ToolGuard` for additional checks

## 📄 License

MIT License - See LICENSE file for details

## ⚠️ Disclaimer

This software is for educational and research purposes. Trading involves risk. Always:
- Test thoroughly in paper trading mode
- Understand the risks involved
- Comply with local regulations
- Never trade with money you cannot afford to lose
- Consult with financial advisors before live trading

---

**Built with:** Ruby, Ollama, DhanHQ API

**Architecture:** Planner-based agent with strict tool calling validation

