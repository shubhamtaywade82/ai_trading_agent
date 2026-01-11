require_relative "base_planner"

class OptionsBuyingPlanner < BasePlanner
  def initialize
    super
    @current_step = :O1
  end

  def allow_tool?(tool)
    allowed = {
      O1: %w[find_instrument],
      O2: %w[get_daily_ohlcv],
      O3: %w[get_intraday_ohlcv],
      O4: %w[get_option_chain],
      O5: %w[get_ltp]
    }

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

