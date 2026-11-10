defmodule SauronReporter.AnalyticsUnitsTest.Page do
  @behaviour Plug
  import Plug.Conn

  alias SauronReporter.AnalyticsUnitsTest

  def init(opts), do: opts

  # The schedule: one heavy statement, and an N+1 of twelve.
  def call(conn, :schedule) do
    AnalyticsUnitsTest.query(
      "SELECT s0.id FROM stages AS s0 WHERE (s0.competition_id = $1)",
      120,
      30
    )

    for _ <- 1..12,
        do: AnalyticsUnitsTest.query("SELECT h0.id FROM heats AS h0 WHERE (h0.stage_id = $1)", 2)

    conn |> put_resp_content_type("text/html") |> send_resp(200, "<p>")
  end

  # A query from a task the request awaits counts for the request.
  def call(conn, :task) do
    Task.async(fn -> AnalyticsUnitsTest.query("SELECT 1", 5) end) |> Task.await()
    send_resp(conn, 200, "ok")
  end
end

defmodule SauronReporter.AnalyticsUnitsTest.Live do
  use Phoenix.LiveView

  alias SauronReporter.AnalyticsUnitsTest

  def mount(_params, _session, socket) do
    if connected?(socket), do: AnalyticsUnitsTest.query("SELECT c0.id FROM competitions AS c0", 4)
    {:ok, socket}
  end

  def handle_params(_params, _url, socket), do: {:noreply, socket}

  def handle_event("reload", _params, socket) do
    AnalyticsUnitsTest.query("SELECT h0.id FROM heats AS h0", 7, 3)
    {:noreply, socket}
  end

  def render(assigns), do: ~H"<p>schedule</p>"
end

defmodule SauronReporter.AnalyticsUnitsTest.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
  end

  get("/competitions/:id/schedule", SauronReporter.AnalyticsUnitsTest.Page, :schedule)
  get("/task", SauronReporter.AnalyticsUnitsTest.Page, :task)

  scope "/" do
    pipe_through(:browser)

    live_session :public, on_mount: [SauronReporter.Analytics.Hook] do
      live("/schedule/:id", SauronReporter.AnalyticsUnitsTest.Live)
    end
  end
end

defmodule SauronReporter.AnalyticsUnitsTest.Endpoint do
  use Phoenix.Endpoint, otp_app: :sauron_reporter

  @session_options [store: :cookie, key: "_units_test", signing_salt: "unitstest"]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :user_agent, :x_headers, session: @session_options]]
  )

  plug(Plug.Session, @session_options)
  plug(SauronReporter.AnalyticsUnitsTest.Router)
end

