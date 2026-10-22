defmodule SauronReporter.AnalyticsContractTest do
  @moduledoc """
  What the client posts follows Sauron's contract — plan 28's
  "Payload" section, rule by rule — even at the extremes: a long path,
  a long user agent, too many props. Sauron would accept every event
  as sent (none of its `dropped` comes from this client).
  """

  use SauronReporter.AnalyticsCase, async: false

  import Plug.Conn

  @moduletag :capture_log

  @fields ~w(kind at site path route name props method status duration_ms referrer
             utm_source utm_medium utm_campaign utm_term utm_content user ip ua country app)

  defmodule Router do
    use Phoenix.Router

    get("/offres/:id", SauronReporter.AnalyticsContractTest.Page, :html)
  end

  defmodule Page do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, _),
      do: conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, "")
  end

  test "every event of every kind, JSON-encoded, follows the Payload rules" do
    long = String.duplicate("é", 5_000)

    Plug.Test.conn(
      :get,
      "https://WWW.Example.FR/offres/#{String.duplicate("x", 2_000)}?utm_source=#{String.duplicate("s", 300)}&utm_medium=email&utm_term=%20&q=secret#frag"
    )
    |> put_req_header("user-agent", "Mozilla/5.0 " <> long)
    |> put_req_header("referer", "https://news.example.org/a?b=c")
    |> put_req_header("accept", "text/html")
    |> assign(:sauron_user_id, 1234)
    |> SauronReporter.Analytics.Plug.call([])
    |> Router.call(Router.init([]))

    Analytics.track(
      %{
        site: "www.example.fr",
        path: "/offres",
        ip: "2001:db8::1",
        ua: "Mozilla/5.0",
        user_id: 9
      },
      String.duplicate("n", 150),
      Map.new(1..30, &{"k#{&1}", String.duplicate("v", 300)})
      |> Map.put(String.duplicate("k", 41), 1)
      |> Map.put("float", 1.5)
      |> Map.put("map", %{a: 1})
    )

    Analytics.track(%{site: "www.example.fr"}, "server.side")

    events = flushed_events()

    body = Jason.encode!(%{"events" => events})
    assert byte_size(body) <= 524_288
    %{"events" => decoded} = Jason.decode!(body)
    assert length(decoded) <= 500

    assert decoded |> Enum.map(& &1["kind"]) |> Enum.sort() == ~w(event event page_request timing)

    now = DateTime.utc_now()
    for event <- decoded, do: assert_contract(event, now)
  end

  defp assert_contract(event, now) do
    # Only the contract's fields; no nil, no empty string.
    assert Map.keys(event) -- @fields == []

    for {key, value} <- event do
      refute is_nil(value), "#{key} is null"
      refute value == "", "#{key} is empty"
      if is_binary(value), do: assert(String.trim(value) == value, "#{key} is not trimmed")
    end

    assert event["kind"] in ~w(page_request page_view event timing)

    assert {:ok, at, _offset} = DateTime.from_iso8601(event["at"])
    assert DateTime.diff(at, now) >= -48 * 3600 and DateTime.diff(at, now) <= 5 * 60

    assert event["site"] == String.downcase(event["site"])
    assert String.length(event["site"]) <= 253

    case event["kind"] do
      kind when kind in ~w(page_request page_view) -> assert is_binary(event["path"])
      "event" -> assert is_binary(event["name"])
      "timing" -> assert is_number(event["duration_ms"])
    end

    if path = event["path"] do
      refute path =~ ~r/[?#]/
      assert String.length(path) <= 1_000
    end

    if route = event["route"], do: assert(String.length(route) <= 300)
    if name = event["name"], do: assert(String.length(name) <= 100)

    if props = event["props"] do
      assert is_map(props) and map_size(props) <= 10

      for {k, v} <- props do
        assert String.length(k) <= 40
        assert is_number(v) or (is_binary(v) and String.length(v) <= 200)
      end

      # The first ten keys by name.
      assert Map.keys(props) == props |> Map.keys() |> Enum.sort()
    end

    if method = event["method"] do
      assert String.length(method) <= 10 and method == String.upcase(method)
    end

    if status = event["status"], do: assert(is_integer(status) and status in 100..599)
    if d = event["duration_ms"], do: assert(d >= 0 and d <= 3_600_000)

    if referrer = event["referrer"] do
      # Only a host leaves the app.
      assert referrer =~ ~r/\A[a-z0-9.-]+\z/
    end

    for utm <- ~w(utm_source utm_medium utm_campaign utm_term utm_content),
        value = event[utm],
        do: assert(String.length(value) <= 200)

    if user = event["user"], do: assert(user =~ ~r/\A[0-9a-f]{16,64}\z/)
    if ip = event["ip"], do: assert({:ok, _} = :inet.parse_address(String.to_charlist(ip)))
    if ua = event["ua"], do: assert(String.length(ua) <= 1_000)
  end
end
