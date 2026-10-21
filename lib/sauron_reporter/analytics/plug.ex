defmodule SauronReporter.Analytics.Plug do
  @moduledoc """
  Page views and server timings to Sauron (plan 28), decided once the
  response is known (`register_before_send`):

    * **a timing** for every request: method, the router's pattern
      (`/offres/:id`, when a `Phoenix.Router` answered), status and
      duration from this plug to the response;
    * **a page view** for an HTML page served: a `GET` answered 2xx with
      `text/html`, or a 304 to a browser asking for HTML; not a
      prefetch, not a crawler (Sauron's own user-agent test; `send_bots:
      true` sends them). Redirects are not page views: their target is.

  Both carry the site (`conn.host`), the path (never the query), the
  visitor's IP and user agent (Sauron hashes them, keeps neither), the
  referrer's host, the UTM parameters, and the signed-in user, hashed
  (`:sauron_user_id`, see `SauronReporter.Analytics`). Assets, health
  checks and the live socket are never reported (`ignore_paths` adds
  more). The path goes without its secrets (0.6.1): the app's
  `redact_paths` applied, token-shaped segments masked — see
  `SauronReporter.Analytics`.

      # endpoint.ex — after Plug.Static (assets are not timed) and the
      # proxy handling that sets remote_ip:
      plug SauronReporter.Analytics.Plug

  **Ours (0.6.0).** A request that is ours (see `SauronReporter.Analytics`:
  the `user_assign`'s email under `ignore_emails`, or the assign
  `:sauron_ignore`) is timed, never a page view, and its response sets
  the cookie `sauron_ignore=1` — a year, path `/`, `HttpOnly`,
  `SameSite=Lax`, `Secure` over https, no identifier in it. A request
  carrying that cookie is ours too, signed in or not, so a person of the
  app signed out on its public pages stays left out. The plug reads the
  cookies itself: no session, no pipeline needed for that. The cookie's
  name is fixed.

  The LiveView hook cannot read a cookie on its connected mount; it reads
  the session. So when this plug finds a request ours and the session is
  already fetched, it puts `"sauron_ignore" => true` in it — never
  fetching the session itself. For the hook to leave out a signed-out
  person of the app, the session must be fetched before this plug: put
  it after `:fetch_session` — in the `:browser` pipeline (`timings:
  false` there, `page_views: false` in the endpoint), or behind `plug
  :fetch_session` in the endpoint. Otherwise only their live navigations
  are counted; a signed-in user is always left out (the hook reads the
  assigns).

  Options: `page_views: false` or `timings: false` keep one of the two —
  a timing plug in the endpoint and a page-view plug in the pipeline of
  the public pages, say — and `trust_forwarded` (see
  `SauronReporter.Analytics`), over the configuration's. A no-op while
  analytics is not enabled.
  """

  @behaviour Plug

  import Plug.Conn

  alias SauronReporter.Analytics

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    if Analytics.enabled?() and not Analytics.ignored_path?(conn.request_path) do
      started = System.monotonic_time()
      conn = fetch_cookies(conn)

      conn
      |> mark_session(Analytics.ours?(conn))
      |> register_before_send(&before_send(&1, started, opts))
    else
      conn
    end
  rescue
    exception ->
      Analytics.debug(exception)
      conn
  end

  defp before_send(conn, started, opts) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) / 1_000

    context = context(conn, opts)
    route = route(conn)
    ours_assigns? = Analytics.ours_assigns?(conn.assigns)
    ours? = ours_assigns? or Analytics.ignore_cookie?(conn)

    if Keyword.get(opts, :timings, true) do
      Analytics.push(
        Map.merge(context, %{
          "kind" => "timing",
          "method" => conn.method,
          "route" => route,
          "status" => conn.status,
          "duration_ms" => Float.round(duration_ms, 2)
        })
      )
    end

    if Keyword.get(opts, :page_views, true) and not ours? and page_view?(conn, context) do
      Analytics.push(
        context
        |> Map.merge(%{"kind" => "page_view", "route" => route})
        |> Map.merge(Analytics.utm(conn.query_string))
      )
    end

    conn
    |> put_ignore_cookie(ours_assigns?)
    |> mark_session(ours?)
  rescue
    exception ->
      Analytics.debug(exception)
      conn
  end

  # Signed in as ours, or ours by the app's word: the cookie that keeps
  # them left out once signed out.
  defp put_ignore_cookie(conn, true) do
    put_resp_cookie(conn, Analytics.ignore_cookie(), "1",
      max_age: 365 * 24 * 60 * 60,
      path: "/",
      http_only: true,
      same_site: "Lax",
      secure: conn.scheme == :https
    )
  end

  defp put_ignore_cookie(conn, _ours?), do: conn

  # The hook's way to know: the session, when the app fetched it already.
  # Written only when it changes, so the session cookie is not rewritten
  # on every response. In before_send it lasts only if the session was
  # fetched before this plug (Plug.Session writes its cookie in a
  # before_send of its own, run after this one then).
  defp mark_session(%{private: %{plug_session_fetch: :done}} = conn, true) do
    if get_session(conn, Analytics.ignore_cookie()) == true,
      do: conn,
      else: put_session(conn, Analytics.ignore_cookie(), true)
  rescue
    _ -> conn
  end

  defp mark_session(conn, _ours?), do: conn

  @doc false
  # The request's visitor fields, as `track/3` from a conn sends them.
  def context(conn, opts \\ []) do
    %{
      "site" => conn.host,
      "path" => Analytics.path(conn.request_path),
      "referrer" => Analytics.referrer_host(header(conn, "referer")),
      "ip" => ip(conn, Analytics.trust_forwarded(opts)),
      "ua" => Analytics.cut(header(conn, "user-agent"), 1_000),
      "user" => Analytics.user_from_assigns(conn.assigns)
    }
  end

  defp page_view?(conn, context) do
    conn.method == "GET" and html?(conn) and not prefetch?(conn) and
      (Analytics.setting(:send_bots, false) == true or not Analytics.bot?(context["ua"]))
  end

  defp html?(%{status: status} = conn) when status in 200..299 do
    case get_resp_header(conn, "content-type") do
      [type | _] -> String.starts_with?(type, "text/html")
      [] -> false
    end
  end

  defp html?(%{status: 304} = conn) do
    case get_req_header(conn, "accept") do
      [accept | _] -> String.contains?(accept, "text/html")
      [] -> false
    end
  end

  defp html?(_conn), do: false

  defp prefetch?(conn) do
    Enum.any?(
      get_req_header(conn, "sec-purpose") ++ get_req_header(conn, "purpose"),
      &String.contains?(&1, "prefetch")
    )
  end

  # The pattern the router matched, when a Phoenix router answered.
  defp route(%{private: %{phoenix_router: router}} = conn) when is_atom(router) do
    if Code.ensure_loaded?(Phoenix.Router) do
      case Phoenix.Router.route_info(router, conn.method, conn.path_info, conn.host) do
        %{route: route} when is_binary(route) -> Analytics.cut(route, 300)
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp route(_conn), do: nil

  defp ip(conn, false), do: Analytics.ip_to_string(conn.remote_ip)

  defp ip(conn, mode) do
    case get_req_header(conn, "x-forwarded-for") do
      [] ->
        Analytics.ip_to_string(conn.remote_ip)

      chains ->
        Analytics.forwarded_ip(Enum.join(chains, ","), mode) ||
          Analytics.ip_to_string(conn.remote_ip)
    end
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
