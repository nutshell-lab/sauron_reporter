defmodule SauronReporter.Analytics do
  @moduledoc """
  An app's visits, custom events and server timings sent to Sauron
  (sauron's plan 28), beside whatever analytics the app keeps of its
  own. Cookieless: the app forwards each visitor's IP and user agent,
  Sauron hashes them with a salt of the day and keeps neither.

  Opt-in, on top of the reporter's `url`, `token` and `app`:

      config :sauron_reporter,
        url: "https://sauron.nutshell-lab.com",   # SAURON_URL
        token: "...",                             # SAURON_REPORT_TOKEN
        app: "my-app",
        analytics: [
          enabled: true,
          # optional:
          user_key: "...",           # HMAC key for user ids; without it no `user` is sent
          sites: ["www.example.fr"], # only these hosts are reported (default: any)
          user_assign: :current_user,# an assign whose `.id` is the user (after :sauron_user_id)
          trust_forwarded: false,    # true | :last | :first — the IP from X-Forwarded-For
          ignore_paths: ["/metrics"],# more paths never reported (prefixes, by segment)
          send_bots: false,          # true sends crawlers' page views too
          flush_every: 5_000,        # ms between two sends
          batch_size: 50,            # a send as soon as this many wait
          max_buffer: 5_000,         # beyond, the oldest are dropped and counted
          deliver: nil,              # or {mod, fun}(app, payload): tests, Sauron itself
          req_options: []            # merged into Req's (tests: a Req.Test plug)
        ]

  The pieces:

    * `SauronReporter.Analytics.Plug` — a page view per HTML page served
      and a timing per request;
    * `SauronReporter.Analytics.Hook` — a page view per live navigation;
    * `track/3` — a custom event, from a conn, a socket or a map;
    * `SauronReporter.Analytics.Buffer` — holds the events and sends
      them in batches; runs in this library's application, inert while
      analytics is not enabled.

  **Who is signed in.** The plug and the hook read the assign
  `:sauron_user_id` (any term: `to_string/1` of it is hashed), else the
  `user_assign`'s `id`. `user_id/1` hashes it with `user_key` —
  HMAC-SHA256, 32 hex characters — before it leaves the app.

  **The visitor's IP.** `conn.remote_ip`, as the app's own proxy
  handling sets it (`RemoteIp`, `Plug.RewriteOn`…). `trust_forwarded:
  true` (or `:last`) reads the last address of `X-Forwarded-For`
  instead — the one the nearest proxy appended, which a client cannot
  forge; `:first` the first, only behind a chain of proxies the app
  trusts entirely.

  Never raises into the app: a failure is logged at debug and counted.
  Telemetry, each with `%{count: n}` and `%{app: app}`:

    * `[:sauron_reporter, :analytics, :sent]` — Sauron took a batch
      (`count` accepted; `dropped` refused one by one, in measurements);
    * `[:sauron_reporter, :analytics, :dropped]` — events lost before a
      send (`reason: :buffer_full`) or refused by Sauron (`:rejected`);
    * `[:sauron_reporter, :analytics, :failed]` — a batch lost to a
      failed send (`reason`: the status or the error).
  """

  alias SauronReporter.Analytics.Buffer

  # Sauron's own test (`Sauron.Analytics.UserAgent`), so a bot here is a
  # bot there.
  @bot ~r/bot|spider|crawl|slurp|ia_archiver|headless|phantom|selenium|puppeteer|fetch|curl|wget|python|go-http-client|okhttp|httpx|libcurl|scrapy|aiohttp|axios|java\/|httpclient|postman/i

  @utm ~w(utm_source utm_medium utm_campaign utm_term utm_content)
  @max_props 10
  @prop_key 40
  @prop_value 200

  @ignore_paths ~w(/assets /fonts /images /favicon.ico /robots.txt /sitemap.xml /live /phoenix /health /healthz)

  # ---------- configuration ----------

  @doc "The `analytics:` keyword list."
  def config, do: Application.get_env(:sauron_reporter, :analytics) || []

  @doc false
  def setting(key, default \\ nil), do: Keyword.get(config(), key, default)

  @doc "Whether events are collected: enabled, an app, and a URL and token or a `deliver`."
  def enabled? do
    reporter = Application.get_all_env(:sauron_reporter)
    analytics = reporter[:analytics] || []

    analytics[:enabled] == true and filled?(reporter[:app]) and
      (match?({_, _}, analytics[:deliver]) or
         (filled?(reporter[:url]) and filled?(reporter[:token])))
  rescue
    _ -> false
  end

  defp filled?(value), do: is_binary(value) and value != ""

  # ---------- public API ----------

  @doc """
  A custom event `name` with up to ten flat `props` (string or number
  values; an atom is sent as its name). The first argument says where:

    * a `Plug.Conn` — its host, path, visitor and user;
    * a LiveView socket the hook is mounted on — its current page,
      visitor and user;
    * a map or keyword list — `:site` (required), `:path`, `:ip`, `:ua`,
      `:user_id` (hashed here) or `:user` (already hashed). Without `:ip`
      and `:ua`, the event has no visitor.

  Always `:ok`.
  """
  def track(where, name, props \\ %{}) do
    if enabled?() do
      where
      |> context()
      |> Map.merge(%{
        "kind" => "event",
        "name" => cut(to_text(name), 100),
        "props" => props(props)
      })
      |> push()
    end

    :ok
  rescue
    exception -> debug(exception)
  end

  @doc """
  The hash of an app's user id as Sauron receives it:
  HMAC-SHA256(`user_key`, `to_string(id)`), the first 32 hex characters.
  `nil` without an id or a `user_key`.
  """
  def user_id(nil), do: nil

  def user_id(id) do
    case setting(:user_key) do
      key when is_binary(key) and key != "" ->
        :hmac
        |> :crypto.mac(:sha256, key, to_string(id))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 32)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc "Whether a user agent names a crawler or a script — Sauron's own test."
  def bot?(nil), do: false
  def bot?(ua) when is_binary(ua), do: Regex.match?(@bot, ua)
  def bot?(_), do: false

  @doc "The paths never reported: the defaults, then the app's `ignore_paths`."
  def ignored_path?(path) when is_binary(path) do
    Enum.any?(@ignore_paths ++ List.wrap(setting(:ignore_paths, [])), fn prefix ->
      prefix = String.trim_trailing(prefix, "/")
      path == prefix or String.starts_with?(path, prefix <> "/")
    end)
  end

  def ignored_path?(_), do: false

  @doc "Counters since boot: `%{sent:, dropped:, failed:, buffered:}`."
  def stats, do: Buffer.stats()

  @doc "Sends what waits now (tests, a shutdown hook)."
  def flush, do: Buffer.flush()

  # ---------- events, for the plug and the hook ----------

  @doc false
  # One event, string keys, JSON-ready; nil fields dropped, the time
  # stamped. Dropped here when the site is not on the allowlist.
  def push(%{"site" => site} = event) when is_binary(site) and site != "" do
    site = site |> String.downcase() |> String.slice(0, 253)

    if site_allowed?(site) do
      event
      |> Map.put("site", site)
      |> Map.put_new_lazy("at", &now/0)
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] or v == %{} end)
      |> Map.new()
      |> Buffer.push()
    end

    :ok
  end

  def push(_event), do: :ok

  defp site_allowed?(site) do
    case setting(:sites) do
      sites when is_list(sites) and sites != [] ->
        Enum.any?(sites, &(String.downcase(to_string(&1)) == site))

      _ ->
        true
    end
  end

  @doc false
  def now do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  @doc false
  # The visitor's fields from a request or a socket, without kind.
  def context(%{__struct__: Plug.Conn} = conn) do
    SauronReporter.Analytics.Plug.context(conn)
  end

  def context(%{__struct__: Phoenix.LiveView.Socket} = socket) do
    SauronReporter.Analytics.Hook.context(socket)
  end

  def context(meta) when is_list(meta), do: meta |> Map.new() |> context()

  def context(%{} = meta) do
    get = fn key -> Map.get(meta, key) || Map.get(meta, Atom.to_string(key)) end

    %{
      "site" => to_text(get.(:site)),
      "path" => path(get.(:path)),
      "ip" => to_text(get.(:ip)),
      "ua" => cut(to_text(get.(:ua)), 1_000),
      "user" => to_text(get.(:user)) || user_id(get.(:user_id))
    }
  end

  @doc false
  # The user of a request or a socket, hashed: `:sauron_user_id`, else
  # the `user_assign`'s id.
  def user_from_assigns(assigns) do
    id =
      case assigns[:sauron_user_id] do
        nil ->
          case setting(:user_assign) && assigns[setting(:user_assign)] do
            %{id: id} -> id
            _ -> nil
          end

        id ->
          id
      end

    user_id(id)
  end

  @doc false
  # The query's UTM parameters, cut at 200.
  def utm(query) when is_binary(query) and query != "" do
    decoded = URI.decode_query(query)
    for key <- @utm, value = to_text(decoded[key]), into: %{}, do: {key, cut(value, 200)}
  rescue
    _ -> %{}
  end

  def utm(_query), do: %{}

  @doc false
  # Only the referrer's host leaves the app: Sauron keeps no more, and a
  # query string carries tokens.
  def referrer_host(nil), do: nil

  def referrer_host(referrer) when is_binary(referrer) do
    case URI.parse(String.trim(referrer)) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc false
  def path(nil), do: nil

  def path(path) when is_binary(path) do
    path |> String.split(["?", "#"], parts: 2) |> hd() |> cut(1_000)
  end

  def path(_), do: nil

  @doc false
  def ip_to_string(nil), do: nil
  def ip_to_string(ip) when is_binary(ip), do: to_text(ip)

  def ip_to_string(ip) when is_tuple(ip) do
    ip |> :inet.ntoa() |> to_string()
  rescue
    _ -> nil
  end

  def ip_to_string(_), do: nil

  @doc false
  # The client's address from a forwarded chain, per `trust_forwarded`.
  def forwarded_ip(chain, mode) when is_binary(chain) do
    hops = chain |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    candidate =
      case mode do
        :first -> List.first(hops)
        _ -> List.last(hops)
      end

    with value when is_binary(value) <- candidate,
         {:ok, address} <- :inet.parse_address(String.to_charlist(value)) do
      address |> :inet.ntoa() |> to_string()
    else
      _ -> nil
    end
  end

  def forwarded_ip(_chain, _mode), do: nil

  @doc false
  def trust_forwarded(opts \\ []) do
    case Keyword.get(opts, :trust_forwarded, setting(:trust_forwarded, false)) do
      true -> :last
      :last -> :last
      :first -> :first
      _ -> false
    end
  end

  # ---------- props and text ----------

  @doc false
  # Plan 28's rule, applied before sending: the first ten keys by name
  # among those of at most 40 characters whose value is a string or a
  # number; strings cut at 200.
  def props(props) when is_list(props), do: props |> Map.new() |> props()

  def props(props) when is_map(props) do
    props
    |> Enum.flat_map(fn {key, value} ->
      key = to_text(key)

      value =
        cond do
          is_binary(value) -> (text = to_text(value)) && String.slice(text, 0, @prop_value)
          is_number(value) -> value
          is_atom(value) and not is_nil(value) -> Atom.to_string(value)
          true -> nil
        end

      if key && String.length(key) <= @prop_key && value != nil, do: [{key, value}], else: []
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(@max_props)
    |> Map.new()
  end

  def props(_), do: %{}

  @doc false
  def to_text(nil), do: nil
  def to_text(value) when is_binary(value), do: value |> String.trim() |> blank()
  def to_text(value) when is_atom(value), do: value |> Atom.to_string() |> to_text()
  def to_text(value) when is_integer(value), do: Integer.to_string(value)
  def to_text(_), do: nil

  defp blank(""), do: nil
  defp blank(value), do: value

  @doc false
  def cut(nil, _max), do: nil
  def cut(value, max) when is_binary(value), do: String.slice(value, 0, max)

  @doc false
  def debug(exception) do
    require Logger
    Logger.debug("sauron analytics: #{Exception.message(exception)}")
    :ok
  end
end
