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

  # The plug after the session is fetched: it can flag it for the hook.
  pipeline :counted do
    plug(:fetch_session)
    plug(SauronReporter.Analytics.Plug, timings: false)
  end

  scope "/counted" do
    pipe_through(:counted)

    live_session :counted, on_mount: [SauronReporter.Analytics.Hook] do
      live("/:id", SauronReporter.AnalyticsHookTest.Live)
    end
  end

  scope "/" do
    pipe_through(:browser)

    live_session :public,
      on_mount: [__MODULE__, SauronReporter.Analytics.Hook] do
      live("/pages/:id", SauronReporter.AnalyticsHookTest.Live)
    end

    live_session :staff,
      on_mount: [{__MODULE__, :staff}, SauronReporter.Analytics.Hook] do
      live("/staff/:id", SauronReporter.AnalyticsHookTest.Live)
    end

    live_session :connected,
      on_mount: [{SauronReporter.Analytics.Hook, count: :connected}] do
      live("/app/:id", SauronReporter.AnalyticsHookTest.Live)
    end
  end

  # The app's own hook, before ours: who is signed in.
  def on_mount(:default, _params, _session, socket),
    do: {:cont, Phoenix.Component.assign(socket, :sauron_user_id, 5)}

  def on_mount(:staff, _params, _session, socket),
    do:
      {:cont,
       Phoenix.Component.assign(socket, :current_user, %{id: 3, email: "nathan@NUTSHELL-lab.com"})}
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

  test "the page counts when its live connection opens; a patch to another path too" do
    {:ok, view, _html} = live(browser(), "/pages/a?utm_campaign=octobre")

    assert [
             %{
               "kind" => "page_view",
               "site" => "www.example.com",
               "path" => "/pages/a",
               "route" => "/pages/:id",
               "utm_campaign" => "octobre",
               "ip" => "127.0.0.1",
               "ua" => @browser
             } = first
           ] = events()

    # The request's referrer is not on the socket: the page_request has it.
    refute Map.has_key?(first, "referrer")

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

  test "count: :connected, read before 0.7.0, changes nothing" do
    {:ok, view, _html} = live(browser(), "/app/a")

    assert [%{"kind" => "page_view", "path" => "/app/a", "route" => "/app/:id"} = first] =
             events()

    refute Map.has_key?(first, "user")

    render_patch(view, "/app/b")
    assert [%{"path" => "/app/b"}] = events()
    # A reconnection (`_mounts` > 0) is not counted; LiveViewTest always
    # joins with `_mounts: 0`, so it is not exercised here.
  end

  test "the disconnected mount — the HTTP render — sends nothing" do
    conn = get(browser(), "/pages/a")
    assert html_response(conn, 200) =~ "page"
    assert events() == []
  end

  describe "pairing (0.7.0): the request and its page view" do
    test "the plug's page_request and the hook's page_view: the same site, path, IP and user agent" do
      configure_analytics(trust_forwarded: true)

      conn =
        browser()
        |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.1, 192.0.2.44")
        |> Plug.Conn.put_req_header("referer", "https://www.google.com/search?q=x")

      {:ok, _view, _html} = live(conn, "/counted/a1b2?utm_source=newsletter")

      assert [
               %{"kind" => "page_request", "status" => 200, "referrer" => "www.google.com"} =
                 request,
               %{"kind" => "page_view"} = page_view
             ] = events()

      pair = ~w(site path route ip ua utm_source)
      assert Map.take(request, pair) == Map.take(page_view, pair)

      assert %{"site" => "www.example.com", "path" => "/counted/a1b2", "ip" => "192.0.2.44"} =
               page_view

      assert page_view["ua"] == @browser
    end

    test "every X-Forwarded-For header, joined as the plug joins them" do
      configure_analytics(trust_forwarded: :first)

      conn =
        browser()
        |> Map.update!(:req_headers, fn headers ->
          headers ++
            [{"x-forwarded-for", "198.51.100.1"}, {"x-forwarded-for", "192.0.2.44"}]
        end)

      {:ok, _view, _html} = live(conn, "/counted/a")

      assert [%{"kind" => "page_request", "ip" => ip}, %{"kind" => "page_view", "ip" => ip}] =
               events()

      assert ip == "198.51.100.1"
    end
  end

  test "track/3 from the socket: the page the hook last saw" do
    {:ok, view, _html} = live(browser(), "/pages/a")
    assert [%{"kind" => "page_view"}] = events()
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

  test "a robot's socket is tracked like anyone's: Sauron sorts it (0.7.0)" do
    robot = "Mozilla/5.0 (X11; Linux x86_64) HeadlessChrome/120.0 Safari/537.36"
    {:ok, view, _html} = live(browser(robot), "/pages/a")
    render_patch(view, "/pages/b")

    assert [%{"path" => "/pages/a", "ua" => ^robot}, %{"path" => "/pages/b", "ua" => ^robot}] =
             events()
  end

  test "disabled: the hook stays out" do
    configure_analytics(enabled: false)
    {:ok, view, _html} = live(browser(), "/pages/a")
    render_patch(view, "/pages/b")
    assert events() == []
  end

  describe "paths (0.6.1)" do
    test "ignore_paths: no live page view there, as the plug sends none" do
      configure_analytics(ignore_paths: ["/pages/hidden"])
      {:ok, view, _html} = live(browser(), "/pages/a")
      assert [%{"path" => "/pages/a"}] = events()
      render_patch(view, "/pages/hidden")
      assert events() == []

      # Out of it, counted, the hidden page only a host.
      render_patch(view, "/pages/b")
      assert [%{"path" => "/pages/b", "referrer" => "www.example.com"}] = events()

      conn = put_connect_params(browser(), %{"_live_referer" => "https://www.google.com/"})
      {:ok, _view, _html} = live(conn, "/pages/hidden")
      assert events() == []

      configure_analytics(ignore_paths: ["/app"])
      {:ok, view, _html} = live(browser(), "/app/a")
      render_patch(view, "/app/b")
      assert events() == []
    end

    test "a secret in the path: masked, or the app's pattern; track/3 alike" do
      token = "Xb3kQ9vN2mLp7RtY5wZc1HfJ8sDg4AeU"
      {:ok, view, _html} = live(browser(), "/pages/a")
      assert [%{"path" => "/pages/a"}] = events()
      render_patch(view, "/pages/#{token}")
      render_click(view, "signup")

      assert [
               %{"kind" => "page_view", "path" => "/pages/:token", "route" => "/pages/:id"},
               %{"kind" => "event", "path" => "/pages/:token"}
             ] = events()

      configure_analytics(redact_paths: ["/app/:code"])
      {:ok, _view, _html} = live(browser(), "/app/short")
      assert [%{"path" => "/app/:code"}] = events()
    end
  end

  describe "ours (0.6.0)" do
    setup do
      configure_analytics(ignore_emails: ["@nutshell-lab.com"])
    end

    test "signed in, by the socket's assigns: no live page view, no event" do
      {:ok, view, _html} = live(browser(), "/staff/a")
      render_patch(view, "/staff/b")
      render_click(view, "signup")
      assert events() == []

      conn = put_connect_params(browser(), %{"_live_referer" => "https://www.google.com/"})
      {:ok, _view, _html} = live(conn, "/staff/c")
      assert events() == []
    end

    test "signed out, by the session's flag: no live page view, no event" do
      conn = Plug.Test.init_test_session(browser(), %{"sauron_ignore" => true})

      {:ok, view, _html} = live(conn, "/pages/a")
      render_patch(view, "/pages/b")
      render_click(view, "signup")
      assert events() == []

      conn = put_connect_params(conn, %{"_live_referer" => "https://www.google.com/"})
      {:ok, _view, _html} = live(conn, "/pages/c")
      assert events() == []
    end

    test "the cookie, through the plug after fetch_session, reaches the hook" do
      conn = Phoenix.ConnTest.put_req_cookie(browser(), "sauron_ignore", "1")
      {:ok, view, _html} = live(conn, "/counted/a")
      render_patch(view, "/counted/b")
      assert events() == []

      # Without it, the plug's request, the hook's first page and its patch.
      {:ok, view, _html} = live(browser(), "/counted/a")
      render_patch(view, "/counted/b")

      assert [
               %{"kind" => "page_request", "path" => "/counted/a"},
               %{"kind" => "page_view", "path" => "/counted/a"},
               %{"kind" => "page_view", "path" => "/counted/b"}
             ] = events()
    end

    test "a session without the flag, a user not under ignore_emails: counted as before" do
      conn = Plug.Test.init_test_session(browser(), %{"sauron_ignore" => "no"})
      {:ok, view, _html} = live(conn, "/pages/a")
      render_patch(view, "/pages/b")
      assert [%{"path" => "/pages/a"}, %{"kind" => "page_view", "path" => "/pages/b"}] = events()

      configure_analytics(ignore_emails: ["@other.fr"])
      {:ok, view, _html} = live(browser(), "/staff/a")
      render_patch(view, "/staff/b")
      assert [%{"path" => "/staff/a"}, %{"kind" => "page_view", "path" => "/staff/b"}] = events()
    end
  end
end
