class Fixnum
  def seconds
    self
  end
  alias_method :second, :seconds

  def minutes
    seconds * 60
  end
  alias_method :minute, :minutes

  def hours
    minutes * 60
  end
  alias_method :hour, :hours

  def days
    hours * 24
  end
  alias_method :day, :days

  def weeks
    days * 7
  end
  alias_method :week, :weeks

  def months
    days * 30
  end
  alias_method :month, :months

  def years
    days * 365
  end
  alias_method :year, :years
end
