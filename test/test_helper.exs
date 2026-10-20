ExUnit.start()

defmodule SauronReporter.AnalyticsCase do
  @moduledoc """
  Analytics enabled, delivering in-process to the test (`{:delivered,
  app, payload}`), the buffer emptied before each test. The library's
  application config is global: not async.
  """

  use ExUnit.CaseTemplate

  alias SauronReporter.Analytics

  using do
    quote do
      import SauronReporter.AnalyticsCase
      alias SauronReporter.Analytics
    end
  end

  setup do
    previous = Application.get_all_env(:sauron_reporter)

    # Whatever an earlier test left waiting is forgotten.
    clear_env()
    Analytics.flush()

    configure_analytics([])

    on_exit(fn ->
      clear_env()
      Analytics.flush()
      for {k, v} <- previous, do: Application.put_env(:sauron_reporter, k, v)
    end)
  end

  defp clear_env do
    for {k, _} <- Application.get_all_env(:sauron_reporter),
        do: Application.delete_env(:sauron_reporter, k)
  end

  @doc "Analytics on, delivering to this process; `extra` merged into `analytics:`."
  def configure_analytics(extra, reporter \\ []) do
    Application.put_env(:sauron_reporter, :app, "m2-app")
    Application.put_env(:sauron_reporter, :url, "http://sauron.test/")
    Application.put_env(:sauron_reporter, :token, "test-report-token-00001")
    Application.put_env(:sauron_reporter, :test_pid, self())

    for {k, v} <- reporter, do: Application.put_env(:sauron_reporter, k, v)

    Application.put_env(
      :sauron_reporter,
      :analytics,
      Keyword.merge(
        [
          enabled: true,
          user_key: "test-user-key",
          deliver: {__MODULE__, :deliver},
          flush_every: 60_000,
          batch_size: 1_000
        ],
        extra
      )
    )
  end

  @doc false
  def deliver(app, payload) do
    send(Application.get_env(:sauron_reporter, :test_pid), {:delivered, app, payload})

    case Application.get_env(:sauron_reporter, :test_reply) do
      nil -> {:ok, %{accepted: length(payload["events"]), dropped: 0}}
      reply -> reply
    end
  end

  @doc "Flushes, and returns the events of the batch delivered."
  def flushed_events do
    Analytics.flush()
    assert_receive {:delivered, "m2-app", %{"events" => events}}
    events
  end
end
