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

# Support (0.8.0): the app's PubSub, and a fake Sauron serving the support
# socket and files API on a free port.
Application.put_env(:sauron_reporter, SauronReporter.FakeSauron.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 0],
  server: true,
  secret_key_base: String.duplicate("f", 64),
  pubsub_server: SauronReporter.FakeSauron.PubSub
)

{:ok, _} =
  Supervisor.start_link(
    [
      Supervisor.child_spec({Phoenix.PubSub, name: SauronReporter.TestPubSub}, id: :app_pubsub),
      Supervisor.child_spec({Phoenix.PubSub, name: SauronReporter.FakeSauron.PubSub},
        id: :sauron_pubsub
      ),
      SauronReporter.FakeSauron,
      SauronReporter.FakeSauron.Endpoint
    ],
    strategy: :one_for_one
  )

defmodule SauronReporter.SupportCase do
  @moduledoc """
  Support enabled against the fake Sauron, the client restarted on it
  and joined; restored (and idle again) after. The library's
  application config is global: not async.
  """

  use ExUnit.CaseTemplate

  alias SauronReporter.FakeSauron

  using do
    quote do
      import SauronReporter.SupportCase
      alias SauronReporter.{FakeSauron, Support}
    end
  end

  setup do
    previous = Application.get_all_env(:sauron_reporter)
    FakeSauron.reset(self())
    FakeSauron.accept(true)

    Application.put_env(:sauron_reporter, :app, FakeSauron.app())
    Application.put_env(:sauron_reporter, :url, FakeSauron.url())
    Application.put_env(:sauron_reporter, :token, FakeSauron.token())

    Application.put_env(:sauron_reporter, :support,
      enabled: true,
      pubsub: SauronReporter.TestPubSub,
      reconnect_after_msec: [20, 50, 100],
      rejoin_after_msec: [20, 50, 100],
      call_timeout: 2_000,
      buffer_ttl: 5_000,
      resume_window: 20
    )

    restart_client()
    await_status(:joined)

    on_exit(fn ->
      for {k, _} <- Application.get_all_env(:sauron_reporter),
          do: Application.delete_env(:sauron_reporter, k)

      for {k, v} <- previous, do: Application.put_env(:sauron_reporter, k, v)
      FakeSauron.accept(true)
      restart_client()
    end)
  end

  @doc "The client restarted, reading the configuration again."
  def restart_client do
    :ok = Supervisor.terminate_child(SauronReporter.Supervisor, SauronReporter.Support.Client)
    {:ok, _} = Supervisor.restart_child(SauronReporter.Supervisor, SauronReporter.Support.Client)
  end

  @doc "Waits until the client's link is `status`."
  def await_status(status, tries \\ 100) do
    cond do
      SauronReporter.Support.status().status == status ->
        :ok

      tries == 0 ->
        flunk(
          "the support client never became #{status}: #{inspect(SauronReporter.Support.status())}"
        )

      true ->
        Process.sleep(20)
        await_status(status, tries - 1)
    end
  end

  @doc "Waits until `fun` returns a truthy value, and returns it."
  def eventually(fun, tries \\ 100) do
    case fun.() do
      result when result in [nil, false] ->
        if tries == 0, do: flunk("never happened")
        Process.sleep(20)
        eventually(fun, tries - 1)

      result ->
        result
    end
  end
end
