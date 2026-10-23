defmodule SauronReporter.Support do
  @moduledoc """
  The support chat in an app (Sauron's plan 29): a signed-in user reports
  a problem, proposes an idea or speaks to somebody now, without leaving
  the app, and Nutshell answers from Sauron.

  Three pieces:

    * `SauronReporter.Support.Client` — the app's **one link** to Sauron,
      a WebSocket per app node, joined to `support:<app>` with the report
      token; it reconnects, buffers the users' calls while the link is
      down, and relays Sauron's events to the app's own PubSub. **The
      browser never talks to Sauron**: the app vouches for its user.
    * `panel/1` — the component the app puts in its layout: the launcher
      at the bottom right (or the app's own menu button, `open_panel/1`)
      and the side panel, a nested LiveView (`SauronReporter.Support.Live`).
    * the calls below — what the panel uses, open to an app that wants
      its own screens.

  ## Configuration

  Off until `support: [enabled: true]`, on top of the reporter's `url`,
  `token` and `app`:

      config :sauron_reporter,
        url: "https://sauron.nutshell-lab.com",   # SAURON_URL
        token: "...",                             # SAURON_REPORT_TOKEN
        app: "m2-app",
        support: [
          enabled: true,
          pubsub: MyApp.PubSub,      # the app's PubSub: where events are relayed
          # optional:
          socket_url: nil,           # default: the url, ws(s)://…/support/socket/websocket
          call_timeout: 10_000,      # ms a pushed call waits for Sauron's reply
          buffer_ttl: 30_000,        # ms a call waits for the link while it is down
          max_buffer: 500,           # calls held while the link is down; beyond, refused
          resume_window: 100,        # ms the resumes are gathered into one resume_many
          preview_max_size: 3_000_000,  # bytes of an image the panel shows; 0: chips only
          reconnect_after_msec: [100, 500, 1_000, 2_000, 5_000, 10_000, 30_000],
          rejoin_after_msec: [500, 1_000, 2_000, 5_000, 10_000, 30_000],
          slipstream: [],            # mint_opts (TLS), heartbeat_interval_msec
          req_options: []            # merged into Req's for the files API
        ]

  The client reads it when it starts (the library's application starts
  it): a change needs a restart.

  ## Calls

  Each returns `{:ok, …}` or `{:error, reason}` and never raises; the
  maps are Sauron's (`Sauron.Support.Wire`), string keys. Reasons are
  Sauron's — `:not_found`, `:over`, `:not_allowed`, `:rate_limited`,
  `{:invalid, detail}` — or the link's — `:disabled`, `:disconnected`,
  `:timeout`, `:buffer_full`, `:unavailable`. See
  `SauronReporter.Support.Client` for what waits and what is dropped.

  ## Events

  The client broadcasts, on the app's PubSub and on this node only:

    * `{SauronReporter.Support, %SauronReporter.Support.Event{}}` on
      `user_topic(user_id)` and on `conversation_topic(id)` — subscribe
      to one of them, not both, or each event arrives twice;
    * `{SauronReporter.Support, :link, :up | :down}` on `link_topic/0`.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias SauronReporter.Support.{Client, Files}

  @css_path Path.join([__DIR__, "..", "..", "priv", "static", "sauron_support.css"])
  @external_resource @css_path
  @css File.read!(@css_path)

  # ---------- configuration ----------

  @doc "The `support:` keyword list."
  def config, do: Application.get_env(:sauron_reporter, :support) || []

  @doc false
  def setting(key, default \\ nil), do: Keyword.get(config(), key, default)

  @doc "Whether support is on: enabled, a PubSub, and the reporter's url, token and app."
  def enabled? do
    reporter = Application.get_all_env(:sauron_reporter)
    support = reporter[:support] || []

    support[:enabled] == true and is_atom(support[:pubsub]) and not is_nil(support[:pubsub]) and
      filled?(reporter[:app]) and filled?(reporter[:url]) and filled?(reporter[:token])
  rescue
    _ -> false
  end

  defp filled?(value), do: is_binary(value) and value != ""

  @doc "The socket's URL: `socket_url`, else the reporter's `url` as `ws(s)://…/support/socket/websocket`."
  def socket_url do
    case setting(:socket_url) do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        uri = URI.parse(String.trim_trailing(Application.get_env(:sauron_reporter, :url), "/"))
        scheme = if uri.scheme == "https", do: "wss", else: "ws"

        URI.to_string(%{
          uri
          | scheme: scheme,
            path: (uri.path || "") <> "/support/socket/websocket"
        })
    end
  end

  @doc "The link: `%{status: :idle | :connecting | :joined | :down, buffered: n, in_flight: n, present: n}`."
  def status, do: Client.status()

  # ---------- topics ----------

  @doc "The topic of every event of `user_id`'s conversations."
  def user_topic(user_id), do: "sauron_support:user:#{user_id}"

  @doc "The topic of every event of one conversation."
  def conversation_topic(id), do: "sauron_support:conversation:#{id}"

  @doc "The topic of the link's changes."
  def link_topic, do: "sauron_support:link"

  @doc "Subscribes the caller to `user_topic/1`."
  def subscribe(user_id), do: Phoenix.PubSub.subscribe(setting(:pubsub), user_topic(user_id))

  @doc "Subscribes the caller to `conversation_topic/1`."
  def subscribe_conversation(id),
    do: Phoenix.PubSub.subscribe(setting(:pubsub), conversation_topic(id))

  @doc "Subscribes the caller to `link_topic/0`."
  def subscribe_link, do: Phoenix.PubSub.subscribe(setting(:pubsub), link_topic())

  # ---------- calls ----------

  @doc """
  The user asks: `kind` is `:issue`, `:feature` or `:live_chat`; `user`
  a map or struct with `id`, `name`, `email`; `org` one with `id` and
  `name`, or `nil`. Options: `body` (a first message), `page` (where the
  user is), `team` (who answers, « l'équipe m2 »: Sauron's own lines of
  the conversation say it; 100 characters at most). `{:ok, thread}` —
  `%{"conversation", "request", "modules", "messages", "resumed"?}`; a
  live chat the user already has open comes back rather than a second
  one.
  """
  def open(user, org, kind, opts \\ []) when kind in [:issue, :feature, :live_chat] do
    payload =
      %{"kind" => Atom.to_string(kind), "user" => user_params(user), "org" => org_params(org)}
      |> put_present("body", opts[:body])
      |> put_present("page", page(opts[:page]))
      |> put_present("team", team(opts[:team]))

    Client.call("open", payload)
  end

  @doc """
  The user writes: `{:ok, %{"message" => message}}`. Option `ref`, the
  app's key for this message (`new_ref/0` when not given): asked again
  with the same ref — a retry — Sauron answers the message it first
  posted, posted once. A call in flight when the link drops is pushed
  again for that reason.
  """
  def send_message(conversation_id, body, opts \\ []) do
    Client.call("message", %{
      "conversation_id" => conversation_id,
      "body" => body,
      "ref" => ref(opts)
    })
  end

  @doc """
  A file uploaded to Sauron's files API (`upload/4`) given to the
  conversation: `{:ok, %{"message" => message}}`. Option `ref`, as
  `send_message/3`.
  """
  def upload_done(conversation_id, file_id, caption \\ nil, opts \\ []) do
    Client.call(
      "upload_done",
      %{"conversation_id" => conversation_id, "file_id" => file_id, "ref" => ref(opts)}
      |> put_present("caption", caption)
    )
  end

  @doc "Uploads a file to Sauron for `conversation_id` (`SauronReporter.Support.Files.upload/4`)."
  defdelegate upload(conversation_id, path, name, content_type \\ nil), to: Files

  @doc "`upload/4` then `upload_done/4`: `{:ok, %{\"message\" => message}}`. Option `ref`."
  def attach(conversation_id, path, name, content_type \\ nil, caption \\ nil, opts \\ []) do
    with {:ok, %{"id" => file_id}} <- upload(conversation_id, path, name, content_type) do
      upload_done(conversation_id, file_id, caption, opts)
    end
  end

  @doc """
  An image of `user_id`'s conversations, fetched from Sauron for that
  user only (`SauronReporter.Support.Files.fetch/3`): `{:ok, %{content_type:,
  body:}}`. What the panel shows; the browser never asks Sauron.
  """
  defdelegate fetch_file(file_id, user_id, opts \\ []), to: Files, as: :fetch

  @doc "A new key for a message (`send_message/3`'s `ref`): 22 random URL-safe characters."
  def new_ref, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp ref(opts) do
    case opts[:ref] do
      ref when is_binary(ref) and ref != "" -> String.slice(ref, 0, 100)
      _ -> new_ref()
    end
  end

  @doc "The user is typing (`true`), or stopped. Sent when the link is up; `:ok`."
  def typing(conversation_id, typing?) when is_boolean(typing?),
    do: Client.cast("typing", %{"conversation_id" => conversation_id, "typing" => typing?})

  @doc "The user has read the conversation up to now. Sent when the link is up; `:ok`."
  def read(conversation_id), do: Client.cast("read", %{"conversation_id" => conversation_id})

  @doc """
  The calling process (a LiveView) shows `conversation_id` to its user,
  on `page`: Sauron hears `present: true`, and `false` once no process
  shows it any more (they are monitored). `:ok`.
  """
  def present(conversation_id, page \\ nil), do: Client.present(conversation_id, page(page))

  @doc "The calling process no longer shows `conversation_id`. `:ok`."
  def absent(conversation_id), do: Client.absent(conversation_id)

  @doc "« Terminé »: the request is sent and waits for an operator. `{:ok, %{\"request\" => request}}`."
  def submit(conversation_id), do: Client.call("submit", %{"conversation_id" => conversation_id})

  @doc "The user closes their request. `{:ok, %{\"request\" => request}}`."
  def close(conversation_id), do: Client.call("close", %{"conversation_id" => conversation_id})

  @doc "The user asks to be called back on `phone`. `{:ok, %{\"request\" => request}}`."
  def callback(conversation_id, phone),
    do: Client.call("callback", %{"conversation_id" => conversation_id, "phone" => phone})

  @doc """
  The user's requests not over yet, the newest first: `{:ok, [thread]}`.
  The users asked within a few milliseconds on this node go to Sauron
  in one `resume_many` call (`SauronReporter.Support.Client.resume/2`).
  """
  def resume(user_id) do
    with {:ok, %{"threads" => threads}} when is_list(threads) <- Client.resume(user_id),
         do: {:ok, threads}
  end

  @doc "A conversation as a thread; with `since` (ISO 8601), only the messages after it. `{:ok, thread}`."
  def history(conversation_id, since \\ nil) do
    Client.call("history", put_present(%{"conversation_id" => conversation_id}, "since", since))
  end

  # ---------- what leaves the app ----------

  @doc false
  # The user as Sauron takes it: an id (text), a name, an email.
  def user_params(user) do
    %{
      "id" => user |> field(:id) |> text(),
      "name" => user_name(user),
      "email" => user |> field(:email) |> text()
    }
  end

  defp user_name(user) do
    case text(field(user, :name)) do
      nil ->
        [field(user, :first_name), field(user, :last_name)]
        |> Enum.map(&text/1)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> nil
          parts -> Enum.join(parts, " ")
        end

      name ->
        name
    end
  end

  @doc false
  def org_params(nil), do: nil

  def org_params(org) do
    %{"id" => org |> field(:id) |> text(), "name" => org |> field(:name) |> text()}
  end

  defp field(nil, _key), do: nil
  defp field(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field(_other, _key), do: nil

  defp text(nil), do: nil

  defp text(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      text -> text
    end
  rescue
    _ -> nil
  end

  # Who answers, as Sauron keeps it: 100 characters at most.
  defp team(team) when is_binary(team) do
    case String.trim(team) do
      "" -> nil
      team -> String.slice(team, 0, 100)
    end
  end

  defp team(_), do: nil

  # The page as analytics sends a path: no query, no secret.
  defp page(nil), do: nil
  defp page(page) when is_binary(page), do: SauronReporter.Analytics.path(page)
  defp page(_), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # ---------- the panel ----------

  @doc """
  The support's launcher and panel, for a signed-in user: a nested
  LiveView (`SauronReporter.Support.Live`), sticky by default so a
  conversation survives live navigation. Renders nothing while support
  is not enabled or without a user id.

      <SauronReporter.Support.panel
        socket={@socket}
        user={%{id: @current_user.id, name: @current_user.name, email: @current_user.email}}
        org={%{id: @org.id, name: @org.name}}
        title="Assistance"
        team="l'équipe m2"
        launcher={false}
        page={@current_path}
      />

  A sticky LiveView is rendered in the layout of a `live_session`, once
  (its id names it).
  """
  attr(:socket, :any,
    required: true,
    doc: "the parent LiveView's socket (or the conn of a dead page)"
  )

  attr(:user, :any,
    required: true,
    doc: "the signed-in user: `id`, `name` (or `first_name`/`last_name`), `email`"
  )

  attr(:org, :any, default: nil, doc: "the user's organisation in the app: `id`, `name`")
  attr(:title, :string, default: "Aide", doc: "the panel's title, the launcher's word")

  attr(:team, :string,
    default: nil,
    doc:
      "who answers, as the copy says it: « l'équipe m2 » (default « l'équipe »); sent to Sauron, whose own lines then say it"
  )

  attr(:launcher, :boolean,
    default: true,
    doc: "the bottom-right launcher; false when the app opens the panel from its own menu"
  )

  attr(:page, :string,
    default: nil,
    doc: "where the user is (a path); `SauronReporter.Support.Hook` follows live navigation"
  )

  attr(:note, :string,
    default: nil,
    doc: "the start's footnote; default « Vos messages sont lus par <team>. »"
  )

  attr(:idea_hint, :string, default: nil, doc: "the line under « J'ai une idée »")
  attr(:time_zone, :string, default: "Europe/Paris", doc: "the times shown")

  attr(:hook, :boolean,
    default: true,
    doc: "the `SauronSupport` JS hook is registered (paste, screen capture, Enter to send)"
  )

  attr(:sticky, :boolean, default: true)
  attr(:id, :string, default: "sauron-support")

  def panel(assigns) do
    assigns = assign(assigns, :user_id, assigns.user |> field(:id) |> text())

    ~H"""
    <%= if @user_id && SauronReporter.Support.enabled?() do %>
      {live_render(@socket, SauronReporter.Support.Live,
        id: @id,
        sticky: @sticky,
        session: session(assigns),
        container: {:div, class: "sauron-support"}
      )}
    <% end %>
    """
  end

  defp session(assigns) do
    %{
      "user" => user_params(assigns.user),
      "org" => org_params(assigns.org),
      "title" => assigns.title,
      "team" => assigns.team,
      "launcher" => assigns.launcher,
      "page" => page(assigns.page),
      "note" => assigns.note,
      "idea_hint" => assigns.idea_hint,
      "time_zone" => assigns.time_zone,
      "hook" => assigns.hook
    }
  end

  @doc """
  The JS command an app's own button runs to open the panel — the menu
  variant (`launcher={false}`):

      <button type="button" phx-click={SauronReporter.Support.open_panel()}
              aria-label="Assistance">…</button>

  It pushes `"sauron_support:open"` to the panel's LiveView (found by
  its id, `"sauron-support"` unless the panel was given another) and
  remembers the focus, which closing the panel gives back. No script of
  the app's own.
  """
  def open_panel(js \\ %JS{}, id \\ "sauron-support") do
    js |> JS.push_focus() |> JS.push("sauron_support:open", target: "##{id}")
  end

  @doc "As `open_panel/2`, but closes the panel when it is open."
  def toggle_panel(js \\ %JS{}, id \\ "sauron-support") do
    js |> JS.push_focus() |> JS.push("sauron_support:toggle", target: "##{id}")
  end

  @doc "The panel's stylesheet (`priv/static/sauron_support.css`), for an app that inlines it."
  def css, do: @css

  @doc """
  A `<style>` with the panel's stylesheet, for an app without a CSS
  build that includes it (`@import "../../deps/sauron_reporter/priv/static/sauron_support.css";`).
  """
  attr(:nonce, :string, default: nil)

  def styles(assigns) do
    assigns = assign(assigns, :css, @css)

    ~H"""
    <style nonce={@nonce}><%= Phoenix.HTML.raw(@css) %></style>
    """
  end
end
