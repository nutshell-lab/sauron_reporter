defmodule SauronReporter.Analytics.Units do
  @moduledoc """
  Where a slow answer spends its time (sauron's plan 45, 0.10.0).

  A **unit** is what the app answers in one go: an HTTP request (the
  plug's timing) or, with `live_timings: true`, a LiveView's connected
  mount, a `handle_params` or a `handle_event` (a LiveComponent's too).
  While a unit runs, every query of the app's repos (`repos:`, Ecto's
  `[..., :query]` telemetry) adds to its totals — time in the database
  (query and decode), time waiting for a connection (queue), how many —
  and to a summary per statement. The unit's timing carries the totals
  (`db_ms`, `db_queue_ms`, `queries`); a unit of `slow_ms` (500) or more
  also writes, to the app's log, one line per statement that was slow
  (`statement_ms`, 100, in one run) or repeated (`repeated`, 10 times):

      sauron.slow_statement phase=http route="/competitions/:competition_id/schedule"
        request_id=F8k… answer_ms=15836 fingerprint=3fa2c1b04e7d count=48
        query_ms=3120 max_ms=210 queue_ms=40 statement="SELECT h0.id … WHERE (h0.stage_id = $1)"

  The statement is Ecto's: placeholders, never a parameter; cut at 1,000
  characters. At most #{10} lines a unit, the heaviest first.

  **Whose query.** Ecto's event fires in the process that ran the query:
  the unit's own, or a task it started (`Task.async`, a parallel
  preload, `start_async`), which carries the unit's process in
  `$callers`. A task counts for the unit that was running at its first
  query, and only while that unit runs: one outliving its callback is
  never billed to the next. A process serves many units — a LiveView,
  a keep-alive connection — so a unit's start forgets the one before.
  Queries outside any unit (`handle_info`, `handle_async`, Oban jobs)
  are not counted: LiveView emits no telemetry around those.

  **Transactions**: `begin` and `commit` are statements like any; the
  wait for a connection is on the checkout, the first query only.

  The units live in an ETS table this process owns. A unit whose
  process died, or older than five minutes, is swept every minute: a
  request that crashed costs nothing for long.
  """

  use GenServer

  require Logger

  alias SauronReporter.Analytics

  @table __MODULE__
  @sweep_every 60_000
  @stale_ms 300_000
  @max_statements 200
  @max_lines 10
  @statement_chars 1_000
  @handler_repo "sauron-reporter-units-repo"
  @handler_live "sauron-reporter-units-live"

  @live_events for name <- [
                     [:phoenix, :live_view, :mount],
                     [:phoenix, :live_view, :handle_params],
                     [:phoenix, :live_view, :handle_event],
                     [:phoenix, :live_component, :handle_event]
                   ],
                   stage <- [:start, :stop, :exception],
                   do: name ++ [stage]

  # ---------- the process ----------

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    attach()
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_every)

  @doc false
  # Units of dead processes, or older than five minutes.
  def sweep(now \\ System.monotonic_time(:millisecond)) do
    for {{:unit, pid}, gen, started, _, _, _, _, _} <- :ets.tab2list(@table),
        not Process.alive?(pid) or now - started > @stale_ms,
        do: forget(pid, gen)

    :ok
  end

  @doc """
  Attaches to the configured repos' queries and, with `live_timings`,
  to LiveView's callbacks — again, with the configuration as it is now.
  Done at start; a test calls it after configuring.
  """
  def attach do
    detach()

    case Enum.map(repos(), &(prefix(&1) ++ [:query])) do
      [] -> :ok
      events -> :telemetry.attach_many(@handler_repo, events, &__MODULE__.query/4, nil)
    end

    if Analytics.setting(:live_timings, false),
      do: :telemetry.attach_many(@handler_live, @live_events, &__MODULE__.live/4, nil)

    :ok
  end

  @doc "Detaches from everything `attach/0` attached to."
  def detach do
    :telemetry.detach(@handler_repo)
    :telemetry.detach(@handler_live)
    :ok
  end

  defp repos, do: List.wrap(Analytics.setting(:repos, []))

  # A repo's telemetry prefix: its own, else Ecto's default from its name.
  defp prefix(prefix) when is_list(prefix), do: prefix

  defp prefix(repo) when is_atom(repo) do
    configured =
      try do
        if function_exported?(repo, :config, 0), do: repo.config()[:telemetry_prefix]
      rescue
        _ -> nil
      end

    configured ||
      repo |> Module.split() |> Enum.map(&(&1 |> Macro.underscore() |> String.to_atom()))
  end

  @doc "Whether queries are followed: analytics on and a repo configured."
  def tracking?, do: Analytics.enabled?() and repos() != [] and table?()

  defp table?, do: :ets.whereis(@table) != :undefined

  # ---------- a unit ----------

  @doc "Starts the calling process's unit, forgetting the one before."
  def start do
    if tracking?() do
      pid = self()

      case :ets.lookup(@table, {:unit, pid}) do
        [{_, gen, _, _, _, _, _, _}] -> forget(pid, gen)
        [] -> :ok
      end

      gen = make_ref()
      :ets.insert(@table, {{:unit, pid}, gen, System.monotonic_time(:millisecond), 0, 0, 0, 0, 0})
      gen
    end
  rescue
    exception -> Analytics.debug(exception)
  end

  @doc """
  Ends the calling process's unit: `%{db_ms, db_queue_ms, queries,
  statements: [%{fingerprint, statement, count, query_ms, max_ms,
  queue_ms}], overflow}`, or nil when none ran.
  """
  def stop do
    pid = self()

    with true <- table?(),
         [{_, gen, _, db, queue, queries, _, overflow}] <- :ets.lookup(@table, {:unit, pid}) do
      statements =
        for {{:stmt, ^pid, ^gen, fingerprint}, count, query, max, q, statement} <-
              :ets.match_object(@table, {{:stmt, pid, gen, :_}, :_, :_, :_, :_, :_}) do
          %{
            fingerprint: fingerprint,
            statement: statement,
            count: count,
            query_ms: ms(query),
            max_ms: ms(max),
            queue_ms: ms(q)
          }
        end

      forget(pid, gen)

      %{
        db_ms: ms(db),
        db_queue_ms: ms(queue),
        queries: queries,
        statements: statements,
        overflow: overflow
      }
    else
      _ -> nil
    end
  rescue
    exception ->
      Analytics.debug(exception)
      nil
  end

  defp forget(pid, gen) do
    :ets.match_delete(@table, {{:stmt, pid, gen, :_}, :_, :_, :_, :_, :_})
    :ets.match_delete(@table, {{:unit, pid}, gen, :_, :_, :_, :_, :_, :_})
    :ok
  end

  @doc "The fields a timing gains from a stopped unit."
  def timing_fields(nil), do: %{}

  def timing_fields(unit),
    do: %{"db_ms" => unit.db_ms, "db_queue_ms" => unit.db_queue_ms, "queries" => unit.queries}

  # ---------- the queries ----------

  @doc false
  def query(_event, measurements, metadata, _config) do
    with true <- table?(),
         {owner, gen} <- owner() do
      query_t = (measurements[:query_time] || 0) + (measurements[:decode_time] || 0)
      queue_t = measurements[:queue_time] || 0
      :ets.update_counter(@table, {:unit, owner}, [{4, query_t}, {5, queue_t}, {6, 1}])

      case metadata[:query] do
        statement when is_binary(statement) -> statement(owner, gen, statement, query_t, queue_t)
        _ -> :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  # The unit this query counts for: the process's own, else the first of
  # its callers that runs one — pinned at the task's first query.
  defp owner do
    pid = self()

    case :ets.lookup(@table, {:unit, pid}) do
      [{_, gen, _, _, _, _, _, _}] ->
        {pid, gen}

      [] ->
        Enum.find_value(Process.get(:"$callers", []), fn caller ->
          case :ets.lookup(@table, {:unit, caller}) do
            [{_, gen, _, _, _, _, _, _}] -> pinned(caller, gen)
            [] -> nil
          end
        end)
    end
  end

  defp pinned(caller, gen) do
    case Process.get({__MODULE__, caller}) do
      nil ->
        Process.put({__MODULE__, caller}, gen)
        {caller, gen}

      ^gen ->
        {caller, gen}

      _other_unit ->
        nil
    end
  end

  defp statement(owner, gen, statement, query_t, queue_t) do
    key = {:stmt, owner, gen, fingerprint(statement)}
    new = {key, 0, 0, 0, 0, String.slice(statement, 0, @statement_chars)}

    kept? =
      cond do
        :ets.member(@table, key) ->
          true

        :ets.update_counter(@table, {:unit, owner}, {7, 1}) > @max_statements ->
          :ets.update_counter(@table, {:unit, owner}, {8, 1})
          false

        true ->
          :ets.insert_new(@table, new) or true
      end

    if kept? do
      [_, _, max] = :ets.update_counter(@table, key, [{2, 1}, {3, query_t}, {4, 0}])
      if query_t > max, do: :ets.update_element(@table, key, {4, query_t})
      :ets.update_counter(@table, key, {5, queue_t})
    end
  end

  defp fingerprint(statement),
    do: :crypto.hash(:sha256, statement) |> binary_part(0, 6) |> Base.encode16(case: :lower)

  defp ms(native),
    do: Float.round(System.convert_time_unit(native, :native, :microsecond) / 1_000, 2)

  # ---------- LiveView's callbacks ----------

  @doc false
  def live([_, _, _callback, :start], _measurements, %{socket: socket}, _config) do
    if timed?(socket), do: start()
    :ok
  rescue
    _ -> :ok
  end

  def live([_, _, callback, stage], measurements, %{socket: socket} = metadata, _config)
      when stage in [:stop, :exception] do
    if timed?(socket) do
      unit = stop()
      duration_ms = ms(measurements[:duration] || 0)
      status = if stage == :exception, do: 500, else: 200
      phase = phase(callback)
      context = live_context(socket, metadata)

      if context && not Analytics.ignored_path?(context["path"]) do
        name = if phase == "event", do: Analytics.cut(to_string(metadata[:event]), 100)

        Analytics.push(
          context
          |> Map.merge(%{
            "kind" => "timing",
            "phase" => phase,
            "name" => name,
            "status" => status,
            "duration_ms" => Float.round(duration_ms, 2)
          })
          |> Map.merge(timing_fields(unit))
        )

        log_slow(unit, duration_ms, %{
          "phase" => phase,
          "route" => context["route"],
          "live_view" => inspect(socket.view),
          "event" => name,
          "unit_id" => unit_id()
        })
      end
    end

    :ok
  rescue
    exception -> Analytics.debug(exception)
  end

  def live(_event, _measurements, _metadata, _config), do: :ok

  defp phase(:mount), do: "mount"
  defp phase(:handle_params), do: "params"
  defp phase(:handle_event), do: "event"

  # The connected callbacks only: the disconnected mount is the HTTP
  # request's, which the plug times.
  defp timed?(%{transport_pid: pid}) when is_pid(pid),
    do: Analytics.enabled?() and Analytics.setting(:live_timings, false) == true

  defp timed?(_socket), do: false

  # The page the callback ran on: the hook's last page, else the uri
  # LiveView gave; the visitor as the hook read it at mount.
  defp live_context(socket, metadata) do
    hook = SauronReporter.Analytics.Hook.context(socket)
    uri = uri(metadata[:uri]) || uri(socket.host_uri)
    host = hook["site"] || (uri && uri.host)
    path = hook["path"] || Analytics.path(uri && uri.path)

    if is_binary(host) do
      %{
        "site" => host,
        "path" => path,
        "route" => route(socket, path, host),
        "ip" => hook["ip"],
        "ua" => hook["ua"],
        "user" => hook["user"]
      }
    end
  end

  defp uri(%URI{} = uri), do: uri
  defp uri(url) when is_binary(url), do: URI.parse(url)
  defp uri(_), do: nil

  defp route(%{router: router}, path, host) when is_atom(router) and not is_nil(router) do
    case Phoenix.Router.route_info(router, "GET", path || "/", host) do
      %{route: route} when is_binary(route) -> Analytics.cut(route, 300)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp route(_socket, _path, _host), do: nil

  defp unit_id, do: "lv-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

  # ---------- the slow statements, to the log ----------

  @doc """
  Writes the slow and repeated statements of a unit that took
  `duration_ms` (see the moduledoc); `fields` name the unit.
  """
  def log_slow(nil, _duration_ms, _fields), do: :ok

  def log_slow(unit, duration_ms, fields) do
    if duration_ms >= Analytics.setting(:slow_ms, 500) do
      statement_ms = Analytics.setting(:statement_ms, 100)
      repeated = Analytics.setting(:repeated, 10)

      worth =
        unit.statements
        |> Enum.filter(&(&1.max_ms >= statement_ms or &1.count >= repeated))
        |> Enum.sort_by(& &1.query_ms, :desc)

      head =
        fields
        |> Map.put("answer_ms", round(duration_ms))
        |> Map.put_new("request_id", Logger.metadata()[:request_id])
        |> line(~w(phase route live_view event request_id unit_id answer_ms))

      for s <- Enum.take(worth, @max_lines) do
        Logger.info(
          "sauron.slow_statement " <>
            head <>
            " fingerprint=#{s.fingerprint} count=#{s.count} query_ms=#{round(s.query_ms)}" <>
            " max_ms=#{round(s.max_ms)} queue_ms=#{round(s.queue_ms)}" <>
            " statement=#{inspect(s.statement, printable_limit: :infinity)}"
        )
      end

      if length(worth) > @max_lines or unit.overflow > 0 do
        Logger.info(
          "sauron.slow_statement " <>
            head <>
            " more=#{max(length(worth) - @max_lines, 0)} statements_over_cap=#{unit.overflow}"
        )
      end
    end

    :ok
  rescue
    exception -> Analytics.debug(exception)
  end

  defp line(fields, order) do
    order
    |> Enum.flat_map(fn key ->
      case fields[key] do
        nil -> []
        value when is_binary(value) -> ["#{key}=#{quote_value(value)}"]
        value -> ["#{key}=#{value}"]
      end
    end)
    |> Enum.join(" ")
  end

  defp quote_value(value) do
    if String.match?(value, ~r/\A[A-Za-z0-9_.:\-]+\z/), do: value, else: inspect(value)
  end
end
