defmodule SauronReporter.Support.Live do
  @moduledoc """
  The support panel (plan 29, boards 75–76): the nested LiveView
  `SauronReporter.Support.panel/1` renders for a signed-in user.

  Its states: the guided start (« J'ai une idée », « J'ai un problème »,
  « Parler à quelqu'un »), the user's requests not over yet to resume;
  describing a problem or an idea, with attachments, then « Terminé »;
  a live chat searching for somebody, then answered by an operator
  (typing shown); nobody in 5 minutes, then an email answer and a
  callback; a screenshot asked, with a capture button; a request over.

  The user is the session's — the app's, signed by its endpoint — and
  every call and event is theirs only: the panel subscribes to its
  user's topic and drops any event of another user, and only ever names
  conversations Sauron gave it for that user.

  Events it handles from the page:

    * `"sauron_support:open"`, `"sauron_support:toggle"` — the launcher,
      or the app's own button (`SauronReporter.Support.open_panel/2`);
    * `"capabilities"` — from the `SauronSupport` hook: screen capture
      is possible in this browser.

  It tells the page's LiveView its unread count through
  `SauronReporter.Support.Hook` (`@sauron_support_unread`), and learns
  the page the user is on from it.
  """

  use Phoenix.LiveView

  alias Phoenix.LiveView.JS
  alias SauronReporter.Support
  alias SauronReporter.Support.{Copy, Event, Files}

  @registry SauronReporter.Support.Registry
  @kinds %{"feature" => :feature, "issue" => :issue, "live_chat" => :live_chat}
  @typing_every_ms 2_000
  @typing_shown_ms 8_000

  # ---------- mount ----------

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(
        user: session["user"] || %{},
        org: session["org"],
        title: session["title"] || "Aide",
        team: session["team"] || "l'équipe",
        launcher: session["launcher"] != false,
        page: session["page"],
        note: session["note"],
        idea_hint: session["idea_hint"],
        time_zone: session["time_zone"] || "Europe/Paris",
        hook: session["hook"] != false,
        open?: false,
        closed_once: false,
        loaded: false,
        threads: %{},
        current: nil,
        pending: [],
        unread: 0,
        typing: nil,
        draft: "",
        form_n: 0,
        typing_at: nil,
        can_capture: false,
        link: :up,
        confirm_close: false,
        later: false,
        notice: nil,
        busy: nil,
        now: DateTime.utc_now(),
        ticking: false,
        resumes: 0
      )
      |> allow_upload(:files,
        accept: Files.extensions(),
        max_entries: 5,
        max_file_size: Files.max_size()
      )

    if connected?(socket) and is_binary(socket.assigns.user["id"]) do
      Support.subscribe(socket.assigns.user["id"])
      Support.subscribe_link()
      register(socket)
      {:ok, resume(socket)}
    else
      {:ok, socket}
    end
  end

  # The page's LiveView (`SauronReporter.Support.Hook`) finds the panel
  # by the socket's transport: the same browser tab.
  defp register(socket) do
    if transport = socket.transport_pid do
      Registry.register(@registry, transport, :panel)
      notify(socket)
    end
  rescue
    _ -> :ok
  end

  defp resume(socket) do
    user_id = socket.assigns.user["id"]
    start_async(socket, :resume, fn -> Support.resume(user_id) end)
  end

  # ---------- render ----------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:thread, assigns.threads[assigns.current])
      |> then(&assign(&1, :ctx, ctx(&1)))

    ~H"""
    <div id={"#{@socket.id}-root"} class="aide-root" phx-hook={@hook && "SauronSupport"}>
      <button
        :if={@launcher and not @open?}
        type="button"
        class="aide-launch"
        aria-label={launcher_label(@title, @unread)}
        aria-expanded="false"
        phx-click="sauron_support:open"
        phx-mounted={@closed_once && JS.focus()}
      >
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path
            d="M4 5h16v11H9l-5 4z"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linejoin="round"
          />
        </svg>
        {@title}<span :if={@unread > 0} class="aide-badge" aria-hidden="true">{@unread}</span>
      </button>

      <section
        :if={@open?}
        id={"#{@socket.id}-panel"}
        class="aide aide-panel"
        role="dialog"
        aria-labelledby={"#{@socket.id}-title"}
        phx-keydown={JS.pop_focus() |> JS.push("close_panel")}
        phx-key="Escape"
        phx-mounted={is_nil(@thread) && JS.focus_first(to: "##{@socket.id}-choices")}
      >
        <header class="aide-h">
          <div class="aide-tt">
            <h2 id={"#{@socket.id}-title"} class="aide-title">{@title}</h2>
            <span class="aide-sub">
              <i :if={claimed?(@thread)} class="aide-on" aria-hidden="true"></i>{subtitle(@thread, @ctx, @now)}
            </span>
          </div>
          <div class="aide-tools">
            <button
              type="button"
              class="aide-ib"
              aria-label="Réduire"
              phx-click={JS.pop_focus() |> JS.push("close_panel")}
            >
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M5 12h14" stroke="currentColor" stroke-width="1.8" />
              </svg>
            </button>
            <button
              :if={closable?(@thread)}
              type="button"
              class="aide-ib"
              aria-label="Fermer la demande"
              phx-click="ask_close"
            >
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="1.8" />
              </svg>
            </button>
          </div>
        </header>

        <%= if @thread do %>
          <.thread_view {assigns} />
        <% else %>
          <.start_view {assigns} />
        <% end %>
      </section>
    </div>
    """
  end

  # ---------- the start ----------

  defp start_view(assigns) do
    assigns =
      assign(assigns,
        others:
          assigns.threads
          |> Map.values()
          |> Enum.reject(&over?/1)
          |> Enum.sort_by(&(&1["conversation"]["inserted_at"] || ""), :desc)
      )

    ~H"""
    <div class="aide-t aide-top">
      <div class="aide-log">
        <span class="aide-who">{@title}</span>
        <div class="aide-b aide-auto">
          <p>{greeting(@user)}</p>
        </div>
        <div class="aide-chs" id={"#{@socket.id}-choices"}>
          <button
            :for={kind <- [:feature, :issue, :live_chat]}
            type="button"
            class="aide-ch"
            phx-click="choose"
            phx-value-kind={kind}
            disabled={@busy == :open}
          >
            <b>{Copy.choice(kind)}</b><span>{Copy.hint(kind, @idea_hint)}</span>
          </button>
        </div>
        <div :if={@others != []} class="aide-chs aide-resume">
          <span class="aide-who">Vos demandes en cours</span>
          <button
            :for={thread <- @others}
            type="button"
            class="aide-ch"
            phx-click="resume_thread"
            phx-value-id={thread["conversation"]["id"]}
          >
            <b>{Copy.choice(kind(thread))}</b><span>{summary(thread, @ctx)}</span>
          </button>
        </div>
      </div>
    </div>
    <p :if={@link == :down} class="aide-status" role="status">
      Connexion à l'assistance interrompue : nous réessayons.
    </p>
    <p :if={@notice} class="aide-notice" role="alert">{@notice}</p>
    <p class="aide-note">{@note || "Vos messages sont lus par #{@team}."}</p>
    """
  end

  # ---------- a thread ----------

  defp thread_view(assigns) do
    modules = assigns.thread["modules"] || []
    request = assigns.thread["request"] || %{}

    assigns =
      assign(assigns,
        modules: modules,
        request: request,
        entries: entries(assigns.thread, assigns.ctx, assigns.now, assigns.time_zone),
        mine: Enum.filter(assigns.pending, &(&1.cid == assigns.current)),
        over: over?(assigns.thread),
        live: kind(assigns.thread) == :live_chat,
        converted: request["was_live_chat"] == true,
        searching: searching?(assigns.thread),
        typing_name: typing_name(assigns.typing, assigns.current),
        label: composer_label(assigns.thread),
        placeholder: placeholder(assigns.thread),
        upload_errors: composer_errors(assigns.uploads.files)
      )

    ~H"""
    <div class="aide-t">
      <div>
        <div class="aide-log" role="log" aria-live="polite" aria-relevant="additions">
          <div class="aide-b aide-me"><p>{Copy.choice(kind(@thread))}</p></div>
          <%= for entry <- @entries do %>
            <%= case entry do %>
              <% {:day, text} -> %>
                <span class="aide-evt">{text}</span>
              <% {:who, text, me?} -> %>
                <span class={["aide-who", me? && "aide-who-me"]}>{text}</span>
              <% {:evt, text} -> %>
                <span class="aide-evt">{text}</span>
              <% {:info, text} -> %>
                <p class="aide-info">{text}</p>
              <% {:bubble, style, body} -> %>
                <div class={["aide-b", "aide-#{style}"]}>
                  <.body body={body} />
                </div>
            <% end %>
          <% end %>
          <%= for item <- @mine do %>
            <span class="aide-who aide-who-me">Vous</span>
            <div class="aide-b aide-me aide-pending">
              <p :if={item.body}>{item.body}</p>
              <div :if={item.kind == :file} class="aide-file">
                <.file_icon /><span>{item.name} <small>{Copy.size(item.size)}</small></span>
              </div>
              <p :if={item.status == :sending} class="aide-state">Envoi…</p>
              <p :if={item.status == :failed} class="aide-state aide-failed">
                Non envoyé.
                <button type="button" class="aide-link" phx-click="retry" phx-value-ref={item.ref}>
                  Réessayer
                </button>
                <button type="button" class="aide-link" phx-click="discard" phx-value-ref={item.ref}>
                  Abandonner
                </button>
              </p>
            </div>
          <% end %>
        </div>
        <p :if={@typing_name} class="aide-typing" role="status">
          <span class="aide-dots" aria-hidden="true"><i></i><i></i><i></i></span>{@typing_name} écrit…
        </p>
      </div>
    </div>

    <p :if={@link == :down} class="aide-status" role="status">
      Connexion à l'assistance interrompue : vos messages partiront dès son retour.
    </p>

    <div :if={@confirm_close} class="aide-cb" role="group" aria-labelledby={"#{@socket.id}-confirm"}>
      <p id={"#{@socket.id}-confirm"} class="aide-strong">
        Clore cette demande ? Vous ne pourrez plus y écrire.
      </p>
      <div class="aide-row">
        <button type="button" class="aide-btn aide-pri" phx-click="close_request" disabled={@busy == :close}>
          Clore la demande
        </button>
        <button type="button" class="aide-btn aide-lite" phx-click="cancel_close">Annuler</button>
      </div>
    </div>

    <div :if={"screenshot" in @modules and not @later and not @over} class="aide-req" role="status">
      <p>
        <.camera_icon />{screenshot_line(@request)}
      </p>
      <div class="aide-row">
        <button
          :if={@can_capture}
          type="button"
          class="aide-btn aide-pri"
          phx-click={JS.dispatch("sauron:capture")}
        >
          Capturer cet écran
        </button>
        <label for={@uploads.files.ref} class={["aide-btn", not @can_capture && "aide-pri"]}>
          Choisir une image
        </label>
        <button type="button" class="aide-btn aide-lite" phx-click="later">Plus tard</button>
      </div>
    </div>

    <form
      :if={"callback" in @modules and @converted and not @over}
      class="aide-cb"
      id={"#{@socket.id}-callback"}
      phx-submit="callback"
    >
      <label for={"#{@socket.id}-phone"}>Votre numéro, pour être rappelé</label>
      <div class="aide-row">
        <input
          id={"#{@socket.id}-phone"}
          name="phone"
          type="tel"
          autocomplete="tel"
          placeholder="06 00 00 00 00"
          required
        />
        <button type="submit" class="aide-btn aide-pri" disabled={@busy == :callback}>
          Rappelez-moi
        </button>
      </div>
    </form>

    <p :if={@notice} class="aide-notice" role="alert">{@notice}</p>

    <form
      :if={"text" in @modules and not @over}
      class="aide-c"
      id={"#{@socket.id}-composer"}
      phx-change="draft"
      phx-submit="send"
    >
      <div :if={@uploads.files.entries != []} class="aide-pend">
        <span :for={entry <- @uploads.files.entries} class="aide-att">
          {entry.client_name}
          <button
            type="button"
            class="aide-ib"
            aria-label={"Retirer #{entry.client_name}"}
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M7 7l10 10M17 7L7 17" stroke="currentColor" stroke-width="1.8" />
            </svg>
          </button>
        </span>
      </div>
      <p :for={error <- @upload_errors} class="aide-notice" role="alert">{error}</p>
      <label for={"#{@socket.id}-message-#{@form_n}"}>{@label}</label>
      <textarea
        id={"#{@socket.id}-message-#{@form_n}"}
        name="message"
        rows="2"
        placeholder={@placeholder}
        data-aide-enter
        phx-mounted={JS.focus()}
      >{@draft}</textarea>
      <div class="aide-row">
        <%= if "upload" in @modules do %>
          <.live_file_input upload={@uploads.files} class="aide-file-input" />
          <label for={@uploads.files.ref} class="aide-btn aide-ic" title="Joindre un fichier">
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path
                d="M20 11l-8.5 8.5a5 5 0 01-7-7L13 4a3.5 3.5 0 015 5l-8.5 8.5a2 2 0 01-3-3L14 7"
                fill="none"
                stroke="currentColor"
                stroke-width="1.8"
              />
            </svg>
            <span class="aide-sr">Joindre un fichier</span>
          </label>
          <button
            :if={@can_capture}
            type="button"
            class="aide-btn"
            phx-click={JS.dispatch("sauron:capture")}
          >
            <.camera_icon />Capture d'écran
          </button>
        <% end %>
        <button type="submit" class="aide-btn aide-pri aide-send">Envoyer</button>
      </div>
      <%= if "submit" in @modules do %>
        <button
          type="button"
          class="aide-btn aide-wide"
          aria-describedby={"#{@socket.id}-submit-hint"}
          phx-click="submit"
          disabled={@busy == :submit}
        >
          Terminé — envoyer la demande
        </button>
        <p id={"#{@socket.id}-submit-hint"} class="aide-hint">
          Votre demande part à {@team} et reste ouverte jusqu'à notre réponse.
        </p>
      <% end %>
      <button
        :if={not @live and "submit" not in @modules}
        type="button"
        class="aide-link aide-again"
        phx-click="new_request"
      >
        Faire une autre demande
      </button>
    </form>

    <div :if={@over} class="aide-c">
      <p class="aide-hint">Cette demande est close.</p>
      <button type="button" class="aide-btn aide-pri" phx-click="new_request">Nouvelle demande</button>
    </div>
    """
  end

  attr(:body, :any, required: true)

  defp body(%{body: {:text, text}} = assigns) do
    assigns = assign(assigns, :paragraphs, String.split(text || "", ~r/\n\s*\n/, trim: true))

    ~H"""
    <p :for={paragraph <- @paragraphs}>{paragraph}</p>
    """
  end

  defp body(%{body: {:paragraphs, paragraphs}} = assigns) do
    assigns = assign(assigns, :paragraphs, paragraphs)

    ~H"""
    <p :for={paragraph <- @paragraphs}>{paragraph}</p>
    """
  end

  defp body(%{body: {:searching, text, searching?}} = assigns) do
    assigns = assign(assigns, text: text, searching?: searching?)

    ~H"""
    <p>
      <span :if={@searching?} class="aide-dots" aria-hidden="true"><i></i><i></i><i></i></span>{@text}
    </p>
    """
  end

  defp body(%{body: {:file, file}} = assigns) do
    assigns = assign(assigns, :file, file)

    ~H"""
    <p :if={@file["caption"]}>{@file["caption"]}</p>
    <div class="aide-file">
      <.file_icon /><span>{@file["name"]} <small>{Copy.size(@file["size"])}</small></span>
    </div>
    """
  end

  defp file_icon(assigns) do
    ~H"""
    <svg width="14" height="16" viewBox="0 0 18 20" aria-hidden="true">
      <path d="M2 1h9l5 5v13H2z M11 1v5h5" fill="none" stroke="currentColor" stroke-width="1.6" />
    </svg>
    """
  end

  defp camera_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" aria-hidden="true" class="aide-icon">
      <rect
        x="3"
        y="7"
        width="18"
        height="13"
        rx="2"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
      />
      <circle cx="12" cy="13.5" r="3.5" fill="none" stroke="currentColor" stroke-width="1.8" />
      <path d="M8 7l2-3h4l2 3" fill="none" stroke="currentColor" stroke-width="1.8" />
    </svg>
    """
  end

  # ---------- what the thread shows ----------

  # The messages as lines: a day when it changes, who speaks when it
  # changes (or after five minutes), the bubbles and the system's lines.
  defp entries(thread, ctx, now, zone) do
    today = Copy.local(now, zone)
    searching? = searching?(thread)

    {entries, _} =
      Enum.reduce(thread["messages"] || [], {[], %{day: nil, who: nil, at: nil}}, fn message,
                                                                                     {acc, prev} ->
        at = Copy.parse(message["inserted_at"])
        local = Copy.local(at, zone) || today
        day = NaiveDateTime.to_date(local)

        acc =
          if day != prev.day and (prev.day != nil or day != NaiveDateTime.to_date(today)),
            do: [{:day, Copy.day(local, today)} | acc],
            else: acc

        prev = if day != prev.day, do: %{prev | day: day, who: nil}, else: prev
        {lines, who} = message_lines(message, ctx, local, searching?)

        who_line =
          case lines do
            [] ->
              []

            [{:evt, _} | _] ->
              []

            _ ->
              if who.key != prev.who or gap?(prev.at, at),
                do: [{:who, "#{who.label} · #{Copy.time(local)}", who.me}],
                else: []
          end

        # A system line between two people: whoever speaks next is named.
        prev =
          case lines do
            [] -> prev
            [{:evt, _} | _] -> %{prev | who: nil, at: at}
            _ -> %{prev | who: who.key, at: at}
          end

        {Enum.reverse(who_line ++ lines) ++ acc, prev}
      end)

    Enum.reverse(entries)
  end

  defp gap?(nil, _at), do: false
  defp gap?(_prev, nil), do: false
  defp gap?(prev, at), do: DateTime.diff(at, prev) > 300

  defp message_lines(%{"author" => %{"kind" => "user"}} = message, _ctx, _local, _searching?) do
    {[{:bubble, :me, content(message["content"])}], %{key: :user, label: "Vous", me: true}}
  end

  defp message_lines(%{"author" => %{"kind" => "operator"} = author} = message, _ctx, _local, _s) do
    name = Copy.first_name(author["name"]) || "L'équipe"

    {[{:bubble, :them, content(message["content"])}],
     %{key: {:operator, author["id"] || author["name"]}, label: name, me: false}}
  end

  defp message_lines(message, ctx, local, searching?) do
    who = %{key: :system, label: ctx.title, me: false}

    case Copy.system(message["content"] || %{}, ctx) do
      {:event, text} ->
        {[{:evt, "#{text} · #{Copy.time(local)}"}], who}

      # Only while it is true: once somebody answered, or nobody did,
      # the next lines say so.
      {:searching, text} ->
        if searching?,
          do: {[{:bubble, :auto, {:searching, text, true}}, {:info, Copy.waiting_info()}], who},
          else: {[], who}

      {:paragraphs, paragraphs} ->
        {[{:bubble, :auto, {:paragraphs, paragraphs}}], who}

      {:line, text} ->
        {[{:bubble, :auto, {:text, text}}], who}
    end
  end

  defp content(%{"type" => type} = file) when type in ["image", "file"], do: {:file, file}
  defp content(%{"body" => body}), do: {:text, body}
  defp content(_), do: {:text, ""}

  defp ctx(assigns) do
    %{
      team: assigns.team,
      title: assigns.title,
      email: assigns.user["email"],
      request: assigns.thread && assigns.thread["request"]
    }
  end

  defp kind(%{"request" => %{"was_live_chat" => true}}), do: :live_chat
  defp kind(%{"request" => %{"kind" => kind}}), do: Map.get(@kinds, kind, :issue)
  defp kind(_), do: :issue

  defp state(%{"request" => %{"state" => state}}), do: state
  defp state(_), do: nil

  defp over?(thread), do: state(thread) in ["closed", "rejected"]
  defp claimed?(thread), do: state(thread) == "claimed"

  defp searching?(%{"request" => %{"kind" => "live_chat", "state" => "open"}}), do: true
  defp searching?(_), do: false

  defp closable?(nil), do: false
  defp closable?(thread), do: kind(thread) == :live_chat and not over?(thread)

  defp subtitle(nil, ctx, _now), do: Copy.capitalize(ctx.team)

  defp subtitle(thread, ctx, now) do
    request = thread["request"] || %{}

    cond do
      over?(thread) ->
        "Demande close"

      claimed?(thread) ->
        case Copy.operator_name(request) do
          nil -> Copy.capitalize(ctx.team)
          name -> "#{Copy.first_name(name)}, de #{ctx.team}"
        end

      searching?(thread) ->
        since = Copy.parse(request["submitted_at"] || request["inserted_at"]) || now
        "Nous cherchons quelqu'un · #{Copy.elapsed(DateTime.diff(now, since))}"

      request["was_live_chat"] == true ->
        "Demande enregistrée · réponse par e-mail"

      is_binary(request["submitted_at"]) ->
        "Demande envoyée · réponse par e-mail"

      kind(thread) == :feature ->
        "Une idée · nous répondons par e-mail"

      true ->
        "Un problème · nous répondons par e-mail"
    end
  end

  defp summary(thread, ctx) do
    case subtitle(thread, ctx, DateTime.utc_now()) do
      "Nous cherchons" <> _ -> "Nous cherchons quelqu'un"
      text -> text
    end
  end

  defp screenshot_line(request) do
    case Copy.operator_name(request) do
      nil -> "On vous demande une capture d'écran"
      name -> "#{Copy.first_name(name)} vous demande une capture d'écran"
    end
  end

  defp composer_label(thread) do
    request = thread["request"] || %{}

    if not claimed?(thread) and
         (request["was_live_chat"] == true or
            (kind(thread) != :live_chat and is_binary(request["submitted_at"]))),
       do: "Ajouter un détail à votre demande",
       else: "Votre message"
  end

  defp placeholder(thread) do
    request = thread["request"] || %{}
    wrote? = Enum.any?(thread["messages"] || [], &(&1["author"]["kind"] == "user"))

    cond do
      claimed?(thread) ->
        case Copy.operator_name(request) do
          nil -> "Votre message…"
          name -> "Écrivez à #{Copy.first_name(name)}…"
        end

      searching?(thread) ->
        "Décrivez votre demande en attendant…"

      request["was_live_chat"] == true or is_binary(request["submitted_at"]) ->
        "Votre message…"

      wrote? ->
        "Ajoutez un détail…"

      kind(thread) == :feature ->
        "Décrivez votre idée…"

      true ->
        "Décrivez le problème…"
    end
  end

  defp typing_name(%{cid: cid, name: name}, cid), do: Copy.first_name(name) || "L'équipe"
  defp typing_name(_typing, _current), do: nil

  defp greeting(user) do
    case Copy.first_name(user["name"]) do
      nil -> "Bonjour — comment pouvons-nous vous aider ?"
      name -> "Bonjour #{name} — comment pouvons-nous vous aider ?"
    end
  end

  defp launcher_label(title, 0), do: title
  defp launcher_label(title, 1), do: "#{title}, 1 nouvelle réponse"
  defp launcher_label(title, n), do: "#{title}, #{n} nouvelles réponses"

  defp composer_errors(upload) do
    (Phoenix.Component.upload_errors(upload) ++
       Enum.flat_map(upload.entries, &Phoenix.Component.upload_errors(upload, &1)))
    |> Enum.uniq()
    |> Enum.map(&Copy.upload_error/1)
  rescue
    _ -> []
  end

  # ---------- the page's events ----------

  @impl true
  def handle_event("sauron_support:open", _params, socket), do: {:noreply, open(socket)}

  def handle_event("sauron_support:toggle", _params, socket) do
    if socket.assigns.open?, do: {:noreply, close(socket)}, else: {:noreply, open(socket)}
  end

  def handle_event("close_panel", _params, socket), do: {:noreply, close(socket)}

  def handle_event("capabilities", params, socket) do
    {:noreply, assign(socket, :can_capture, params["capture"] == true)}
  end

  def handle_event("capture_failed", _params, socket) do
    {:noreply,
     assign(socket, :notice, "La capture n'a pas pu être faite : choisissez plutôt une image.")}
  end

  def handle_event("choose", %{"kind" => kind}, socket) when is_map_key(@kinds, kind) do
    if socket.assigns.busy == :open do
      {:noreply, socket}
    else
      %{user: user, org: org, page: page} = socket.assigns
      kind = Map.fetch!(@kinds, kind)

      {:noreply,
       socket
       |> assign(busy: :open, notice: nil)
       |> start_async(:open, fn -> Support.open(user, org, kind, page: page) end)}
    end
  end

  def handle_event("resume_thread", %{"id" => id}, socket) do
    if Map.has_key?(socket.assigns.threads, id),
      do: {:noreply, socket |> show(id) |> assign(:notice, nil)},
      else: {:noreply, socket}
  end

  def handle_event("new_request", _params, socket) do
    {:noreply,
     socket
     |> forget_uploads()
     |> assign(current: nil, notice: nil, confirm_close: false, draft: "")}
  end

  def handle_event("draft", params, socket) do
    draft = params["message"] || ""
    {:noreply, socket |> assign(:draft, draft) |> typing(draft)}
  end

  def handle_event("send", params, socket) do
    cid = socket.assigns.current
    body = String.trim(params["message"] || "")

    if is_nil(cid) do
      {:noreply, socket}
    else
      files =
        consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
          kept = Path.join(System.tmp_dir!(), "sauron-support-#{entry.uuid}")
          File.cp!(path, kept)

          {:ok,
           %{
             path: kept,
             name: entry.client_name,
             type: entry.client_type,
             size: entry.client_size
           }}
        end)

      # Text with files rides on the first file as its caption, as one
      # message — when it fits a caption.
      {caption, text} =
        if files != [] and body != "" and String.length(body) <= 1_000,
          do: {body, ""},
          else: {nil, body}

      socket = if text != "", do: send_text(socket, cid, text), else: socket

      socket =
        files
        |> Enum.with_index()
        |> Enum.reduce(socket, fn {file, i}, socket ->
          send_file(socket, cid, file, if(i == 0, do: caption))
        end)

      if socket.assigns.typing_at, do: Support.typing(cid, false)

      {:noreply,
       assign(socket,
         draft: "",
         form_n: socket.assigns.form_n + 1,
         typing_at: nil,
         notice: nil
       )}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  def handle_event("retry", %{"ref" => ref}, socket) do
    case Enum.find(socket.assigns.pending, &(to_string(&1.ref) == ref)) do
      nil -> {:noreply, socket}
      item -> {:noreply, run(socket, %{item | status: :sending})}
    end
  end

  def handle_event("discard", %{"ref" => ref}, socket) do
    {gone, pending} = Enum.split_with(socket.assigns.pending, &(to_string(&1.ref) == ref))
    Enum.each(gone, &forget_file/1)
    {:noreply, assign(socket, :pending, pending)}
  end

  def handle_event("submit", _params, socket) do
    call(socket, :submit, &Support.submit/1)
  end

  def handle_event("ask_close", _params, socket),
    do: {:noreply, assign(socket, :confirm_close, true)}

  def handle_event("cancel_close", _params, socket),
    do: {:noreply, assign(socket, :confirm_close, false)}

  def handle_event("close_request", _params, socket) do
    call(socket, :close, &Support.close/1)
  end

  def handle_event("callback", %{"phone" => phone}, socket) do
    if String.trim(phone) == "" do
      {:noreply, assign(socket, :notice, "Indiquez un numéro où vous rappeler.")}
    else
      call(socket, :callback, &Support.callback(&1, phone))
    end
  end

  def handle_event("later", _params, socket), do: {:noreply, assign(socket, :later, true)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ---------- Sauron's answers ----------

  @impl true
  def handle_async(:resume, {:ok, {:ok, threads}}, socket) when is_list(threads) do
    first? = not socket.assigns.loaded
    socket = Enum.reduce(threads, assign(socket, loaded: true, resumes: 0), &put_thread(&2, &1))

    # A thread the user had left mid-way opens again by itself: a live
    # chat not over, or a request not sent yet.
    socket =
      if first? and is_nil(socket.assigns.current) do
        case Enum.find(threads, &continuing?/1) do
          nil -> socket
          thread -> show(socket, thread["conversation"]["id"])
        end
      else
        socket
      end

    # The thread on screen that ended while the link was down.
    socket =
      case socket.assigns.current do
        nil ->
          socket

        id ->
          if Enum.any?(threads, &(&1["conversation"]["id"] == id)),
            do: socket,
            else: history(socket, id)
      end

    {:noreply, socket |> present_all() |> tick()}
  end

  # Sauron limits the calls of the app's one socket: after a restart or
  # a reconnection every panel asks at once. Asked again, later, a few
  # times.
  def handle_async(:resume, {:ok, {:error, reason}}, socket)
      when reason in [:rate_limited, :timeout, :disconnected] and socket.assigns.resumes < 5 do
    Process.send_after(self(), :resume, 1_000 + :rand.uniform(4_000))
    {:noreply, assign(socket, :resumes, socket.assigns.resumes + 1)}
  end

  def handle_async(:resume, _result, socket), do: {:noreply, assign(socket, :loaded, true)}

  def handle_async(:open, {:ok, {:ok, %{"conversation" => %{"id" => id}} = thread}}, socket) do
    {:noreply,
     socket
     |> assign(busy: nil, later: false)
     |> put_thread(thread)
     |> show(id)
     |> present_all()
     |> tick()}
  end

  def handle_async(:open, result, socket) do
    {:noreply, assign(socket, busy: nil, notice: Copy.failure(failure(result)))}
  end

  def handle_async(
        {:history, id},
        {:ok, {:ok, %{"conversation" => %{"id" => id}} = thread}},
        socket
      ) do
    {:noreply, socket |> put_thread(thread) |> present_all() |> tick()}
  end

  def handle_async({:history, _id}, _result, socket), do: {:noreply, socket}

  def handle_async({:send, ref}, result, socket), do: {:noreply, sent(socket, ref, result)}

  def handle_async({:request, op, id}, {:ok, {:ok, %{"request" => request}}}, socket) do
    socket =
      socket
      |> assign(busy: nil, notice: nil)
      |> update_thread(id, &Map.put(&1, "request", request))
      |> assign(:confirm_close, if(op == :close, do: false, else: socket.assigns.confirm_close))

    {:noreply, tick(socket)}
  end

  def handle_async({:request, _op, _id}, result, socket) do
    {:noreply, assign(socket, busy: nil, notice: Copy.failure(failure(result)))}
  end

  defp failure({:ok, {:error, reason}}), do: reason
  defp failure({:exit, reason}), do: {:exit, reason}
  defp failure(other), do: other

  # ---------- Sauron's events, the page's messages ----------

  @impl true
  def handle_info({Support, %Event{user_id: user_id} = event}, socket) do
    if is_binary(user_id) and user_id == socket.assigns.user["id"] and
         is_binary(event.conversation_id),
       do: {:noreply, sauron_event(event, socket)},
       else: {:noreply, socket}
  end

  def handle_info({Support, :link, status}, socket) when status in [:up, :down] do
    socket = assign(socket, :link, status)

    # Back: what happened meanwhile, from Sauron — every panel of the
    # node hears it at once, so each asks within a few seconds.
    if status == :up, do: Process.send_after(self(), :resume, :rand.uniform(3_000))
    {:noreply, socket}
  end

  def handle_info(:resume, socket), do: {:noreply, resume(socket)}

  def handle_info({Support, :hello, pid}, socket) do
    send(pid, {Support, :unread, socket.assigns.unread})
    {:noreply, socket}
  end

  def handle_info({Support, :page, page}, socket) do
    page = if is_binary(page), do: SauronReporter.Analytics.path(page), else: nil
    {:noreply, socket |> assign(:page, page) |> present_all()}
  end

  def handle_info({:typing_off, token}, socket) do
    case socket.assigns.typing do
      %{token: ^token} -> {:noreply, assign(socket, :typing, nil)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(:tick, socket) do
    {:noreply, socket |> assign(now: DateTime.utc_now(), ticking: false) |> tick()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp sauron_event(%Event{conversation_id: id} = event, socket) do
    known? = Map.has_key?(socket.assigns.threads, id)
    payload = event.payload
    request? = is_map(payload["request"])

    socket =
      case event.event do
        "message" ->
          socket
          |> then(fn socket ->
            if known? and is_map(payload["message"]),
              do: update_thread(socket, id, &merge_messages(&1, [payload["message"]])),
              else: history(socket, id)
          end)
          |> operator_spoke(payload["message"], id)
          |> arrived(id, payload["message"])

        "typing" ->
          operator_typing(socket, id, payload)

        "modules" when known? ->
          update_thread(socket, id, &Map.put(&1, "modules", payload["modules"] || []))

        _request_event when known? and request? ->
          socket
          |> update_thread(id, &Map.put(&1, "request", payload["request"]))
          |> then(&if(event.event == "screenshot_asked", do: assign(&1, :later, false), else: &1))

        _ ->
          if known?, do: socket, else: history(socket, id)
      end

    tick(socket)
  end

  defp operator_spoke(socket, %{"author" => %{"kind" => "operator"}}, id) do
    case socket.assigns.typing do
      %{cid: ^id} -> assign(socket, :typing, nil)
      _ -> socket
    end
  end

  defp operator_spoke(socket, _message, _id), do: socket

  defp operator_typing(socket, id, %{"typing" => true} = payload) do
    token = make_ref()
    Process.send_after(self(), {:typing_off, token}, @typing_shown_ms)
    name = get_in(payload, ["operator", "name"])
    assign(socket, :typing, %{cid: id, name: name, token: token})
  end

  defp operator_typing(socket, id, _payload) do
    case socket.assigns.typing do
      %{cid: ^id} -> assign(socket, :typing, nil)
      _ -> socket
    end
  end

  # An answer from Nutshell — an operator's message, or a system line
  # that answers (nobody there, rejected, resolved, a screenshot asked,
  # called): read at once when the panel shows it, counted otherwise.
  # Lines the user caused or that only announce (searching, claimed,
  # sent, a callback asked) are not counted.
  @answers ~w(no_operator rejected resolved screenshot_asked called)

  defp arrived(socket, id, message) do
    cond do
      socket.assigns.open? and socket.assigns.current == id ->
        Support.read(id)
        socket

      answer?(message) ->
        socket |> assign(:unread, socket.assigns.unread + 1) |> notify()

      true ->
        socket
    end
  end

  defp answer?(%{"author" => %{"kind" => "operator"}}), do: true

  defp answer?(%{"author" => %{"kind" => "system"}, "content" => %{"code" => code}}),
    do: code in @answers

  defp answer?(_message), do: false

  # ---------- doing ----------

  defp open(socket) do
    socket = socket |> assign(open?: true, unread: 0) |> notify() |> tick()
    if id = socket.assigns.current, do: Support.read(id)
    socket
  end

  defp close(socket) do
    assign(socket, open?: false, closed_once: true, confirm_close: false)
  end

  defp show(socket, id) do
    if socket.assigns.open?, do: Support.read(id)

    socket
    |> forget_uploads()
    |> assign(current: id, confirm_close: false, later: false, draft: "")
  end

  # Files chosen for one request never ride into another.
  defp forget_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.files.entries, socket, &cancel_upload(&2, :files, &1.ref))
  end

  defp history(socket, id) do
    start_async(socket, {:history, id}, fn -> Support.history(id) end)
  end

  defp call(socket, op, fun) do
    case socket.assigns.current do
      nil ->
        {:noreply, socket}

      id ->
        {:noreply,
         socket
         |> assign(busy: op, notice: nil)
         |> start_async({:request, op, id}, fn -> fun.(id) end)}
    end
  end

  defp send_text(socket, cid, body) do
    run(socket, %{
      ref: System.unique_integer([:positive]),
      cid: cid,
      kind: :text,
      body: body,
      status: :sending
    })
  end

  defp send_file(socket, cid, file, caption) do
    run(socket, %{
      ref: System.unique_integer([:positive]),
      cid: cid,
      kind: :file,
      body: caption,
      name: file.name,
      size: file.size,
      path: file.path,
      type: file.type,
      status: :sending
    })
  end

  defp run(socket, item) do
    pending =
      if Enum.any?(socket.assigns.pending, &(&1.ref == item.ref)),
        do: Enum.map(socket.assigns.pending, &if(&1.ref == item.ref, do: item, else: &1)),
        else: socket.assigns.pending ++ [item]

    work =
      case item do
        %{kind: :text, cid: cid, body: body} ->
          fn -> Support.send_message(cid, body) end

        %{kind: :file, cid: cid, path: path, name: name, type: type, body: caption} ->
          fn -> Support.attach(cid, path, name, type, caption) end
      end

    socket |> assign(:pending, pending) |> start_async({:send, item.ref}, work)
  end

  defp sent(socket, ref, result) do
    case Enum.find(socket.assigns.pending, &(&1.ref == ref)) do
      nil ->
        socket

      item ->
        case result do
          {:ok, {:ok, %{"message" => message}}} ->
            forget_file(item)

            socket
            |> assign(:pending, Enum.reject(socket.assigns.pending, &(&1.ref == ref)))
            |> update_thread(item.cid, &merge_messages(&1, [message]))

          other ->
            reason = failure(other)

            socket
            |> assign(
              :pending,
              Enum.map(
                socket.assigns.pending,
                &if(&1.ref == ref, do: %{&1 | status: :failed}, else: &1)
              )
            )
            |> assign(
              :notice,
              if(reason in [:over, :too_large, :unsupported_type], do: Copy.failure(reason))
            )
        end
    end
  end

  defp forget_file(%{kind: :file, path: path}), do: File.rm(path)
  defp forget_file(_item), do: :ok

  defp typing(socket, draft) do
    id = socket.assigns.current
    now = System.monotonic_time(:millisecond)
    last = socket.assigns.typing_at

    cond do
      is_nil(id) or String.trim(draft) == "" ->
        if last && id, do: Support.typing(id, false)
        assign(socket, :typing_at, nil)

      is_nil(last) or now - last >= @typing_every_ms ->
        Support.typing(id, true)
        assign(socket, :typing_at, now)

      true ->
        socket
    end
  end

  # Sauron hears the user is on the app — and on which page — for each
  # of their requests not over; the client says `false` once this
  # process is gone.
  defp present_all(socket) do
    for {id, thread} <- socket.assigns.threads, not over?(thread) do
      Support.present(id, socket.assigns.page)
    end

    socket
  end

  # The seconds of « Nous cherchons quelqu'un », while the panel shows them.
  defp tick(socket) do
    thread = socket.assigns.threads[socket.assigns.current]

    if socket.assigns.open? and searching?(thread) and not socket.assigns.ticking and
         connected?(socket) do
      Process.send_after(self(), :tick, 1_000)
      assign(socket, ticking: true, now: DateTime.utc_now())
    else
      socket
    end
  end

  # The unread count to the page's LiveView (`SauronReporter.Support.Hook`).
  defp notify(socket) do
    if transport = socket.transport_pid do
      for {pid, :listener} <- Registry.lookup(@registry, transport),
          do: send(pid, {Support, :unread, socket.assigns.unread})
    end

    socket
  rescue
    _ -> socket
  end

  # ---------- threads ----------

  defp continuing?(thread) do
    not over?(thread) and
      (kind(thread) == :live_chat or not is_binary(get_in(thread, ["request", "submitted_at"])))
  end

  defp put_thread(socket, %{"conversation" => %{"id" => id}} = thread) do
    if socket.assigns.user["id"] == get_in(thread, ["conversation", "user", "id"]) do
      threads =
        Map.update(socket.assigns.threads, id, normalize(thread), fn known ->
          known
          |> Map.merge(Map.take(thread, ["conversation", "request", "modules"]))
          |> merge_messages(thread["messages"] || [])
        end)

      assign(socket, :threads, threads)
    else
      # Never a conversation of another user's.
      socket
    end
  end

  defp put_thread(socket, _thread), do: socket

  defp normalize(thread) do
    thread
    |> Map.put("messages", [])
    |> Map.put_new("modules", [])
    |> merge_messages(thread["messages"] || [])
  end

  defp update_thread(socket, id, fun) do
    case socket.assigns.threads do
      %{^id => thread} ->
        assign(socket, :threads, Map.put(socket.assigns.threads, id, fun.(thread)))

      _ ->
        socket
    end
  end

  # Messages by id — one may come both in a reply and an event — in
  # their order.
  defp merge_messages(thread, messages) do
    known = Map.new(thread["messages"] || [], &{&1["id"], &1})

    merged =
      messages
      |> Enum.filter(&(is_map(&1) and is_binary(&1["id"])))
      |> Enum.reduce(known, &Map.put(&2, &1["id"], &1))
      |> Map.values()
      |> Enum.sort_by(&{sort_time(&1["inserted_at"]), &1["id"]})

    Map.put(thread, "messages", merged)
  end

  defp sort_time(at) do
    case Copy.parse(at) do
      nil -> 0
      at -> DateTime.to_unix(at, :microsecond)
    end
  end
end
