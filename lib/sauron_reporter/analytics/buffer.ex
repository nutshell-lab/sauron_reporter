defmodule SauronReporter.Analytics.Buffer do
  @moduledoc """
  Holds an app's analytics events and sends them to Sauron's
  `POST /report/events` in batches: every `flush_every` ms (5 s), or as
  soon as `batch_size` (50) wait. One send at a time, from a task, so a
  slow Sauron never holds the buffer; each carries at most
  #{200} events (Sauron refuses 500, or 512 KB).

  Beyond `max_buffer` (5 000) the oldest event is dropped and counted;
  a batch Sauron does not take (an error, a timeout, any status but 202)
  is dropped and counted, never retried — an hour without Sauron costs
  that hour's events, never the app's memory or time. Sauron's own
  `dropped` (events refused one by one) is counted too.

  Started by the library's application, inert while analytics is not
  enabled: `push/1` is a cast, ignored until then.
  """

  use GenServer

  require Logger

  alias SauronReporter.Analytics

  @max_post 200

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Queues one event (a string-keyed map). Never blocks, never raises."
  def push(event) do
    GenServer.cast(__MODULE__, {:push, event})
  end

  @doc "Sends everything that waits, in this call. `:ok` whatever happens."
  def flush do
    GenServer.call(__MODULE__, :flush, 30_000)
  catch
    :exit, _ -> :ok
  end

  @doc "Counters since boot."
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, _ -> %{sent: 0, dropped: 0, failed: 0, buffered: 0}
  end

  # ---------- server ----------

  @impl GenServer
  def init(_opts) do
    # So terminate/2 runs on a clean shutdown and what waits is sent.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       queue: :queue.new(),
       size: 0,
       timer: nil,
       in_flight: nil,
       sent: 0,
       dropped: 0,
       failed: 0
     }}
  end

  @impl GenServer
  def handle_cast({:push, event}, state) do
    state =
      if state.size >= max_buffer() do
        {_oldest, queue} = :queue.out(state.queue)
        telemetry(:dropped, 1, %{reason: :buffer_full})
        %{state | queue: queue, size: state.size - 1, dropped: state.dropped + 1}
      else
        state
      end

    state = %{state | queue: :queue.in(event, state.queue), size: state.size + 1}

    if state.size >= batch_size(),
      do: {:noreply, send_batch(state)},
      else: {:noreply, ensure_timer(state)}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    {:reply, :ok, drain(cancel_timer(state))}
  end

  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:sent, :dropped, :failed]) |> Map.put(:buffered, state.size), state}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    {:noreply, send_batch(%{state | timer: nil})}
  end

  def handle_info({ref, result}, %{in_flight: {ref, count}} = state) do
    Process.demonitor(ref, [:flush])
    state = account(%{state | in_flight: nil}, count, result)
    {:noreply, next(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{in_flight: {ref, count}} = state) do
    state = account(%{state | in_flight: nil}, count, {:error, reason})
    {:noreply, next(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if Analytics.enabled?(), do: drain(state)
    :ok
  end

  # ---------- sending ----------

  # A send from a task: one at a time; the next waits for its answer.
  defp send_batch(%{in_flight: {_, _}} = state), do: state
  defp send_batch(%{size: 0} = state), do: cancel_timer(state)

  defp send_batch(state) do
    state = cancel_timer(state)

    if Analytics.enabled?() do
      {events, state} = take(state)
      app = app()

      task =
        Task.Supervisor.async_nolink(SauronReporter.TaskSupervisor, fn ->
          deliver(app, %{"events" => events})
        end)

      %{state | in_flight: {task.ref, length(events)}}
    else
      # Switched off with events waiting: forgotten, not counted.
      %{state | queue: :queue.new(), size: 0}
    end
  end

  defp next(state) do
    cond do
      state.size >= batch_size() -> send_batch(state)
      state.size > 0 -> ensure_timer(state)
      true -> state
    end
  end

  # Everything, in this process: a flush, a shutdown.
  defp drain(%{size: 0} = state), do: state

  defp drain(state) do
    if Analytics.enabled?() do
      {events, state} = take(state)
      count = length(events)
      state = account(state, count, deliver(app(), %{"events" => events}))
      drain(state)
    else
      %{state | queue: :queue.new(), size: 0}
    end
  end

  defp take(state) do
    n = min(state.size, @max_post)
    {taken, rest} = :queue.split(n, state.queue)
    {:queue.to_list(taken), %{state | queue: rest, size: state.size - n}}
  end

  @doc false
  # Over HTTP, or in-process with `deliver: {mod, fun}`. Never raises.
  def deliver(app, payload) do
    reporter = Application.get_all_env(:sauron_reporter)
    config = reporter[:analytics] || []

    case config[:deliver] do
      {module, function} ->
        apply(module, function, [app, payload])

      nil ->
        Req.post(
          [
            url: String.trim_trailing(reporter[:url], "/") <> "/report/events",
            json: payload,
            auth: {:bearer, reporter[:token]},
            retry: false,
            connect_options: [timeout: 3_000],
            receive_timeout: 5_000
          ]
          |> Keyword.merge(config[:req_options] || reporter[:req_options] || [])
        )
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # What a send's answer says: accepted and refused one by one, or the
  # whole batch lost.
  defp account(state, count, result) do
    case accepted(result, count) do
      {:ok, accepted, refused} ->
        telemetry(:sent, accepted, %{dropped: refused})
        if refused > 0, do: telemetry(:dropped, refused, %{reason: :rejected})
        %{state | sent: state.sent + accepted, dropped: state.dropped + refused}

      {:error, reason} ->
        Logger.debug("sauron analytics: #{count} event(s) lost: #{inspect(reason, limit: 5)}")
        telemetry(:failed, count, %{reason: reason})
        %{state | failed: state.failed + count}
    end
  end

  defp accepted({:ok, %{__struct__: Req.Response, status: 202, body: body}}, count),
    do: counts(body, count)

  defp accepted({:ok, %{__struct__: Req.Response, status: status}}, _count),
    do: {:error, status}

  defp accepted({:ok, %{} = counts}, count), do: counts(counts, count)
  defp accepted(:ok, count), do: {:ok, count, 0}
  defp accepted({:error, reason}, _count), do: {:error, short(reason)}
  defp accepted(other, _count), do: {:error, other}

  defp counts(body, count) when is_map(body) do
    get = fn key -> Map.get(body, key) || Map.get(body, Atom.to_string(key)) end

    case {get.(:accepted), get.(:dropped)} do
      {a, d} when is_integer(a) and is_integer(d) -> {:ok, a, d}
      {a, _} when is_integer(a) -> {:ok, a, max(count - a, 0)}
      _ -> {:ok, count, 0}
    end
  end

  defp counts(_body, count), do: {:ok, count, 0}

  defp short(%{__exception__: true} = exception), do: exception.__struct__
  defp short(reason), do: reason

  defp telemetry(event, count, metadata) do
    :telemetry.execute(
      [:sauron_reporter, :analytics, event],
      Map.merge(%{count: count}, Map.take(metadata, [:dropped])),
      metadata |> Map.drop([:dropped]) |> Map.put(:app, app())
    )
  end

  # ---------- timer and settings ----------

  defp ensure_timer(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :flush, flush_every())}

  defp ensure_timer(state), do: state

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp app, do: Application.get_env(:sauron_reporter, :app)
  defp flush_every, do: positive(Analytics.setting(:flush_every), 5_000)
  defp batch_size, do: positive(Analytics.setting(:batch_size), 50)
  defp max_buffer, do: positive(Analytics.setting(:max_buffer), 5_000)

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
