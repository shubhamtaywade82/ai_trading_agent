class PlannerHalt < StandardError; end

class BasePlanner
  attr_reader :state, :current_step

  def initialize
    @state = {}
    @current_step = nil
  end

  def halt!(reason)
    raise PlannerHalt, reason
  end

  def require!(cond, msg)
    halt!(msg) unless cond
  end
end

