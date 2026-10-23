defmodule SauronReporter.SupportLiveTest.Page do
  use Phoenix.LiveView

  @users %{
    "42" => %{id: 42, name: "Camille Roussel", email: "camille@ville.fr"},
    "43" => %{id: 43, name: "Karim Benali", email: "karim@ville-cenon.fr"}
  }

  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       user: Map.fetch!(@users, params["user"] || "42"),
       launcher: params["menu"] != "1",
       path: nil
     )}
  end

  def handle_params(_params, uri, socket),
    do: {:noreply, assign(socket, :path, URI.parse(uri).path)}

  def render(assigns) do
    ~H"""
    <header>
      <button
        :if={not @launcher}
        id="menu"
        type="button"
        aria-label="Assistance"
        phx-click={SauronReporter.Support.open_panel()}
      >
        Assistance<span :if={@sauron_support_unread > 0} class="dot">{@sauron_support_unread}</span>
      </button>
    </header>
    <SauronReporter.Support.panel
      socket={@socket}
      user={@user}
      org={%{id: 7, name: "Ville de Wattrelos"}}
      title="Assistance"
      team="l'équipe m2"
      launcher={@launcher}
      page={@path}
    />
    """
  end
end

defmodule SauronReporter.SupportLiveTest.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
  end

  scope "/" do
    pipe_through(:browser)

    live_session :app, on_mount: [SauronReporter.Support.Hook] do
      live("/pages/:id", SauronReporter.SupportLiveTest.Page)
    end
  end
end

defmodule SauronReporter.SupportLiveTest.Endpoint do
  use Phoenix.Endpoint, otp_app: :sauron_reporter

  @session_options [store: :cookie, key: "_support_test", signing_salt: "supporttest"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Session, @session_options)
  plug(SauronReporter.SupportLiveTest.Router)
end

