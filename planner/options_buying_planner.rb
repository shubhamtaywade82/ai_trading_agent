require_relative "base_planner"

class OptionsBuyingPlanner < BasePlanner
  def initialize
    super
    @current_step = :O1
  end

  def allow_tool?(tool, allow_intraday_at_o4: false)
    allowed = {
      O1: %w[find_instrument],
      O2: %w[get_daily_ohlcv],
      O3: %w[get_intraday_ohlcv],
      O4: %w[get_option_chain],
      O5: %w[get_ltp]
    }

    # Special case: allow get_intraday_ohlcv at O4 if we're still fetching multiple intervals
    if @current_step == :O4 && tool == "get_intraday_ohlcv" && allow_intraday_at_o4
      return true
    end

    allowed[@current_step]&.include?(tool)
  end

  def advance!
    @current_step = {
      O1: :O2,
      O2: :O3,
      O3: :O4,
      O4: :O5,
      O5: :DONE
    }[@current_step]
  end
end

