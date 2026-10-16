defmodule SauronReporter.JournalFormatterTest do
  use ExUnit.Case, async: true

  alias SauronReporter.JournalFormatter

  defp format(level, message, options \\ [format: "[$level] $message\n"]) do
    {module, config} = JournalFormatter.new(options)

    %{level: level, msg: {:string, message}, meta: %{time: System.os_time(:microsecond)}}
    |> module.format(config)
    |> IO.chardata_to_string()
  end

  test "the level as <N> before the line systemd reads it from" do
    assert format(:error, "boom") == "<3>[error] boom\n"
    assert format(:warning, "slow") == "<4>[warning] slow\n"
    assert format(:info, "GET /") == "<6>[info] GET /\n"
    assert format(:debug, "x") == "<7>[debug] x\n"
    assert format(:critical, "down") == "<2>[critical] down\n"
  end

  test "an event over several lines stays one line: its breaks written \\n" do
    message =
      "** (KeyError) key :caption not found in:\n    %{url: \"x\"}\r\n    (m2 0.10.11) lib/m2_web.ex:318"

    assert format(:error, message) ==
             "<3>[error] ** (KeyError) key :caption not found in:\\n    %{url: \"x\"}\\n    (m2 0.10.11) lib/m2_web.ex:318\n"
  end

  test "Logger.Formatter's options go through: metadata, format" do
    {module, config} =
      JournalFormatter.new(format: "$metadata[$level] $message\n", metadata: [:request_id])

    line =
      %{
        level: :info,
        msg: {:string, "Sent 200"},
        meta: %{request_id: "GN5Y", time: System.os_time(:microsecond)}
      }
      |> module.format(config)
      |> IO.chardata_to_string()

    assert line == "<6>request_id=GN5Y [info] Sent 200\n"
  end

  test "another formatter wrapped: its line, prefixed, kept on one line" do
    {module, config} = JournalFormatter.new(formatter: {__MODULE__.Json, %{}})

    line =
      %{level: :error, msg: {:string, "boom\nat line 2"}, meta: %{}}
      |> module.format(config)
      |> IO.chardata_to_string()

    assert "<3>" <> json = line

    assert String.ends_with?(json, "}\n") and
             not String.contains?(String.trim_trailing(json), "\n")

    assert Jason.decode!(json) == %{"severity" => "error", "message" => "boom\nat line 2"}
  end

  test "its config checks as :logger asks it to" do
    {module, config} = JournalFormatter.new()
    assert module.check_config(config) == :ok
    assert {:error, _} = module.check_config(:nonsense)
  end

  defmodule Json do
    # A formatter like LoggerJSON's: one JSON object per event, newline-terminated.
    def format(%{level: level, msg: {:string, message}}, _config),
      do: [Jason.encode!(%{severity: level, message: message}), "\n"]
  end
end