defmodule SauronReporter.SupportLiveTest do
  use SauronReporter.SupportCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @moduletag :capture_log

  @endpoint SauronReporter.SupportLiveTest.Endpoint
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0::size(64)>>

  setup_all do
    Application.put_env(:sauron_reporter, @endpoint,
      secret_key_base: String.duplicate("s", 64),
      live_view: [signing_salt: "support-test-salt"],
      pubsub_server: SauronReporter.TestPubSub,
      server: false
    )

    start_supervised!(@endpoint)
    :ok
  end

  defp page(path \\ "/pages/1") do
    {:ok, view, _html} = live(build_conn(), path)
    panel = find_live_child(view, "sauron-support")
    # The first resume answered.
    render_async(panel)
    {view, panel}
  end

  defp open(panel) do
    render_click(panel, "sauron_support:open", %{})
  end

  defp choose(panel, label) do
    panel |> element("button.aide-ch", label) |> render_click()
    render_async(panel)
  end

  defp say(panel, text) do
    panel |> form("#sauron-support-composer", %{message: text}) |> render_submit()
    render_async(panel, 2_000)
  end

  # What the panel shows once `text` is in it: Sauron's events arrive
  # through the socket, the client and the PubSub.
  defp shown(panel, text) do
    eventually(fn ->
      html = render(panel)
      html =~ text && html
    end)
  end

  # The conversation Camille's panel opened, as Sauron holds it.
  defp current(_panel) do
    eventually(fn ->
      case Support.resume(42) do
        {:ok, [%{"conversation" => %{"id" => id}} | _]} -> id
        _ -> nil
      end
    end)
  end

  test "renders nothing while support is off" do
    Application.delete_env(:sauron_reporter, :support)
    {:ok, view, html} = live(build_conn(), "/pages/1")
    refute html =~ "aide-launch"
    assert find_live_child(view, "sauron-support") == nil
  end

  test "the guided start, then a live chat an operator answers" do
    {_view, panel} = page()

    html = open(panel)
    assert html =~ ~s(role="dialog")
    assert html =~ "Assistance"
    assert html =~ "L&#39;équipe m2"
    assert html =~ "Bonjour Camille — comment pouvons-nous vous aider ?"
    assert html =~ "J&#39;ai une idée"
    assert html =~ "J&#39;ai un problème"
    assert html =~ "Parler à quelqu&#39;un"
    assert html =~ "Vos messages sont lus par l&#39;équipe m2."

    html = choose(panel, "Parler à quelqu'un")
    assert html =~ "Nous cherchons quelqu&#39;un de disponible…"
    assert html =~ "Sans réponse sous 5 minutes"
    assert html =~ "Nous cherchons quelqu&#39;un ·"
    assert html =~ ~s(aria-label="Fermer la demande")
    assert html =~ ~s(role="log")

    assert_received {:fake_sauron, "open", %{"kind" => "live_chat", "page" => "/pages/1"}}
    assert_receive {:fake_sauron, "presence", %{"present" => true, "page" => "/pages/1"}}

    id = current(panel)

    FakeSauron.typing(id, true)
    shown(panel, "Thomas écrit…")

    FakeSauron.operator_says(id, "Bonjour Camille, je regarde tout de suite.")
    html = shown(panel, "Bonjour Camille, je regarde tout de suite.")
    assert html =~ "Thomas, de l&#39;équipe m2, a rejoint la conversation"
    assert html =~ ~s(<i class="aide-on" aria-hidden="true"></i>Thomas, de l&#39;équipe m2)
    assert html =~ "Bonjour Camille, je regarde tout de suite."
    assert html =~ ~s(class="aide-b aide-them")
    assert html =~ "Écrivez à Thomas…"
    refute html =~ "Thomas écrit…"
    assert_receive {:fake_sauron, "read", %{"conversation_id" => ^id}}

    html = say(panel, "Firefox, sur la fiche du gymnase.")
    assert html =~ "Firefox, sur la fiche du gymnase."
    assert html =~ "Vous ·"

    assert [{"message", %{"body" => "Firefox, sur la fiche du gymnase."}}] =
             for({"message", _} = call <- FakeSauron.calls(), do: call)
  end

  @tag :tmp_dir
  test "a problem: described, a capture attached, then « Terminé »" do
    {_view, panel} = page()
    open(panel)

    html = choose(panel, "J'ai un problème")
    assert html =~ "Décrivez le problème : ce que vous faisiez"
    assert html =~ "Un problème · nous répondons par e-mail"
    assert html =~ "Terminé — envoyer la demande"
    assert html =~ "Votre demande part à l&#39;équipe m2"
    refute html =~ ~s(aria-label="Fermer la demande")

    upload =
      file_input(panel, "#sauron-support-composer", :files, [
        %{name: "capture-bibliotheque.png", content: @png, type: "image/png"}
      ])

    assert render_upload(upload, "capture-bibliotheque.png") =~ "capture-bibliotheque.png"
    assert render(panel) =~ ~s(aria-label="Retirer capture-bibliotheque.png")

    html = say(panel, "Le modèle s'ouvre sans ses clauses.")
    assert html =~ "Le modèle s&#39;ouvre sans ses clauses."
    assert html =~ "capture-bibliotheque.png"
    refute html =~ "Retirer capture-bibliotheque.png"

    id = current(panel)
    messages = FakeSauron.conversation(id).messages

    assert %{
             "content" => %{
               "type" => "image",
               "name" => "capture-bibliotheque.png",
               "caption" => "Le modèle s'ouvre sans ses clauses."
             }
           } = List.last(messages)

    panel |> element("button", "Terminé — envoyer la demande") |> render_click()
    html = render_async(panel)
    assert html =~ "C&#39;est envoyé à l&#39;équipe m2 : nous vous répondrons ici, ou par e-mail."
    assert html =~ "Demande envoyée · réponse par e-mail"
    assert html =~ "Ajouter un détail à votre demande"
    refute html =~ "Terminé — envoyer la demande"
    assert FakeSauron.conversation(id).request["submitted_at"]
  end

  test "nobody in five minutes: an email answer, or a callback" do
    {_view, panel} = page()
    open(panel)
    choose(panel, "Parler à quelqu'un")
    id = current(panel)

    FakeSauron.convert(id)
    html = shown(panel, "Votre numéro, pour être rappelé")

    assert html =~
             "Personne n&#39;est disponible pour le moment. Votre demande reste ouverte : nous vous répondrons par e-mail à camille@ville.fr."

    assert html =~ "Vous pouvez aussi demander à être rappelé."
    assert html =~ "Demande enregistrée · réponse par e-mail"
    assert html =~ "Votre numéro, pour être rappelé"
    refute html =~ "Sans réponse sous 5 minutes"
    refute html =~ "Nous cherchons quelqu&#39;un de disponible"

    panel |> form("#sauron-support-callback", %{phone: "06 39 98 42 17"}) |> render_submit()
    html = render_async(panel)
    assert html =~ "Rappel demandé au 06 39 98 42 17"
    refute html =~ "Votre numéro, pour être rappelé"
    assert FakeSauron.conversation(id).request["callback_phone"] == "06 39 98 42 17"
  end

  test "a screenshot asked: the banner, a capture button where the browser can, the image sent" do
    {_view, panel} = page()
    open(panel)
    choose(panel, "Parler à quelqu'un")
    id = current(panel)
    FakeSauron.operator_says(id, "Pouvez-vous me montrer l'écran ?")

    FakeSauron.ask_screenshot(id)
    html = shown(panel, "Plus tard")
    assert html =~ "Thomas vous demande une capture d&#39;écran"
    assert html =~ "Choisir une image"
    refute html =~ "Capturer cet écran"

    # The hook says the browser can capture.
    html = render_hook(panel, "capabilities", %{"capture" => true})
    assert html =~ "Capturer cet écran"
    assert html =~ "sauron:capture"

    upload =
      file_input(panel, "#sauron-support-composer", :files, [
        %{name: "capture-2026-10-23.png", content: @png, type: "image/png"}
      ])

    render_upload(upload, "capture-2026-10-23.png")
    html = say(panel, "")
    assert html =~ "capture-2026-10-23.png"
    refute html =~ "vous demande une capture d&#39;écran</p>"
    refute html =~ "Capturer cet écran"
    refute "screenshot" in FakeSauron.conversation(id).modules
  end

  test "« Plus tard » puts the banner away until the next request" do
    {_view, panel} = page()
    open(panel)
    choose(panel, "Parler à quelqu'un")
    id = current(panel)

    FakeSauron.ask_screenshot(id)
    shown(panel, "Plus tard")
    panel |> element("button", "Plus tard") |> render_click()
    refute render(panel) =~ "Plus tard"
  end

  test "a message written while the link is down goes once it is back" do
    {_view, panel} = page()
    open(panel)
    choose(panel, "Parler à quelqu'un")
    id = current(panel)

    FakeSauron.accept(false)
    FakeSauron.drop_connections()
    assert eventually(fn -> render(panel) =~ "Connexion à l&#39;assistance interrompue" end)

    html =
      panel
      |> form("#sauron-support-composer", %{message: "Toujours là ?"})
      |> render_submit()

    assert html =~ "Toujours là ?"
    assert html =~ "Envoi…"

    FakeSauron.accept(true)
    html = render_async(panel, 5_000)
    refute html =~ "Envoi…"
    refute html =~ "Connexion à l&#39;assistance interrompue"

    assert [%{"content" => %{"body" => "Toujours là ?"}}] =
             Enum.filter(FakeSauron.conversation(id).messages, &(&1["author"]["kind"] == "user"))
  end

  test "closing a live chat asks first; then a new request starts over" do
    {_view, panel} = page()
    open(panel)
    choose(panel, "Parler à quelqu'un")
    id = current(panel)

    html = panel |> element(~s(button[aria-label="Fermer la demande"])) |> render_click()
    assert html =~ "Clore cette demande ? Vous ne pourrez plus y écrire."
    panel |> element("button", "Annuler") |> render_click()
    refute render(panel) =~ "Clore cette demande ?"

    panel |> element(~s(button[aria-label="Fermer la demande"])) |> render_click()
    panel |> element("button", "Clore la demande") |> render_click()
    html = render_async(panel)
    assert html =~ "Cette demande est close."
    assert html =~ "Demande close"
    refute html =~ "sauron-support-composer"
    assert FakeSauron.conversation(id).request["state"] == "closed"

    html = panel |> element("button", "Nouvelle demande") |> render_click()
    assert html =~ "comment pouvons-nous vous aider ?"
  end

  test "files chosen for one request do not ride into the next" do
    {_view, panel} = page()
    open(panel)
    choose(panel, "J'ai un problème")

    panel
    |> file_input("#sauron-support-composer", :files, [
      %{name: "oubli.png", content: @png, type: "image/png"}
    ])
    |> render_upload("oubli.png")

    panel |> element("button", "Terminé — envoyer la demande") |> render_click()
    render_async(panel)
    panel |> element("button", "Faire une autre demande") |> render_click()
    choose(panel, "J'ai une idée")
    refute render(panel) =~ "oubli.png"
  end

  test "a request the user left mid-way opens again by itself" do
    {:ok, _} = Support.open(%{id: 42, name: "Camille Roussel"}, nil, :live_chat)
    {_view, panel} = page()
    html = open(panel)
    assert html =~ "Nous cherchons quelqu&#39;un de disponible…"
  end

  test "another user never sees a conversation not theirs" do
    {_view, camille} = page("/pages/1")
    {_view, karim} = page("/pages/1?user=43")
    open(camille)
    open(karim)
    choose(camille, "Parler à quelqu'un")
    id = current(camille)

    FakeSauron.operator_says(id, "Pour Camille seulement.")
    shown(camille, "Pour Camille seulement.")
    refute render(karim) =~ "Pour Camille seulement."

    # An event that names Karim but carries Camille's conversation: the
    # panel asks for it, and keeps nothing that is not Karim's.
    FakeSauron.push("message", %{
      "conversation_id" => id,
      "user_id" => "43",
      "message" => %{
        "id" => Ecto.UUID.generate(),
        "author" => %{"kind" => "operator", "name" => "Thomas"},
        "content" => %{"type" => "text", "body" => "Mal adressé."},
        "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })

    Process.sleep(100)
    html = render_async(karim)
    refute html =~ "Mal adressé."
    refute html =~ "Pour Camille seulement."
    assert html =~ "Bonjour Karim"
  end

  test "the launcher counts the answers that arrive while the panel is closed" do
    {_view, panel} = page()
    open(panel)
    choose(panel, "Parler à quelqu'un")
    id = current(panel)
    render_click(panel, "close_panel", %{})

    FakeSauron.operator_says(id, "Je suis là.")
    html = shown(panel, "1 nouvelle réponse")
    assert html =~ ~s(aria-label="Assistance, 1 nouvelle réponse")
    assert html =~ ~s(<span class="aide-badge" aria-hidden="true">1</span>)

    # A screenshot asked is an answer too; the claim was not.
    FakeSauron.ask_screenshot(id)
    shown(panel, "Assistance, 2 nouvelles réponses")

    html = open(panel)
    refute html =~ "aide-badge"
    assert html =~ "Je suis là."
  end

  test "the menu variant: no launcher, the app's button opens the panel and shows the unread count" do
    {view, panel} = page("/pages/1?menu=1")
    refute render(panel) =~ "aide-launch"

    html = render(view)
    assert html =~ "sauron_support:open"
    assert html =~ "#sauron-support"

    # LiveViewTest does not follow a JS push's target to another
    # LiveView: the browser does; the panel takes the event it names.
    assert view |> element("#menu") |> render() =~
             "&quot;target&quot;:&quot;#sauron-support&quot;"

    assert render_click(panel, "sauron_support:open", %{}) =~ ~s(role="dialog")

    choose(panel, "Parler à quelqu'un")
    id = current(panel)
    render_click(panel, "close_panel", %{})

    FakeSauron.operator_says(id, "Une réponse.")
    assert eventually(fn -> render(view) =~ ~s(<span class="dot">1</span>) end)
  end

  test "the page follows live navigation" do
    {view, panel} = page()
    open(panel)
    choose(panel, "Parler à quelqu'un")
    _ = current(panel)

    render_patch(view, "/pages/2?token=x")
    assert_receive {:fake_sauron, "presence", %{"present" => true, "page" => "/pages/2"}}, 1_000
  end

  test "the stylesheet takes every colour, face and radius from --aide-* variables" do
    css = Support.css()

    for var <- ~w(--aide-font --aide-bg --aide-surface --aide-ink --aide-muted --aide-line
                  --aide-field --aide-accent --aide-accent-ink --aide-mark --aide-ok
                  --aide-radius --aide-button-radius --aide-top) do
      assert css =~ "var(#{var},", "#{var} not used with a default"
    end

    # No colour outside a variable's default but the badge's white and the shadow.
    rules = Regex.replace(~r/var\(--aide-[a-z-]+, [^)]+\)/, css, "")
    rules = Regex.replace(~r{/\*.*?\*/}s, rules, "")
    assert Regex.scan(~r/#[0-9A-Fa-f]{3,6}\b/, rules) == [["#FFFFFF"]]

    assert render_component(&Support.styles/1, %{}) =~ "--aide-accent"
  end
end
