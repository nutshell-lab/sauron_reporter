defmodule SauronReporter.FakeSauron do
  @moduledoc """
  Sauron's side of the support (plan 29, step 1) for the tests: a real
  Phoenix endpoint on a free port, its socket at `/support/socket`
  (the `x-sauron-token` header, the channel `support:<app>` and its
  calls, as `SauronWeb.SupportChannel` answers them) and its files API
  (`POST /support/files`). Its state lives in an Agent; the functions
  below play the operators.
  """

  use Agent

  alias SauronReporter.FakeSauron.Endpoint

  @app "m2-app"
  @token "test-support-token-0001"

  def app, do: @app
  def token, do: @token

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> initial() end, name: __MODULE__)
  end

  defp initial,
    do: %{conversations: %{}, files: %{}, calls: [], accepting: true, test_pid: nil}

  def reset(test_pid \\ self()) do
    Agent.update(__MODULE__, fn _ -> %{initial() | test_pid: test_pid} end)
  end

  def port do
    {:ok, {_ip, port}} = Endpoint.server_info(:http)
    port
  end

  def url, do: "http://127.0.0.1:#{port()}"

  @doc "Whether a socket may connect now."
  def accepting?, do: Agent.get(__MODULE__, & &1.accepting)
  def accept(accepting?), do: Agent.update(__MODULE__, &%{&1 | accepting: accepting?})

  @doc "Every socket of the app closed, as a rotated token would."
  def drop_connections, do: Endpoint.broadcast("support_socket:#{@app}", "disconnect", %{})

  @doc "The calls received, in order: `{event, payload}`."
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  def conversation(id), do: Agent.get(__MODULE__, fn state -> state.conversations[id] end)

  # ---------- the channel's calls ----------

  @doc false
  def handle(event, payload) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = %{state | calls: [{event, payload} | state.calls]}
      if state.test_pid, do: send(state.test_pid, {:fake_sauron, event, payload})
      {reply, state, events} = call(event, payload, state)
      {{reply, events}, state}
    end)
    |> then(fn {reply, events} ->
      Enum.each(events, fn {event, payload} ->
        Endpoint.broadcast("support:#{@app}", event, payload)
      end)

      reply
    end)
  end

  defp call("open", %{"kind" => kind, "user" => %{"id" => user_id} = user} = payload, state)
       when kind in ["issue", "feature", "live_chat"] and is_binary(user_id) do
    active =
      kind == "live_chat" &&
        Enum.find(Map.values(state.conversations), fn c ->
          c.user["id"] == user_id and c.request["kind"] == "live_chat" and
            c.request["state"] in ["open", "claimed"]
        end)

    if active do
      {{:ok, Map.put(thread(active), "resumed", true)}, state, []}
    else
      id = Ecto.UUID.generate()
      now = now()

      conversation = %{
        id: id,
        user: user,
        org: payload["org"],
        inserted_at: now,
        modules:
          if(kind == "live_chat", do: ~w(text upload callback), else: ~w(text upload submit)),
        messages: [],
        request: %{
          "id" => Ecto.UUID.generate(),
          "conversation_id" => id,
          "kind" => kind,
          "state" => "open",
          "was_live_chat" => false,
          "submitted_at" => if(kind == "live_chat", do: now),
          "claimed_by" => nil,
          "callback_phone" => nil,
          "inserted_at" => now
        }
      }

      greeting =
        case kind do
          "live_chat" ->
            {"searching", "Nous cherchons quelqu'un de l'équipe Nutshell pour vous répondre…"}

          "issue" ->
            {"describe_issue", "Décrivez le problème."}

          "feature" ->
            {"describe_feature", "Décrivez votre idée."}
        end

      conversation = add(conversation, system(id, greeting))

      conversation =
        if is_binary(payload["body"]),
          do: add(conversation, user_message(conversation, text(payload["body"]))),
          else: conversation

      state = put_in(state, [:conversations, id], conversation)
      {{:ok, thread(conversation)}, state, []}
    end
  end

  defp call("message", %{"conversation_id" => id, "body" => body}, state) do
    with_live(state, id, fn conversation ->
      message = user_message(conversation, text(body))
      {{:ok, %{"message" => message}}, add(conversation, message), []}
    end)
  end

  defp call("upload_done", %{"conversation_id" => id, "file_id" => file_id} = payload, state) do
    with_live(state, id, fn conversation ->
      case state.files[file_id] do
        %{conversation_id: ^id} = file ->
          type = if String.starts_with?(file.content_type, "image/"), do: "image", else: "file"

          content = %{
            "type" => type,
            "file_id" => file_id,
            "name" => file.name,
            "content_type" => file.content_type,
            "size" => file.size,
            "caption" => payload["caption"]
          }

          message = user_message(conversation, content)
          conversation = add(conversation, message)

          {conversation, events} =
            if type == "image" and "screenshot" in conversation.modules,
              do: modules(conversation, List.delete(conversation.modules, "screenshot")),
              else: {conversation, []}

          {{:ok, %{"message" => message}}, conversation, events}

        _ ->
          {{:error, %{reason: "not_found"}}, conversation, []}
      end
    end)
  end

  defp call(event, %{"conversation_id" => id}, state)
       when event in ["typing", "presence", "read"] do
    if state.conversations[id],
      do: {{:ok, %{}}, state, []},
      else: {{:error, %{reason: "not_found"}}, state, []}
  end

  defp call("submit", %{"conversation_id" => id}, state) do
    with_live(state, id, fn conversation ->
      conversation = put_in(conversation, [:request, "submitted_at"], now())
      line = system(id, {"submitted", "C'est envoyé à l'équipe Nutshell."})

      {conversation, module_events} =
        modules(conversation, List.delete(conversation.modules, "submit"))

      conversation = add(conversation, line)

      {{:ok, %{"request" => conversation.request}}, conversation,
       [request_event(conversation, "submitted")] ++
         module_events ++ [message_event(conversation, line)]}
    end)
  end

  defp call("close", %{"conversation_id" => id}, state) do
    with_live(state, id, fn conversation ->
      conversation = put_in(conversation, [:request, "state"], "closed")
      {conversation, module_events} = modules(conversation, [])
      line = system(id, {"closed_by_user", "Vous avez clos cette demande."})
      conversation = add(conversation, line)

      {{:ok, %{"request" => conversation.request}}, conversation,
       [request_event(conversation, "closed", %{"by" => "user"})] ++
         module_events ++ [message_event(conversation, line)]}
    end)
  end

  defp call("callback", %{"conversation_id" => id, "phone" => phone}, state) do
    with_live(state, id, fn conversation ->
      conversation = put_in(conversation, [:request, "callback_phone"], phone)
      line = system(id, {"callback_requested", "Nous vous rappellerons au #{phone}."})

      {conversation, module_events} =
        modules(conversation, List.delete(conversation.modules, "callback"))

      conversation = add(conversation, line)

      {{:ok, %{"request" => conversation.request}}, conversation,
       [request_event(conversation, "callback_requested")] ++
         module_events ++ [message_event(conversation, line)]}
    end)
  end

  defp call("resume", %{"user_id" => user_id}, state) do
    threads =
      state.conversations
      |> Map.values()
      |> Enum.filter(&(&1.user["id"] == user_id and &1.request["state"] in ["open", "claimed"]))
      |> Enum.sort_by(& &1.inserted_at, :desc)
      |> Enum.map(&thread/1)

    {{:ok, %{"threads" => threads}}, state, []}
  end

  defp call("history", %{"conversation_id" => id} = payload, state) do
    case state.conversations[id] do
      nil ->
        {{:error, %{reason: "not_found"}}, state, []}

      conversation ->
        thread = thread(conversation)

        thread =
          case payload["since"] do
            nil ->
              thread

            since ->
              Map.update!(thread, "messages", fn ms ->
                Enum.filter(ms, &(&1["inserted_at"] > since))
              end)
          end

        {{:ok, thread}, state, []}
    end
  end

  defp call(_event, _payload, state),
    do: {{:error, %{reason: "invalid", detail: "missing or malformed fields"}}, state, []}

  defp with_live(state, id, fun) do
    case state.conversations[id] do
      nil ->
        {{:error, %{reason: "not_found"}}, state, []}

      %{request: %{"state" => s}} when s in ["closed", "rejected"] ->
        {{:error, %{reason: "over"}}, state, []}

      conversation ->
        {reply, conversation, events} = fun.(conversation)
        {reply, put_in(state, [:conversations, id], conversation), events}
    end
  end

  # ---------- the operators ----------

  @doc "An operator answers: claims the request if it is open, then writes."
  def operator_says(id, body, name \\ "Thomas Martin") do
    operator(id, fn conversation ->
      op = %{"id" => "op-1", "name" => name}

      {conversation, events} =
        if conversation.request["state"] == "open" do
          conversation =
            conversation
            |> put_in([:request, "state"], "claimed")
            |> put_in([:request, "claimed_by"], op)

          line =
            system(id, {"claimed", "#{name}, de l'équipe Nutshell, a rejoint la conversation."})

          {add(conversation, line),
           [
             request_event(conversation, "claimed", %{"operator" => op}),
             message_event(conversation, line)
           ]}
        else
          {conversation, []}
        end

      message = %{
        "id" => Ecto.UUID.generate(),
        "conversation_id" => id,
        "author" => %{"kind" => "operator", "id" => "op-1", "name" => name},
        "content" => text(body),
        "inserted_at" => now()
      }

      {add(conversation, message), events ++ [message_event(conversation, message)]}
    end)
  end

  @doc "Nobody answered the live chat in time: a ticket, the user told."
  def convert(id) do
    operator(id, fn conversation ->
      conversation =
        conversation
        |> put_in([:request, "kind"], "issue")
        |> put_in([:request, "was_live_chat"], true)

      line = system(id, {"no_operator", "Personne n'est disponible pour l'instant."})
      conversation = add(conversation, line)

      {conversation,
       [request_event(conversation, "converted"), message_event(conversation, line)]}
    end)
  end

  @doc "An operator asks for a screenshot."
  def ask_screenshot(id, name \\ "Thomas Martin") do
    operator(id, fn conversation ->
      op = %{"id" => "op-1", "name" => name}
      line = system(id, {"screenshot_asked", "#{name} vous demande une capture d'écran."})

      {conversation, module_events} =
        modules(conversation, Enum.uniq(conversation.modules ++ ["screenshot"]))

      conversation = add(conversation, line)

      {conversation,
       [request_event(conversation, "screenshot_asked", %{"operator" => op})] ++
         module_events ++ [message_event(conversation, line)]}
    end)
  end

  @doc "An operator types."
  def typing(id, typing?, name \\ "Thomas Martin") do
    operator(id, fn conversation ->
      {conversation,
       [
         {"typing",
          addressed(conversation)
          |> Map.merge(%{"operator" => %{"id" => "op-1", "name" => name}, "typing" => typing?})}
       ]}
    end)
  end

  @doc "A raw event, as Sauron would push it."
  def push(event, payload), do: Endpoint.broadcast("support:#{@app}", event, payload)

  defp operator(id, fun) do
    events =
      Agent.get_and_update(__MODULE__, fn state ->
        {conversation, events} = fun.(state.conversations[id])
        {events, put_in(state, [:conversations, id], conversation)}
      end)

    Enum.each(events, fn {event, payload} -> push(event, payload) end)
    :ok
  end

  # ---------- files ----------

  @doc false
  def store_file(conversation_id, name, body) do
    content_type =
      cond do
        match?(<<0x89, "PNG", _::binary>>, body) -> "image/png"
        match?(<<"%PDF", _::binary>>, body) -> "application/pdf"
        true -> nil
      end

    Agent.get_and_update(__MODULE__, fn state ->
      case state.conversations[conversation_id] do
        nil ->
          {{:error, 404}, state}

        %{request: %{"state" => s}} when s in ["closed", "rejected"] ->
          {{:error, 409}, state}

        _ when is_nil(content_type) ->
          {{:error, 415}, state}

        _ ->
          file = %{
            id: Ecto.UUID.generate(),
            conversation_id: conversation_id,
            name: name,
            content_type: content_type,
            size: byte_size(body)
          }

          {{:ok, file}, put_in(state, [:files, file.id], file)}
      end
    end)
  end

  # ---------- the wire ----------

  defp thread(c) do
    %{
      "conversation" => %{
        "id" => c.id,
        "org" => c.org,
        "user" => c.user,
        "inserted_at" => c.inserted_at
      },
      "request" => c.request,
      "modules" => c.modules,
      "messages" => c.messages
    }
  end

  defp add(conversation, message),
    do: %{conversation | messages: conversation.messages ++ [message]}

  defp modules(conversation, modules) do
    if modules == conversation.modules do
      {conversation, []}
    else
      conversation = %{conversation | modules: modules}
      {conversation, [{"modules", Map.put(addressed(conversation), "modules", modules)}]}
    end
  end

  defp system(id, {code, text}) do
    %{
      "id" => Ecto.UUID.generate(),
      "conversation_id" => id,
      "author" => %{"kind" => "system"},
      "content" => %{"type" => "event", "code" => code, "text" => text},
      "inserted_at" => now()
    }
  end

  defp user_message(conversation, content) do
    %{
      "id" => Ecto.UUID.generate(),
      "conversation_id" => conversation.id,
      "author" => %{"kind" => "user", "name" => conversation.user["name"]},
      "content" => content,
      "inserted_at" => now()
    }
  end

  defp text(body), do: %{"type" => "text", "body" => body}

  defp addressed(c), do: %{"conversation_id" => c.id, "user_id" => c.user["id"]}

  defp message_event(c, message), do: {"message", Map.put(addressed(c), "message", message)}

  defp request_event(c, event, extra \\ %{}),
    do: {event, addressed(c) |> Map.put("request", c.request) |> Map.merge(extra)}

  # Microseconds, so two messages of one call keep their order.
  defp now do
    Process.sleep(1)
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end

