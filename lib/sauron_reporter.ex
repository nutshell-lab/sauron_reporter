defmodule SauronReporter do
  @moduledoc """
  Sends an app's errors to Sauron, the fleet's error manager (sauron's
  plan 18). One library for every Elixir app of the fleet, Sauron
  included, so the contract is written once.

  ErrorTracker captures in the app (its Phoenix, LiveView and Oban hooks)
  and keeps a short local copy, the buffer when Sauron is away; its
  dashboard need not be mounted. The reporter attaches to
  `[:error_tracker, :occurrence, :new]` and sends each occurrence: its
  reason, stack trace and an allowlisted context. A group that fires in
  a loop sends at most five a minute; the rest are counted and the count
  rides on the next report (`dropped`), so Sauron's total stays true.

  Each report is built and sent from a task under
  `SauronReporter.TaskSupervisor`, so the erroring process never waits.
  A failure logs at debug and never raises. Both run in this library's
  own application: an app adds the dependency and configures it, nothing
  in its supervision tree.

      config :sauron_reporter,
        url: "https://sauron.nutshell-lab.com",  # SAURON_URL
        token: "...",                            # SAURON_REPORT_TOKEN, a secret
        app: "m2-app",                           # the app's name in Sauron
        otp_apps: [:m2],                         # whose frames are "the app's"
        # optional:
        version_app: :m2,                        # whose vsn is release.version (default: the last of otp_apps)
        redact: {M2.Redactor, :reason},          # fun(reason) -> reason, after the email mask
        self_noise: ["M2.Observability."],       # more modules whose errors never report
        ignore: [{"MyApp.ClientError", ~r/LiveView not connected/}], # {kind, reason regex}, or a kind alone
        deliver: nil,                            # or {mod, fun}(app, payload): in-process, Sauron's own
        req_options: []                          # tests inject a Req.Test plug

  What the client caused is not reported (0.4.0): an exception whose HTTP
  status (`Plug.Exception`) is below 500 — a 404 `NotFound`, a 400 from
  Bandit on a client's timeout — and `Bandit.TransportError`, a client
  that closed its connection. ErrorTracker still keeps them in the app.
  `ignore` adds an app's own (kinds, with a pattern on the reason or not).

  Inert unless `app` is set and either `url` and `token` or `deliver`:
  the configuration is read when the application starts, so it belongs
  in `config/runtime.exs`, set only when the token is there.

  What leaves the app: kind, reason (emails masked, then the app's
  `redact`), source, stack trace and these context keys only: request
  method, host and path; the LiveView, its event and component; the Oban
  worker, queue, attempt and job id; the release version and node. Never
  query strings, IPs, headers, params, event params or job arguments.
  Sauron enforces the same list on arrival.
  """

  use GenServer

  require Logger

  @event [:error_tracker, :occurrence, :new]
  @per_minute 5
  @table __MODULE__.Throttle
  @context_keys ~w(
    request.method request.host request.path
    live_view.view live_view.event live_view.component
    job.worker job.queue job.attempt job.id
  )
  @max_frames 40

  # Errors from these never report: a failed report would otherwise report
  # itself, and fail again. An app adds its own (`self_noise`) — Sauron
  # its error manager and endpoint. ErrorTracker spells modules without
  # `Elixir.`; both spellings are matched.
  @self_noise ["SauronReporter"]

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    if configured?(), do: :telemetry.attach(__MODULE__, @event, &__MODULE__.handle_event/4, nil)
    {:ok, nil}
  end

  @impl GenServer
  def terminate(_reason, _state), do: :telemetry.detach(__MODULE__)

  @doc "Whether an app is set, and a URL and token or an in-process delivery."
  def configured? do
    config = config()

    config[:app] not in [nil, ""] and
      (match?({_, _}, config[:deliver]) or
         (config[:url] not in [nil, ""] and config[:token] not in [nil, ""]))
  end

  @doc false
  def handle_event(@event, _measurements, %{error: error, occurrence: occurrence}, _config) do
    if not self_noise?(error) and not client_caused?(error, occurrence) do
      case take(error.fingerprint) do
        {:send, dropped} ->
          Task.Supervisor.start_child(__MODULE__.TaskSupervisor, fn ->
            deliver(payload(error, occurrence, dropped))
          end)

        :counted ->
          :ok
      end
    end

    :ok
  rescue
    exception ->
      Logger.debug("sauron reporter: #{Exception.message(exception)}")
      :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @doc "Sends one payload, over HTTP or in-process. Never raises."
  def deliver(payload) do
    config = config()

    case config[:deliver] do
      {module, function} ->
        apply(module, function, [config[:app], payload])

      nil ->
        Req.post(
          [
            url: String.trim_trailing(config[:url], "/") <> "/report/errors",
            json: payload,
            auth: {:bearer, config[:token]},
            retry: false,
            connect_options: [timeout: 3_000],
            receive_timeout: 5_000
          ]
          |> Keyword.merge(config[:req_options] || [])
        )
    end
    |> tap(fn
      {:ok, %Req.Response{status: 202}} -> :ok
      {:ok, _group, _alert} -> :ok
      other -> Logger.debug("sauron reporter: #{inspect(other, limit: 5)}")
    end)
  rescue
    exception ->
      Logger.debug("sauron reporter: #{Exception.message(exception)}")
      {:error, exception}
  end

  @doc "The report for one occurrence: string keys, JSON-ready."
  def payload(error, occurrence, dropped \\ 0) do
    config = config()
    otp_apps = otp_apps(config)

    %{
      "fingerprint" => error.fingerprint,
      "kind" => cut(error.kind, 200),
      "reason" => (occurrence.reason || error.reason) |> reason(config) |> cut(2_000),
      "source_function" => cut(error.source_function, 300),
      "source_line" => cut(error.source_line, 300),
      "occurred_at" => DateTime.to_iso8601(occurrence.inserted_at || DateTime.utc_now()),
      "stacktrace" => frames(occurrence, otp_apps),
      "context" => context(occurrence.context, config[:version_app] || List.last(otp_apps)),
      "dropped" => dropped
    }
  end

  # `otp_app` (one) was the single-app spelling; both are accepted.
  defp otp_apps(config), do: List.wrap(config[:otp_apps] || config[:otp_app])

  # A reason can quote a value (a changeset error, a constraint message);
  # an email address is the one identity that commonly shows up, masked
  # for every app. Then the app's own redactor, if it has more to hide.
  defp reason(nil, _config), do: ""

  defp reason(reason, config) do
    masked = String.replace(reason, ~r/[\w.+-]+@[\w-]+(\.[\w-]+)+/u, "[email]")

    case config[:redact] do
      {module, function} -> apply(module, function, [masked])
      nil -> masked
    end
  end

  defp frames(%{stacktrace: %{lines: lines}}, otp_apps) when is_list(lines) do
    apps = Enum.map(otp_apps, &to_string/1)

    lines
    |> Enum.take(@max_frames)
    |> Enum.map(fn line ->
      %{
        "file" => line.file,
        "line" => line.line,
        "module" => line.module && String.replace_prefix(line.module, "Elixir.", ""),
        "function" => line.function,
        "arity" => line.arity,
        "app" => line.application in apps,
        "application" => line.application
      }
    end)
  end

  defp frames(_occurrence, _otp_apps), do: []

  defp context(context, version_app) do
    kept =
      for {k, v} <- context || %{},
          k in @context_keys,
          is_binary(v) or is_integer(v),
          into: %{} do
        {k, if(is_binary(v), do: cut(v, 300), else: v)}
      end

    version = version_app && Application.spec(version_app, :vsn)

    kept
    |> Map.put("node", to_string(node()))
    |> then(&if(version, do: Map.put(&1, "release.version", to_string(version)), else: &1))
  end

  defp self_noise?(%{source_function: f}) when is_binary(f) do
    f = String.replace_prefix(f, "Elixir.", "")
    Enum.any?(@self_noise ++ (config()[:self_noise] || []), &String.starts_with?(f, &1))
  end

  defp self_noise?(_), do: false

  # The client closed its connection: nothing the app did, nothing to fix.
  @client_kinds ["Bandit.TransportError"]

  @doc false
  def client_caused?(error, occurrence) do
    kind = String.replace_prefix(error.kind || "", "Elixir.", "")
    reason = occurrence.reason || error.reason || ""

    kind in @client_kinds or below_500?(kind) or
      Enum.any?(config()[:ignore] || [], &ignored?(&1, kind, reason))
  end

  defp ignored?({k, %Regex{} = pattern}, kind, reason), do: short(k) == kind and reason =~ pattern
  defp ignored?(k, kind, _reason) when is_binary(k) or is_atom(k), do: short(k) == kind
  defp ignored?(_, _kind, _reason), do: false

  defp short(k), do: k |> to_string() |> String.replace_prefix("Elixir.", "")

  # The status Phoenix answers an exception with, from its kind alone (an
  # occurrence keeps no struct): below 500 is the client's request, not a
  # failure. An exception whose status cannot be read so is reported.
  defp below_500?(kind) do
    module = Module.concat([kind])

    Code.ensure_loaded?(Plug.Exception) and Code.ensure_loaded?(module) and
      function_exported?(module, :__struct__, 0) and
      Plug.Exception.status(struct(module)) < 500
  rescue
    _ -> false
  end

  # At most @per_minute sends per group and minute; the rest are counted
  # and ride on the next send.
  defp take(fingerprint) do
    minute = System.monotonic_time(:second) |> div(60)

    case :ets.lookup(@table, fingerprint) do
      [{_, ^minute, sent, dropped}] when sent >= @per_minute ->
        :ets.insert(@table, {fingerprint, minute, sent, dropped + 1})
        :counted

      [{_, ^minute, sent, dropped}] ->
        :ets.insert(@table, {fingerprint, minute, sent + 1, 0})
        {:send, dropped}

      [{_, _older, _sent, dropped}] ->
        :ets.insert(@table, {fingerprint, minute, 1, 0})
        {:send, dropped}

      [] ->
        :ets.insert(@table, {fingerprint, minute, 1, 0})
        {:send, 0}
    end
  end

  defp cut(nil, _max), do: nil

  defp cut(s, max) when is_binary(s),
    do: if(String.length(s) > max, do: String.slice(s, 0, max - 1) <> "…", else: s)

  defp config, do: Application.get_all_env(:sauron_reporter)
end
