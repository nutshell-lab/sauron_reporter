defmodule SauronReporter.AnalyticsPlugTest.Page do
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, :html), do: conn |> put_resp_content_type("text/html") |> send_resp(200, "<p>")

  def call(conn, :json),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, "{}")

  def call(conn, :redirect),
    do: conn |> put_resp_header("location", "/") |> send_resp(302, "")

  def call(conn, :not_modified), do: send_resp(conn, 304, "")
end

defmodule SauronReporter.AnalyticsPlugTest.Router do
  use Phoenix.Router

  alias SauronReporter.AnalyticsPlugTest.Page

  pipeline :signed_in do
    plug(:assign_user)
  end

  scope "/" do
    pipe_through(:signed_in)
    get("/offres/:id", Page, :html)
    get("/api/offres", Page, :json)
    post("/contact", Page, :html)
    get("/old", Page, :redirect)
    get("/cached", Page, :not_modified)
    get("/healthz", Page, :json)
    get("/assets/*file", Page, :json)
  end

  # Assigned downstream of the analytics plug: read when the response leaves.
  def assign_user(conn, _opts), do: Plug.Conn.assign(conn, :current_user, %{id: 12})
end

defmodule SauronReporter.AnalyticsPlugTest do
  use SauronReporter.AnalyticsCase, async: false

  import Plug.Conn

  # The test router logs each request at debug.
  @moduletag :capture_log

  alias SauronReporter.AnalyticsPlugTest.Router

  @browser "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Safari/605.1.15"

  defp request(method, url, opts \\ []) do
    conn =
      Plug.Test.conn(method, url)
      |> put_req_header("accept", Keyword.get(opts, :accept, "text/html,application/xhtml+xml"))
      |> put_req_header("user-agent", Keyword.get(opts, :ua, @browser))
      |> Map.put(:remote_ip, {203, 0, 113, 7})

    conn =
      Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {k, v}, c ->
        put_req_header(c, k, v)
      end)

    conn
    |> SauronReporter.Analytics.Plug.call(
      SauronReporter.Analytics.Plug.init(Keyword.get(opts, :plug, []))
    )
    |> Router.call(Router.init([]))
  end

  defp events do
    Analytics.flush()

    receive do
      {:delivered, "m2-app", %{"events" => events}} -> events
    after
      100 -> []
    end
  end

  defp kinds(events), do: Enum.map(events, & &1["kind"])

  test "an HTML page: a timing and a page view, with route, visitor, referrer, UTM and user" do
    configure_analytics(user_assign: :current_user)

    request(
      :get,
      "https://www.example.fr/offres/42?utm_source=newsletter&utm_campaign=octobre&token=secret",
      headers: [{"referer", "https://www.google.com/search?q=offres"}]
    )

    assert [timing, page_view] = events()

    common = %{
      "site" => "www.example.fr",
      "path" => "/offres/42",
      "route" => "/offres/:id",
      "ip" => "203.0.113.7",
      "ua" => @browser,
      "referrer" => "www.google.com",
      "user" => Analytics.user_id(12)
    }

    assert Map.take(timing, Map.keys(common)) == common
    assert Map.take(page_view, Map.keys(common)) == common

    assert %{"kind" => "timing", "method" => "GET", "status" => 200, "duration_ms" => d} = timing
    assert is_float(d) and d >= 0
    refute Map.has_key?(timing, "utm_source")

    assert %{"kind" => "page_view", "utm_source" => "newsletter", "utm_campaign" => "octobre"} =
             page_view

    refute Map.has_key?(page_view, "status")
    refute inspect(page_view) =~ "secret"
  end

  test ":sauron_user_id before the user_assign" do
    configure_analytics(user_assign: :current_user)

    Plug.Test.conn(:get, "https://www.example.fr/offres/1")
    |> assign(:sauron_user_id, "abc")
    |> SauronReporter.Analytics.Plug.call(timings: false)
    |> Router.call(Router.init([]))

    assert [%{"user" => user}] = events()
    assert user == Analytics.user_id("abc")
  end

  test "not a page view: JSON, a POST, a redirect, a crawler, a prefetch — but each timed" do
    request(:get, "https://www.example.fr/api/offres")
    request(:post, "https://www.example.fr/contact")
    request(:get, "https://www.example.fr/old")

    request(:get, "https://www.example.fr/offres/1",
      ua: "Mozilla/5.0 (compatible; Googlebot/2.1)"
    )

    request(:get, "https://www.example.fr/offres/1", headers: [{"sec-purpose", "prefetch"}])

    events = events()
    assert kinds(events) == List.duplicate("timing", 5)
    assert Enum.map(events, & &1["status"]) == [200, 200, 302, 200, 200]
    assert Enum.map(events, & &1["method"]) == ~w(GET POST GET GET GET)
  end

  test "send_bots: true sends crawlers' page views (Sauron counts them apart)" do
    configure_analytics(send_bots: true)
    request(:get, "https://www.example.fr/offres/1", ua: "curl/8.0")
    assert kinds(events()) == ["timing", "page_view"]
  end

  test "a 304 to a browser asking for HTML is a page view" do
    request(:get, "https://www.example.fr/cached")
    assert kinds(events()) == ["timing", "page_view"]
  end

  test "health checks, assets and ignore_paths: nothing at all" do
    configure_analytics(ignore_paths: ["/api"])
    request(:get, "https://www.example.fr/healthz")
    request(:get, "https://www.example.fr/assets/app.js")
    request(:get, "https://www.example.fr/api/offres")
    assert events() == []
  end

  test "page_views: false and timings: false keep one of the two" do
    request(:get, "https://www.example.fr/offres/1", plug: [page_views: false])
    assert kinds(events()) == ["timing"]

    request(:get, "https://www.example.fr/offres/1", plug: [timings: false])
    assert kinds(events()) == ["page_view"]
  end

  test "trust_forwarded: the last X-Forwarded-For hop, or the first; remote_ip otherwise" do
    headers = [{"x-forwarded-for", "198.51.100.1, 192.0.2.44"}]

    request(:get, "https://www.example.fr/offres/1", headers: headers, plug: [timings: false])
    assert [%{"ip" => "203.0.113.7"}] = events()

    request(:get, "https://www.example.fr/offres/1",
      headers: headers,
      plug: [timings: false, trust_forwarded: true]
    )

    assert [%{"ip" => "192.0.2.44"}] = events()

    configure_analytics(trust_forwarded: :first)
    request(:get, "https://www.example.fr/offres/1", headers: headers, plug: [timings: false])
    assert [%{"ip" => "198.51.100.1"}] = events()
  end

  test "disabled: the conn untouched, nothing sent" do
    configure_analytics(enabled: false)
    conn = request(:get, "https://www.example.fr/offres/1")
    assert conn.status == 200
    assert events() == []
  end

  test "a site off the allowlist: nothing" do
    configure_analytics(sites: ["www.example.fr"])
    request(:get, "https://vm-cms.internal/offres/1")
    assert events() == []
  end
end