defmodule SauronReporter.FakeSauron.Socket do
  use Phoenix.Socket

  channel("support:*", SauronReporter.FakeSauron.Channel)

  @impl true
  def connect(_params, socket, connect_info) do
    token = for {"x-sauron-token", token} <- connect_info[:x_headers] || [], do: token

    if token == [SauronReporter.FakeSauron.token()] and SauronReporter.FakeSauron.accepting?(),
      do: {:ok, assign(socket, :app, SauronReporter.FakeSauron.app())},
      else: :error
  end

  @impl true
  def id(socket), do: "support_socket:#{socket.assigns.app}"
end

defmodule SauronReporter.FakeSauron.Channel do
  use Phoenix.Channel

  @impl true
  def join("support:" <> app, _payload, socket) do
    if app == socket.assigns.app,
      do: {:ok, %{app: app}, socket},
      else: {:error, %{reason: "forbidden"}}
  end

  @impl true
  def handle_in(event, payload, socket) do
    {:reply, SauronReporter.FakeSauron.handle(event, payload), socket}
  end
end

defmodule SauronReporter.FakeSauron.Files do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: "POST", path_info: ["support", "files"]} = conn, _opts) do
    conn = fetch_query_params(conn)

    if get_req_header(conn, "authorization") != ["Bearer " <> SauronReporter.FakeSauron.token()] do
      conn |> send_resp(401, "unknown token") |> halt()
    else
      {:ok, body, conn} = read_body(conn, length: 11_000_000)

      case SauronReporter.FakeSauron.store_file(
             conn.params["conversation_id"],
             conn.params["name"],
             body
           ) do
        {:ok, file} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(201, Jason.encode!(%{file: file}))
          |> halt()

        {:error, status} ->
          conn |> send_resp(status, "no") |> halt()
      end
    end
  end

  def call(conn, _opts), do: conn |> send_resp(404, "no such route") |> halt()
end

defmodule SauronReporter.FakeSauron.Endpoint do
  use Phoenix.Endpoint, otp_app: :sauron_reporter

  socket("/support/socket", SauronReporter.FakeSauron.Socket,
    websocket: [connect_info: [:x_headers], check_origin: false],
    longpoll: false
  )

  plug(SauronReporter.FakeSauron.Files)
end