defmodule SauronReporter.AnalyticsUnitsTest do
  use SauronReporter.AnalyticsCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SauronReporter.Analytics.Units
  alias SauronReporter.AnalyticsUnitsTest.Router

  @endpoint SauronReporter.AnalyticsUnitsTest.Endpoint
  @prefix [:units_test, :repo]
  @browser "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Safari/605.1.15"

  setup_all do
    Application.put_env(:sauron_reporter, @endpoint,
      secret_key_base: String.duplicate("u", 64),
      live_view: [signing_salt: "units-test-salt"],
      server: false
    )

    start_supervised!(@endpoint)
    :ok
  end

  setup do
    on_exit(&Units.detach/0)
    :ok
  end

  defp configure(extra \\ []) do
    configure_analytics(Keyword.merge([repos: [@prefix]], extra))
    Units.attach()
  end

  @doc false
  # A query as Ecto reports it: `ms` running, `queue_ms` waiting for a
  # connection, a parameter that must never leave.
  def query(statement, ms, queue_ms \\ 0) do
    native = &System.convert_time_unit(round(&1 * 1_000), :microsecond, :native)

    :telemetry.execute(
      @prefix ++ [:query],
      %{query_time: native.(ms), decode_time: 0, queue_time: native.(queue_ms)},
      %{query: statement, params: ["secret-param"], source: "heats"}
    )
  end

  defp request(path) do
    Plug.Test.conn(:get, "https://wodlane.test" <> path)
    |> Plug.Conn.put_req_header("user-agent", @browser)
    |> SauronReporter.Analytics.Plug.call(SauronReporter.Analytics.Plug.init([]))
    |> Router.call(Router.init([]))
  end

  defp timings(events), do: Enum.filter(events, &(&1["kind"] == "timing"))

  test "a request's timing carries its time in the database, its wait and its queries" do
    configure()
    request("/competitions/7/schedule")

    [timing] = timings(flushed_events())
    assert timing["route"] == "/competitions/:id/schedule"
    assert timing["queries"] == 13
    assert_in_delta timing["db_ms"], 144.0, 0.01
    assert_in_delta timing["db_queue_ms"], 30.0, 0.01
    refute inspect(timing) =~ "secret-param"
  end

  test "without repos, no unit: the timing as before" do
    configure(repos: [])
    request("/competitions/7/schedule")

    [timing] = timings(flushed_events())
    refute Map.has_key?(timing, "db_ms")
    refute Map.has_key?(timing, "queries")
  end

  test "a slow answer writes its slow and repeated statements, never a parameter" do
    configure(slow_ms: 0)
    Logger.metadata(request_id: "F8kTest")

    log = capture_log([level: :info], fn -> request("/competitions/7/schedule") end)
    lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "sauron.slow_statement"))

    # The 120 ms one (over 100 ms), the twelve-times one (10 or more).
    assert length(lines) == 2
    [heavy, repeated] = lines
    assert heavy =~ "count=1 query_ms=120 max_ms=120 queue_ms=30"
    assert heavy =~ ~s(route="/competitions/:id/schedule")
    assert heavy =~ "phase=http"
    assert heavy =~ "request_id=F8kTest"

    assert heavy =~
             ~s(statement="SELECT s0.id FROM stages AS s0 WHERE \(s0.competition_id = $1\)")

    assert repeated =~ "count=12 query_ms=24"
    assert repeated =~ ~r/fingerprint=[0-9a-f]{12}/
    refute log =~ "secret-param"
  end

  test "a quick answer writes nothing" do
    configure()
    log = capture_log([level: :info], fn -> request("/competitions/7/schedule") end)
    refute log =~ "sauron.slow_statement"
  end

  test "a task's queries count for the unit that started it" do
    configure()
    request("/task")

    [timing] = timings(flushed_events())
    assert timing["queries"] == 1
    assert_in_delta timing["db_ms"], 5.0, 0.01
  end

  test "a task outliving its unit is billed to no other" do
    configure()
    test = self()

    Units.start()
    query("SELECT 1", 1)

    task =
      Task.async(fn ->
        query("SELECT 2", 1)
        send(test, :first)

        receive do
          :again -> query("SELECT 3", 50)
        end
      end)

    assert_receive :first
    assert %{queries: 2} = Units.stop()

    Units.start()
    send(task.pid, :again)
    Task.await(task)

    assert %{queries: 0, db_ms: +0.0} = Units.stop()
  end

  test "a unit whose process died is swept" do
    configure()
    test = self()

    pid =
      spawn(fn ->
        Units.start()
        query("SELECT 1", 1)
        send(test, :started)
      end)

    assert_receive :started
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert :ets.member(Units, {:unit, pid})
    Units.sweep()
    refute :ets.member(Units, {:unit, pid})
    assert :ets.match_object(Units, {{:stmt, pid, :_, :_}, :_, :_, :_, :_, :_}) == []
  end

  test "LiveView: the connected mount, handle_params and an event are timed, with their queries" do
    configure(live_timings: true)
    conn = build_conn() |> Plug.Conn.put_req_header("user-agent", @browser)

    {:ok, view, _html} = live(conn, "/schedule/3")
    render_click(view, "reload")

    timings = timings(flushed_events())

    assert [mount] = Enum.filter(timings, &(&1["phase"] == "mount"))
    assert mount["route"] == "/schedule/:id"
    assert mount["queries"] == 1
    assert mount["status"] == 200

    assert [_params] = Enum.filter(timings, &(&1["phase"] == "params"))

    assert [event] = Enum.filter(timings, &(&1["phase"] == "event"))
    assert event["name"] == "reload"
    assert event["path"] == "/schedule/3"
    assert event["queries"] == 1
    assert_in_delta event["db_queue_ms"], 3.0, 0.01

    # The disconnected mount is the HTTP request's: not timed here.
    assert length(Enum.filter(timings, &(&1["phase"] == "mount"))) == 1
  end

  test "LiveView timings stay off unless asked" do
    configure()
    conn = build_conn() |> Plug.Conn.put_req_header("user-agent", @browser)
    {:ok, view, _html} = live(conn, "/schedule/3")
    render_click(view, "reload")

    Analytics.flush()

    events =
      receive do
        {:delivered, _, %{"events" => events}} -> events
      after
        100 -> []
      end

    assert Enum.filter(events, &Map.has_key?(&1, "phase")) == []
  end
end
