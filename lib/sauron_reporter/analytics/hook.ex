if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule SauronReporter.Analytics.Hook do
    @moduledoc """
    Page views for live navigations (plan 28): a visitor moving between
    pages over the socket makes no HTTP request, so
    `SauronReporter.Analytics.Plug` never sees it. Modelled on phx-cms's
    `CmsEngine.Analytics.Hook`.

        live_session :public,
          on_mount: [MyAppWeb.UserAuth, SauronReporter.Analytics.Hook] do
          ...
        end

    After the hook that assigns the user, so `:sauron_user_id` (or the
    `user_assign`) is there. Options, as `{SauronReporter.Analytics.Hook,
    opts}`: `trust_forwarded` (over the configuration's), and `count:
    :connected` for routes the plug does not count — the first page then
    counts here, when its live connection opens (no referrer: the HTTP
    request's is not on the socket).

    What counts:

      * the first page of a visit was the plug's (its HTTP request): the
        first `handle_params` of the connection only remembers it;
      * a `patch` to another path is a page view, the previous URL its
        referrer — what a browser would have sent;
      * a `navigate` mounts the next LiveView afresh, with the previous
        URL in its connect params (`_live_referer`): its first
        `handle_params` is a page view;
      * a reconnection (`_mounts` > 0) and a patch that only changes the
        query are not.

    The visitor's IP and user agent come from the socket's `connect_info`,
    read once at mount — the endpoint must pass them:

        socket "/live", Phoenix.LiveView.Socket,
          websocket: [connect_info: [:peer_data, :user_agent, :x_headers, session: @session_options]],
          longpoll: [connect_info: [:peer_data, :user_agent, :x_headers, session: @session_options]]

    `:x_headers` only matters with `trust_forwarded`; without it the IP is
    the socket's peer. A crawler's socket is not tracked (`send_bots:
    true` tracks it). `SauronReporter.Analytics.track(socket, name, props)`
    sends a custom event from the page this hook last saw.
    """

    import Phoenix.LiveView

    alias SauronReporter.Analytics

    @private :sauron_analytics

    def on_mount(arg, _params, _session, socket) do
      opts = if is_list(arg), do: arg, else: []

      with true <- Analytics.enabled?(),
           true <- connected?(socket),
           %{} = context <- build_context(socket, opts) do
        {:cont,
         socket
         |> put_private(@private, context)
         |> attach_hook(@private, :handle_params, &handle_params/3)}
      else
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
        context.last_path == nil and context.navigated? ->
          record(socket, context, uri, context.live_referer)

        context.last_path == nil and context.count == :connected and not context.remount? ->
          record(socket, context, uri, nil)

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

    defp record(socket, context, uri, referrer) do
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
    defp build_context(socket, opts) do
      ua = Analytics.cut(get_connect_info(socket, :user_agent), 1_000)

      if Analytics.bot?(ua) and Analytics.setting(:send_bots, false) != true do
        nil
      else
        params = get_connect_params(socket) || %{}
        referer = params["_live_referer"]

        %{
          ip: ip(socket, Analytics.trust_forwarded(opts)),
          ua: ua,
          live_referer: referer,
          navigated?: is_binary(referer) and (params["_mounts"] || 0) == 0,
          remount?: (params["_mounts"] || 0) > 0,
          count: if(Keyword.get(opts, :count) == :connected, do: :connected, else: :request),
          last_path: nil,
          last_url: nil,
          site: nil
        }
      end
    end

    defp ip(socket, mode) do
      peer =
        case get_connect_info(socket, :peer_data) do
          %{address: address} -> Analytics.ip_to_string(address)
          _ -> nil
        end

      forwarded =
        mode &&
          case List.keyfind(get_connect_info(socket, :x_headers) || [], "x-forwarded-for", 0) do
            {_, chain} -> Analytics.forwarded_ip(chain, mode)
            nil -> nil
          end

      forwarded || peer
    end
  end
end
