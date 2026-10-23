defmodule SauronReporter.Support.Client do
  @moduledoc """
  The app's one link to Sauron's support (plan 29): a WebSocket to
  `/support/socket/websocket` (Phoenix's protocol, `vsn=2.0.0`), the
  report token in the `x-sauron-token` header, joined to
  `support:<app>`. One per app node, started by the library's
  application; inert (it never connects) while support is not enabled
  when it starts.

  **Calls.** `call/3` pushes an event and waits for Sauron's reply. While
  the link is down a call waits in a buffer — at most `max_buffer`
  (500) of them, each at most `buffer_ttl` (30 s) — and is pushed, in
  order, as soon as the channel is joined again; past its time it
  answers `{:error, :disconnected}`, and a call beyond the bound
  `{:error, :buffer_full}` at once. A call pushed whose reply does not
  come within `call_timeout` (10 s) answers `{:error, :timeout}`; one
  pushed when the link drops answers `{:error, :disconnected}` — it may
  or may not have reached Sauron, so it is never pushed twice.

  **Casts** (`typing`, `read`) are pushed when the link is up and
  dropped otherwise: they are worth nothing late.

  **Presence.** `present/3` and `absent/2` say a user's screen (a
  process, monitored) shows a conversation: Sauron is told `present:
  true` (with the page) for the first and on each page change, `false`
  when the last one goes — and every presence is said again after a
  reconnection.

  **Events.** Every event Sauron pushes is broadcast on the app's own
  PubSub — `Phoenix.PubSub.local_broadcast/3`, since each node's client
  receives every event of the app — as `{SauronReporter.Support,
  %SauronReporter.Support.Event{}}` on `sauron_support:user:<user_id>`
  and `sauron_support:conversation:<id>`. The link's changes go on
  `sauron_support:link` as `{SauronReporter.Support, :link, :up |
  :down}`.

  Reconnects with backoff (`reconnect_after_msec`, by default from 100
  ms up to 30 s), rejoins the same way. Never raises into a caller: a
  dead or busy client answers `{:error, :unavailable}`.

  Telemetry, each with `%{app: app}` in metadata:

    * `[:sauron_reporter, :support, :connected]` — joined;
    * `[:sauron_reporter, :support, :disconnected]` — the link or the
      channel lost (`reason`);
    * `[:sauron_reporter, :support, :dropped]` — a call answered
      without Sauron (`count`, `reason`: `:buffer_full`, `:expired`,
      `:timeout`, `:disconnected`).
  """

  use Slipstream

  require Logger

  alias SauronReporter.Support
  alias SauronReporter.Support.Event

  @sweep_every 1_000

  @doc false
  def start_link(opts \\ []) do
    Slipstream.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Pushes `event` with `payload` and waits for the reply: `{:ok, map}`
  or `{:error, reason}` — Sauron's reason as an atom (`:not_found`,
  `:over`, `:not_allowed`, `:rate_limited`, `:unknown_event`,
  `{:invalid, detail}`), or the link's (`:disabled`, `:disconnected`,
  `:timeout`, `:buffer_full`, `:unavailable`).
  """
  def call(event, payload, server \\ __MODULE__) do
    # The client answers every call itself within its buffer's and its
    # reply's times; this is the margin over both.
    GenServer.call(
      server,
      {:call, event, payload},
      Support.setting(:buffer_ttl, 30_000) + Support.setting(:call_timeout, 10_000) + 5_000
    )
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Pushes `event` when the link is up, forgets it otherwise. Always `:ok`."
  def cast(event, payload, server \\ __MODULE__) do
    GenServer.cast(server, {:cast, event, payload})
  end

  @doc "The calling process shows `conversation_id`, on `page`."
  def present(conversation_id, page, pid \\ self(), server \\ __MODULE__) do
    GenServer.cast(server, {:present, conversation_id, page, pid})
  end

  @doc "The calling process no longer shows `conversation_id`."
  def absent(conversation_id, pid \\ self(), server \\ __MODULE__) do
    GenServer.cast(server, {:absent, conversation_id, pid})
  end

  @doc "`%{status: :idle | :connecting | :joined, buffered: n, in_flight: n, present: n}`."
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> %{status: :down, buffered: 0, in_flight: 0, present: 0}
  end

  # ---------- the process ----------

  @impl Slipstream
  def init(_opts) do
    socket =
      new_socket()
      |> assign(
        status: :idle,
        app: nil,
        topic: nil,
        pubsub: nil,
        buffer: :queue.new(),
        buffered: 0,
        pending: %{},
        present: %{},
        sweep: nil,
        failures: 0
      )

    with true <- Support.enabled?(),
         {:ok, config} <- connection(),
         {:ok, socket} <- connect(socket, config) do
      app = Application.get_env(:sauron_reporter, :app)

      {:ok,
       assign(socket,
         status: :connecting,
         app: app,
         topic: "support:" <> app,
         pubsub: Support.setting(:pubsub)
       )}
    else
      false ->
        {:ok, socket}

      {:error, reason} ->
        Logger.warning("sauron support: not started: #{inspect(reason, limit: 5)}")
        {:ok, socket}
    end
  end

  defp connection do
    reporter = Application.get_all_env(:sauron_reporter)

    {:ok,
     [
       uri: Support.socket_url(),
       headers: [{"x-sauron-token", reporter[:token]}],
       reconnect_after_msec:
         Support.setting(:reconnect_after_msec, [100, 500, 1_000, 2_000, 5_000, 10_000, 30_000]),
       rejoin_after_msec:
         Support.setting(:rejoin_after_msec, [500, 1_000, 2_000, 5_000, 10_000, 30_000])
     ] ++ Keyword.take(Support.setting(:slipstream, []), [:mint_opts, :heartbeat_interval_msec])}
  rescue
    exception -> {:error, exception}
  end

  @impl Slipstream
  def handle_connect(socket) do
    {:ok, join(socket, socket.assigns.topic)}
  end

  @impl Slipstream
  def handle_join(_topic, _reply, socket) do
    if socket.assigns.failures > 0,
      do: Logger.info("sauron support: linked again to #{socket.assigns.topic}")

    telemetry(:connected, %{}, %{}, socket)
    broadcast_link(socket, :up)

    socket =
      socket
      |> assign(status: :joined, failures: 0)
      |> replay()
      |> announce_presence()

    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    socket = lost(socket, reason)

    case reconnect(socket) do
      {:ok, socket} -> {:ok, socket}
      {:error, _} -> {:ok, assign(socket, :status, :idle)}
    end
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    socket = lost(socket, reason)

    case rejoin(socket, topic) do
      {:ok, socket} -> {:ok, socket}
      {:error, _} -> {:ok, socket}
    end
  end

  @impl Slipstream
  def handle_message(_topic, event, payload, socket) when is_map(payload) do
    relay(socket, event, payload)
    {:ok, socket}
  end

  def handle_message(_topic, _event, _payload, socket), do: {:ok, socket}

  @impl Slipstream
  def handle_reply(ref, reply, socket) do
    case Map.pop(socket.assigns.pending, ref) do
      {{from, _deadline}, pending} ->
        GenServer.reply(from, answer(reply))
        {:ok, assign(socket, :pending, pending)}

      {nil, _} ->
        # A cast's reply, or a call already answered by its timeout.
        {:ok, socket}
    end
  end

  @impl Slipstream
  def handle_call({:call, _event, _payload}, _from, %{assigns: %{status: :idle}} = socket),
    do: {:reply, {:error, :disabled}, socket}

  def handle_call({:call, event, payload}, from, socket) do
    case socket.assigns.status == :joined && push_call(socket, event, payload, from) do
      {:ok, socket} ->
        {:noreply, ensure_sweep(socket)}

      _not_joined ->
        if socket.assigns.buffered >= positive(:max_buffer, 500) do
          telemetry(:dropped, %{count: 1}, %{reason: :buffer_full}, socket)
          {:reply, {:error, :buffer_full}, socket}
        else
          entry = {event, payload, from, now() + positive(:buffer_ttl, 30_000)}

          socket =
            assign(socket,
              buffer: :queue.in(entry, socket.assigns.buffer),
              buffered: socket.assigns.buffered + 1
            )

          {:noreply, ensure_sweep(socket)}
        end
    end
  end

  def handle_call(:status, _from, socket) do
    {:reply,
     %{
       status: socket.assigns.status,
       buffered: socket.assigns.buffered,
       in_flight: map_size(socket.assigns.pending),
       present: map_size(socket.assigns.present)
     }, socket}
  end

  @impl Slipstream
  def handle_cast({:cast, event, payload}, socket) do
    if socket.assigns.status == :joined, do: push(socket, socket.assigns.topic, event, payload)
    {:noreply, socket}
  end

  def handle_cast({:present, id, page, pid}, socket) when is_binary(id) do
    seats = Map.get(socket.assigns.present, id, %{})

    # Said when it changes: a new screen, or another page.
    {seats, changed?} =
      case seats do
        %{^pid => {_ref, ^page}} -> {seats, false}
        %{^pid => {ref, _page}} -> {Map.put(seats, pid, {ref, page}), true}
        _ -> {Map.put(seats, pid, {Process.monitor(pid), page}), true}
      end

    if changed?, do: say_presence(socket, id, true, page)
    {:noreply, assign(socket, :present, Map.put(socket.assigns.present, id, seats))}
  end

  def handle_cast({:absent, id, pid}, socket) when is_binary(id) do
    {:noreply, leave_seat(socket, id, pid)}
  end

  def handle_cast(_message, socket), do: {:noreply, socket}

  @impl Slipstream
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    socket =
      Enum.reduce(socket.assigns.present, socket, fn {id, seats}, socket ->
        if Map.has_key?(seats, pid), do: leave_seat(socket, id, pid), else: socket
      end)

    {:noreply, socket}
  end

  def handle_info(:sweep, socket) do
    {:noreply, socket |> assign(:sweep, nil) |> sweep() |> ensure_sweep()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Slipstream
  def terminate(_reason, socket) do
    if connected?(socket), do: disconnect(socket)
    :ok
  end

  # ---------- calls ----------

  defp push_call(socket, event, payload, from) do
    case push(socket, socket.assigns.topic, event, payload) do
      {:ok, ref} ->
        deadline = now() + positive(:call_timeout, 10_000)
        {:ok, assign(socket, :pending, Map.put(socket.assigns.pending, ref, {from, deadline}))}

      {:error, _reason} = error ->
        error
    end
  catch
    :exit, _ -> {:error, :push_failed}
  end

  # What waited for the link, in order. One that cannot be pushed now
  # (the link fell again) waits on.
  defp replay(socket) do
    {entries, socket} = take_buffer(socket)
    now = now()

    Enum.reduce(entries, socket, fn {event, payload, from, deadline} = entry, socket ->
      cond do
        deadline < now ->
          expire(socket, from, :expired)

        socket.assigns.status == :joined ->
          case push_call(socket, event, payload, from) do
            {:ok, socket} -> socket
            {:error, _} -> rebuffer(socket, entry)
          end

        true ->
          rebuffer(socket, entry)
      end
    end)
  end

  defp take_buffer(socket) do
    {:queue.to_list(socket.assigns.buffer), assign(socket, buffer: :queue.new(), buffered: 0)}
  end

  defp rebuffer(socket, entry) do
    assign(socket,
      buffer: :queue.in(entry, socket.assigns.buffer),
      buffered: socket.assigns.buffered + 1
    )
  end

  defp expire(socket, from, reason) do
    GenServer.reply(from, {:error, if(reason == :timeout, do: :timeout, else: :disconnected)})
    telemetry(:dropped, %{count: 1}, %{reason: reason}, socket)
    socket
  end

  # The link or the channel is gone: the calls in flight will never be
  # answered — and may or may not have reached Sauron.
  defp lost(socket, reason) do
    failures = socket.assigns.failures + 1

    if failures == 1 do
      Logger.warning("sauron support: link to #{socket.assigns.topic} lost: #{short(reason)}")
      telemetry(:disconnected, %{}, %{reason: reason}, socket)
    end

    if socket.assigns.status == :joined, do: broadcast_link(socket, :down)

    Enum.each(socket.assigns.pending, fn {_ref, {from, _}} ->
      expire(socket, from, :disconnected)
    end)

    assign(socket, status: :connecting, pending: %{}, failures: failures)
  end

  defp sweep(socket) do
    now = now()

    {late, pending} =
      Enum.split_with(socket.assigns.pending, fn {_ref, {_from, deadline}} -> deadline < now end)

    Enum.each(late, fn {_ref, {from, _}} -> expire(socket, from, :timeout) end)

    {entries, socket} = take_buffer(socket)
    {old, kept} = Enum.split_with(entries, fn {_, _, _, deadline} -> deadline < now end)
    Enum.each(old, fn {_, _, from, _} -> expire(socket, from, :expired) end)

    assign(socket,
      pending: Map.new(pending),
      buffer: :queue.from_list(kept),
      buffered: length(kept)
    )
  end

  defp ensure_sweep(%{assigns: %{sweep: nil}} = socket) do
    if map_size(socket.assigns.pending) > 0 or socket.assigns.buffered > 0,
      do: assign(socket, :sweep, Process.send_after(self(), :sweep, @sweep_every)),
      else: socket
  end

  defp ensure_sweep(socket), do: socket

  # Sauron's reply as the library answers it.
  defp answer({:ok, body}) when is_map(body), do: {:ok, body}
  defp answer(:ok), do: {:ok, %{}}

  defp answer({:error, %{"reason" => "invalid"} = body}),
    do: {:error, {:invalid, body["detail"]}}

  defp answer({:error, %{"reason" => reason}}) when is_binary(reason),
    do: {:error, reason(reason)}

  defp answer({:error, other}), do: {:error, other}
  defp answer(other), do: {:error, other}

  @reasons %{
    "not_found" => :not_found,
    "over" => :over,
    "not_allowed" => :not_allowed,
    "rate_limited" => :rate_limited,
    "unknown_event" => :unknown_event,
    "forbidden" => :forbidden
  }
  defp reason(reason), do: Map.get(@reasons, reason, reason)

  # ---------- presence ----------

  defp leave_seat(socket, id, pid) do
    seats = Map.get(socket.assigns.present, id, %{})

    case Map.pop(seats, pid) do
      {nil, _} ->
        socket

      {{ref, _page}, seats} ->
        Process.demonitor(ref, [:flush])

        if map_size(seats) == 0 do
          say_presence(socket, id, false, nil)
          assign(socket, :present, Map.delete(socket.assigns.present, id))
        else
          assign(socket, :present, Map.put(socket.assigns.present, id, seats))
        end
    end
  end

  defp announce_presence(socket) do
    for {id, seats} <- socket.assigns.present, map_size(seats) > 0 do
      {_ref, page} = seats |> Map.values() |> List.last()
      say_presence(socket, id, true, page)
    end

    socket
  end

  defp say_presence(socket, id, present?, page) do
    if socket.assigns.status == :joined do
      payload = %{"conversation_id" => id, "present" => present?}
      payload = if is_binary(page), do: Map.put(payload, "page", page), else: payload
      push(socket, socket.assigns.topic, "presence", payload)
    end
  catch
    :exit, _ -> :ok
  end

  # ---------- events ----------

  defp relay(socket, event, payload) do
    message =
      {Support,
       %Event{
         event: event,
         conversation_id: payload["conversation_id"],
         user_id: payload["user_id"],
         payload: payload
       }}

    pubsub = socket.assigns.pubsub

    if pubsub do
      if is_binary(payload["user_id"]),
        do:
          Phoenix.PubSub.local_broadcast(pubsub, Support.user_topic(payload["user_id"]), message)

      if is_binary(payload["conversation_id"]),
        do:
          Phoenix.PubSub.local_broadcast(
            pubsub,
            Support.conversation_topic(payload["conversation_id"]),
            message
          )
    end
  rescue
    exception -> Logger.debug("sauron support: event not relayed: #{inspect(exception)}")
  end

  defp broadcast_link(socket, status) do
    if pubsub = socket.assigns.pubsub,
      do: Phoenix.PubSub.local_broadcast(pubsub, Support.link_topic(), {Support, :link, status})
  rescue
    _ -> :ok
  end

  # ---------- helpers ----------

  defp telemetry(event, measurements, metadata, socket) do
    :telemetry.execute(
      [:sauron_reporter, :support, event],
      measurements,
      Map.put(metadata, :app, socket.assigns.app)
    )
  end

  defp short(%{__exception__: true} = exception), do: Exception.message(exception)
  defp short(reason), do: inspect(reason, limit: 5)

  defp now, do: System.monotonic_time(:millisecond)

  defp positive(key, default) do
    case Support.setting(key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
