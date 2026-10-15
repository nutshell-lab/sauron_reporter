defmodule SauronReporter.JournalFormatter do
  @moduledoc """
  One journal entry per log event, with its severity — the fleet's log
  contract (infra `docs/logs.md`).

  Under systemd, what a release prints becomes journal entries: one per
  line, all at priority 6 (info) unless the line starts with `<N>` —
  then systemd sets that priority and drops the prefix. So an `[error]`
  was stored as info, invisible to Sauron's error views (`PRIORITY <= 3`),
  and a stack trace became one entry per frame.

  This formatter wraps Elixir's own (`Logger.Formatter`, same options):
  each event comes out as one line, its own line breaks written `\\n`,
  after the `<N>` of its level. Use it only when the output is the
  journal — `JOURNAL_STREAM` is set then, not in a terminal or a test:

      # config/runtime.exs
      if System.get_env("JOURNAL_STREAM") do
        config :logger, :default_handler,
          formatter:
            SauronReporter.JournalFormatter.new(
              format: "$metadata[$level] $message\\n",
              metadata: [:request_id]
            )
      end

  The journal stamps each entry with its own time: a `$time` in the
  format is printed, not needed.
  """

  @levels %{
    emergency: 0,
    alert: 1,
    critical: 2,
    error: 3,
    warning: 4,
    notice: 5,
    info: 6,
    debug: 7
  }

  @doc "A `:logger` formatter: `{#{inspect(__MODULE__)}, config}`, options as `Logger.Formatter.new/1`."
  def new(options \\ []) do
    {__MODULE__, %{inner: Logger.Formatter.new(options)}}
  end

  @doc false
  def check_config(%{inner: {module, config}}) do
    if function_exported?(module, :check_config, 1), do: module.check_config(config), else: :ok
  end

  def check_config(other), do: {:error, {:invalid_formatter_config, __MODULE__, other}}

  @doc false
  def format(%{level: level} = event, %{inner: {module, config}}) do
    line =
      event
      |> module.format(config)
      |> IO.chardata_to_string()
      |> String.trim_trailing("\n")
      |> String.replace(~r/\r?\n/, "\\n")

    ["<", Integer.to_string(Map.get(@levels, level, 6)), ">", line, "\n"]
  end
end
