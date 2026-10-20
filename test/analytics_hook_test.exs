defmodule SauronReporter.AnalyticsHookTest.Live do
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, socket}
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  def handle_event("signup", _params, socket) do
    SauronReporter.Analytics.track(socket, "signup", %{plan: "pro"})
    {:noreply, socket}
  end

  def render(assigns), do: ~H"<p>page</p>"
end

defmodule SauronReporter.AnalyticsHookTest.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
  end

  scope "/" do
    pipe_through(:browser)

    live_session :public,
      on_mount: [__MODULE__, SauronReporter.Analytics.Hook] do
      live("/pages/:id", SauronReporter.AnalyticsHookTest.Live)
    end

    live_session :connected,
      on_mount: [{SauronReporter.Analytics.Hook, count: :connected}] do
      live("/app/:id", SauronReporter.AnalyticsHookTest.Live)
    end
  end

  # The app's own hook, before ours: who is signed in.
  def on_mount(:default, _params, _session, socket),
    do: {:cont, Phoenix.Component.assign(socket, :sauron_user_id, 5)}
end

defmodule SauronReporter.AnalyticsHookTest.Endpoint do
  use Phoenix.Endpoint, otp_app: :sauron_reporter

  @session_options [store: :cookie, key: "_hook_test", signing_salt: "hooktest"]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :user_agent, :x_headers, session: @session_options]]
  )

  plug(Plug.Session, @session_options)
  plug(SauronReporter.AnalyticsHookTest.Router)
end

defmodule SauronReporter.AnalyticsHookTest do
  use SauronReporter.AnalyticsCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  # LiveView logs each mount and patch at debug.
  @moduletag :capture_log

  @endpoint SauronReporter.AnalyticsHookTest.Endpoint
  @browser "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Mobile/15E148 Safari/604.1"

  setup_all do
    Application.put_env(:sauron_reporter, @endpoint,
      secret_key_base: String.duplicate("s", 64),
      live_view: [signing_salt: "hook-test-salt"],
      server: false
    )

    start_supervised!(@endpoint)
    :ok
  end

  defp browser(ua \\ @browser), do: build_conn() |> Plug.Conn.put_req_header("user-agent", ua)

  defp events do
    Analytics.flush()

    receive do
      {:delivered, "m2-app", %{"events" => events}} -> events
    after
      100 -> []
    end
  end

  test "the first page is the plug's; a patch to another path is a page view" do
    {:ok, view, _html} = live(browser(), "/pages/a")
    assert events() == []

    render_patch(view, "/pages/b?utm_source=newsletter&token=secret")

    assert [
             %{
               "kind" => "page_view",
               "site" => "www.example.com",
               "path" => "/pages/b",
               "route" => "/pages/:id",
               "referrer" => "www.example.com",
               "utm_source" => "newsletter",
               "ip" => "127.0.0.1",
               "ua" => @browser,
               "user" => user
             } = page_view
           ] = events()

    assert user == Analytics.user_id(5)
    refute inspect(page_view) =~ "secret"

    # The same path, another query: not a new page.
    render_patch(view, "/pages/b?sort=asc")
    assert events() == []
  end

  test "a navigate mounts the next page with _live_referer: its first page counts" do
    conn = put_connect_params(browser(), %{"_live_referer" => "https://www.google.com/"})
    {:ok, _view, _html} = live(conn, "/pages/c")

    assert [%{"kind" => "page_view", "path" => "/pages/c", "referrer" => "www.google.com"}] =
             events()
  end

  test "count: :connected — the first page counts when it connects" do
    {:ok, view, _html} = live(browser(), "/app/a")

    assert [%{"kind" => "page_view", "path" => "/app/a", "route" => "/app/:id"} = first] =
             events()

    refute Map.has_key?(first, "user")

    render_patch(view, "/app/b")
    assert [%{"path" => "/app/b"}] = events()
    # A reconnection (`_mounts` > 0) is not counted; LiveViewTest always
    # joins with `_mounts: 0`, so it is not exercised here.
  end

  test "track/3 from the socket: the page the hook last saw" do
    {:ok, view, _html} = live(browser(), "/pages/a")
    render_click(view, "signup")

    assert [
             %{
               "kind" => "event",
               "name" => "signup",
               "props" => %{"plan" => "pro"},
               "site" => "www.example.com",
               "path" => "/pages/a",
               "ip" => "127.0.0.1",
               "ua" => @browser
             }
           ] = events()
  end

  test "a crawler's socket is not tracked" do
    {:ok, view, _html} = live(browser("Mozilla/5.0 (compatible; bingbot/2.0)"), "/pages/a")
    render_patch(view, "/pages/b")
    assert events() == []
  end

  test "disabled: the hook stays out" do
    configure_analytics(enabled: false)
    {:ok, view, _html} = live(browser(), "/pages/a")
    render_patch(view, "/pages/b")
    assert events() == []
  end
end
