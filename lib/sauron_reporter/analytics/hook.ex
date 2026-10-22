if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule SauronReporter.Analytics.Hook do
    @moduledoc """
    Page views — a person's (plan 32) — to Sauron: one when a page's live
    connection opens, one per live navigation. A live connection is the
    proof a browser ran the page's script, which no robot fetching HTML
    gives; `SauronReporter.Analytics.Plug` sends the HTTP request as a
    `page_request`, and Sauron pairs the two (the same visitor — its IP
    and user agent — and the same path, within seconds). Modelled on
    phx-cms's `CmsEngine.Analytics.Hook`.

        live_session :public,
          on_mount: [MyAppWeb.UserAuth, SauronReporter.Analytics.Hook] do
          ...
        end

    On every `live_session` that serves pages, after the hook that
    assigns the user, so `:sauron_user_id` (or the `user_assign`) is
    there. Options, as `{SauronReporter.Analytics.Hook, opts}`:
    `trust_forwarded` (over the configuration's). `count:` is no longer
    read (0.7.0): every page counts when its live connection opens, as
    `count: :connected` did.

    What counts:

      * the page a connected mount opens on: the first of a visit, with
        the path its HTTP request had (no referrer: the request's is not
        on the socket — Sauron has it on the `page_request`), or the
        page a `navigate` mounted, the previous URL in its connect
        params (`_live_referer`) its referrer;
      * a `patch` to another path, the previous URL its referrer — what
        a browser would have sent;
      * not the disconnected mount (the HTTP render: a robot gets that
        far), nor a reconnection (`_mounts` > 0), nor a patch that only
        changes the query;
      * nor a page under the paths the plug never reports — assets, the
        live socket, the app's `ignore_paths` (0.6.1; a patch from it to
        another page counts, its referrer the host only).

    A robot's socket is tracked like a person's (0.7.0): a headless
    browser that says what it is still says it, and Sauron sorts it.

    The path is sent as the plug sends it (0.6.1): the app's
    `redact_paths` applied, token-shaped segments masked (see
    `SauronReporter.Analytics`), never the query.

    The visitor's IP and user agent come from the socket's `connect_info`,
    read once at mount — the endpoint must pass them:

        socket "/live", Phoenix.LiveView.Socket,
          websocket: [connect_info: [:peer_data, :user_agent, :x_headers, session: @session_options]],
          longpoll: [connect_info: [:peer_data, :user_agent, :x_headers, session: @session_options]]

    They must be the plug's, or Sauron cannot pair a page view with its
    request: the user agent is the browser's on both; the IP is the last
    (or first, `trust_forwarded: :first`) `X-Forwarded-For` hop of the
    socket's `:x_headers` with `trust_forwarded`, as the plug reads it on
    the request — so behind a proxy, `trust_forwarded` it is. Without
    it the hook has only the socket's peer (`:peer_data`), which is the
    plug's `conn.remote_ip` only when nothing rewrites it (no proxy, no
    `RemoteIp`).

    **Ours (0.6.0)** is never counted, nor `track/3`ed (see
    `SauronReporter.Analytics`): a signed-in user by the socket's assigns
    — the `user_assign`'s email under `ignore_emails`, or `:sauron_ignore`
    — read when each page view is decided; a signed-out person of the app
    by the session's `"sauron_ignore"`, which `SauronReporter.Analytics.Plug`
    puts there for a request carrying its cookie, when the session is
    fetched before it. A connected mount reads no cookie, but its session
    is the page's signed session merged with the session cookie the
    socket read (`session: @session_options` in `connect_info`): the flag
    reaches the hook through either.

    `SauronReporter.Analytics.track(socket, name, props)` sends a custom
    event from the page this hook last saw.
    """

    import Phoenix.LiveView

    alias SauronReporter.Analytics

    @private :sauron_analytics

    def on_mount(arg, _params, session, socket) do
      opts = if is_list(arg), do: arg, else: []
      ours? = is_map(session) and session[Analytics.ignore_cookie()] == true

      with true <- Analytics.enabled?(),
           true <- connected?(socket),
           %{} = context <- build_context(socket, opts) do
        {:cont,
         socket
         |> put_private(@private, Map.put(context, :ours?, ours?))
         |> attach_hook(@private, :handle_params, &handle_params/3)}
      else
        # Not tracked, but track/3 from this socket must know.
        _ when ours? -> {:cont, put_private(socket, @private, %{ours?: true})}
        _ -> {:cont, socket}
      end
    rescue
      exception ->
        Analytics.debug(exception)
        {:cont, socket}
    end

    defp handle_params(_params, url, socket) do
      context = socket.private[@private]
      uri = URI.parse(url)

      cond do
        # The page the live connection opened on: the visit's first (its
        # request was the plug's) or the one a `navigate` mounted.
        context.last_path == nil and not context.remount? ->
          record(socket, context, uri, context.live_referer)

        # A reconnection's page was counted when it first connected.
        context.last_path == nil ->
          :seed

        context.last_path == uri.path ->
          :same

        true ->
          record(socket, context, uri, context.last_url)
      end

      {:cont,
       put_private(socket, @private, %{
         context
         | last_path: uri.path,
           last_url: url,
           site: uri.host
       })}
    rescue
      exception ->
        Analytics.debug(exception)
        {:cont, socket}
    end

    # A path the plug would not report (0.6.1); ours: by the session at
    # mount, or by the assigns now.
    defp record(socket, context, uri, referrer) do
      cond do
        Analytics.ignored_path?(uri.path) -> :ignored
        context.ours? or Analytics.ours_assigns?(socket.assigns) -> :ours
        true -> push(socket, context, uri, referrer)
      end
    end

    defp push(socket, context, uri, referrer) do
      Analytics.push(
        %{
          "kind" => "page_view",
          "site" => uri.host,
          "path" => Analytics.path(uri.path),
          "route" => route(socket, uri),
          "referrer" => Analytics.referrer_host(referrer),
          "ip" => context.ip,
          "ua" => context.ua,
          "user" => Analytics.user_from_assigns(socket.assigns)
        }
        |> Map.merge(Analytics.utm(uri.query))
      )
    end

    @doc false
    # Whether the session said ours at mount, for `track/3` from a socket.
    def ours_session?(socket), do: match?(%{ours?: true}, socket.private[@private])

    @doc false
    # The page this hook last saw, for `track/3` from a socket.
    def context(socket) do
      context = socket.private[@private] || %{}

      %{
        "site" => context[:site] || host(socket.host_uri),
        "path" => Analytics.path(context[:last_path]),
        "ip" => context[:ip],
        "ua" => context[:ua],
        "user" => Analytics.user_from_assigns(socket.assigns)
      }
    end

    defp host(%URI{host: host}), do: host
    defp host(_), do: nil

    defp route(socket, uri) do
      case socket.router &&
             Phoenix.Router.route_info(socket.router, "GET", uri.path || "/", uri.host) do
        %{route: route} when is_binary(route) -> Analytics.cut(route, 300)
        _ -> nil
      end
    rescue
      _ -> nil
    end

    # `get_connect_info/2` and `get_connect_params/1` answer at mount only.
    # The options' `count:` (before 0.7.0) is no longer read.
    defp build_context(socket, opts) do
      params = get_connect_params(socket) || %{}

      %{
        ip: ip(socket, Analytics.trust_forwarded(opts)),
        ua: Analytics.cut(get_connect_info(socket, :user_agent), 1_000),
        live_referer: params["_live_referer"],
        remount?: (params["_mounts"] || 0) > 0,
        last_path: nil,
        last_url: nil,
        site: nil
      }
    end

    defp ip(socket, mode) do
      peer =
        case get_connect_info(socket, :peer_data) do
          %{address: address} -> Analytics.ip_to_string(address)
          _ -> nil
        end

      # Every X-Forwarded-For header, joined as the plug joins them.
      forwarded =
        mode &&
          case for {"x-forwarded-for", chain} <- get_connect_info(socket, :x_headers) || [],
                   do: chain do
            [] -> nil
            chains -> Analytics.forwarded_ip(Enum.join(chains, ","), mode)
          end

      forwarded || peer
    end
  end
end
