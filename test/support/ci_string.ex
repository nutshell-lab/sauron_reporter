defmodule SauronReporter.Test.CiString do
  # Ash.CiString's shape: an email that is not a string, but to_string-able.
  defstruct [:value]

  defimpl String.Chars do
    def to_string(%{value: value}), do: value
  end
end
