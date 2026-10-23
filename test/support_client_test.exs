defmodule SauronReporter.SupportClientTest do
  use SauronReporter.SupportCase, async: false

  alias SauronReporter.Support.Event

  @moduletag :capture_log

  @user %{id: 42, name: "Camille Roussel", email: "camille@ville.fr"}
  @org %{id: 7, name: "Ville de Wattrelos"}

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0::size(64)>>

  defp open!(kind \\ :live_chat, user \\ @user) do
    {:ok, %{"conversation" => %{"id" => id}} = thread} =
      Support.open(user, @org, kind, page: "/patrimoine/12?tab=etat")

    {id, thread}
  end

  test "inert without configuration: never connects, every call says so" do
    Application.delete_env(:sauron_reporter, :support)
    restart_client()

    assert %{status: :idle} = Support.status()
    refute Support.enabled?()
    assert {:error, :disabled} = Support.open(@user, @org, :issue)
    assert :ok = Support.typing("x", true)
  end

  test "joins support:<app> with the token in x-sauron-token" do
    assert %{status: :joined} = Support.status()

    # Another token: refused at the upgrade, never joined.
    Application.put_env(:sauron_reporter, :token, "not-the-token")
    restart_client()
    Process.sleep(150)
    assert %{status: :connecting} = Support.status()
  end

  test "the socket URL follows the reporter's url" do
    Application.put_env(:sauron_reporter, :url, "https://sauron.example.com/")
    assert Support.socket_url() == "wss://sauron.example.com/support/socket/websocket"

    Application.put_env(:sauron_reporter, :support, socket_url: "ws://other/s/websocket")
    assert Support.socket_url() == "ws://other/s/websocket"
  end

  test "calls answer Sauron's replies; its reasons as atoms" do
    {id, thread} = open!(:issue)

    assert %{"request" => %{"kind" => "issue"}, "modules" => ["text", "upload", "submit"]} =
             thread

    assert [%{"author" => %{"kind" => "system"}}] = thread["messages"]

    assert_received {:fake_sauron, "open", payload}

    assert payload == %{
             "kind" => "issue",
             "user" => %{"id" => "42", "name" => "Camille Roussel", "email" => "camille@ville.fr"},
             "org" => %{"id" => "7", "name" => "Ville de Wattrelos"},
             # No query: the page as analytics sends a path.
             "page" => "/patrimoine/12"
           }

    assert {:ok, %{"message" => %{"content" => %{"body" => "Bonjour"}}}} =
             Support.send_message(id, "Bonjour")

    assert {:ok, %{"request" => %{"submitted_at" => at}}} = Support.submit(id)
    assert is_binary(at)

    assert {:error, :not_found} = Support.send_message(Ecto.UUID.generate(), "Allô")
    assert {:error, {:invalid, _}} = SauronReporter.Support.Client.call("open", %{})

    assert {:ok, [%{"conversation" => %{"id" => ^id}}]} = Support.resume(42)
    assert {:ok, %{"messages" => messages}} = Support.history(id)
    assert length(messages) == 3

    assert {:ok, %{"request" => %{"state" => "closed"}}} = Support.close(id)
    assert {:error, :over} = Support.send_message(id, "encore")
  end

  test "Sauron's events reach the user's and the conversation's topics, no one else's" do
    {id, _} = open!()
    {other, _} = open!(:live_chat, %{id: 43, name: "Karim"})

    Support.subscribe(42)
    Phoenix.PubSub.subscribe(SauronReporter.TestPubSub, Support.conversation_topic(id))
    Phoenix.PubSub.subscribe(SauronReporter.TestPubSub, Support.user_topic(44))

    FakeSauron.operator_says(id, "Je regarde.")

    # claimed, the system's line, the operator's message — on both topics.
    for _ <- 1..2 do
      assert_receive {Support, %Event{event: "claimed", conversation_id: ^id, user_id: "42"}}
    end

    assert_receive {Support,
                    %Event{
                      event: "message",
                      payload: %{"message" => %{"author" => %{"kind" => "operator"}}}
                    }}

    FakeSauron.operator_says(other, "Pour Karim.")
    refute_receive {Support, %Event{conversation_id: ^other}}, 200
  end

  test "a call while the link is down waits, and goes once it is back, in order" do
    {id, _} = open!(:issue)
    Support.subscribe_link()

    FakeSauron.accept(false)
    FakeSauron.drop_connections()
    assert_receive {Support, :link, :down}, 1_000

    first = Task.async(fn -> Support.send_message(id, "un") end)
    Process.sleep(30)
    second = Task.async(fn -> Support.send_message(id, "deux") end)
    eventually(fn -> Support.status().buffered == 2 end)

    FakeSauron.accept(true)
    assert_receive {Support, :link, :up}, 2_000

    assert {:ok, %{"message" => %{"content" => %{"body" => "un"}}}} = Task.await(first)
    assert {:ok, %{"message" => %{"content" => %{"body" => "deux"}}}} = Task.await(second)

    bodies = for {"message", %{"body" => body}} <- FakeSauron.calls(), do: body
    assert bodies == ["un", "deux"]
    assert %{buffered: 0, in_flight: 0} = Support.status()
  end

  test "the buffer is bounded and its calls expire" do
    Application.put_env(
      :sauron_reporter,
      :support,
      Keyword.merge(Support.config(), max_buffer: 1, buffer_ttl: 300)
    )

    {id, _} = open!(:issue)
    FakeSauron.accept(false)
    FakeSauron.drop_connections()
    await_status(:connecting)

    waiting = Task.async(fn -> Support.send_message(id, "attend") end)
    eventually(fn -> Support.status().buffered == 1 end)
    assert {:error, :buffer_full} = Support.send_message(id, "de trop")

    assert {:error, :disconnected} = Task.await(waiting)
    refute Enum.any?(FakeSauron.calls(), &match?({"message", _}, &1))
  end

  test "presence: said for a screen, again after a reconnection, false when the screen goes" do
    {id, _} = open!()

    screen =
      spawn(fn ->
        Support.present(id, "/contrats/3?q=secret")

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:fake_sauron, "presence",
                    %{"conversation_id" => ^id, "present" => true, "page" => "/contrats/3"}}

    FakeSauron.drop_connections()
    assert_receive {:fake_sauron, "presence", %{"present" => true}}, 2_000

    send(screen, :stop)
    assert_receive {:fake_sauron, "presence", %{"conversation_id" => ^id, "present" => false}}
  end

  test "casts go when the link is up" do
    {id, _} = open!()
    Support.typing(id, true)
    Support.read(id)
    assert_receive {:fake_sauron, "typing", %{"conversation_id" => ^id, "typing" => true}}
    assert_receive {:fake_sauron, "read", %{"conversation_id" => ^id}}
  end

  test "each message carries a ref; the same ref again answers the first message, posted once" do
    {id, _} = open!(:issue)

    assert {:ok, %{"message" => %{"id" => first, "ref" => ref}}} = Support.send_message(id, "un")
    assert is_binary(ref) and byte_size(ref) >= 16

    assert {:ok, %{"message" => %{"id" => ^first}}} = Support.send_message(id, "un", ref: ref)
    assert {:ok, %{"message" => %{"id" => other}}} = Support.send_message(id, "un")
    assert other != first

    users = Enum.filter(FakeSauron.conversation(id).messages, &(&1["author"]["kind"] == "user"))
    assert length(users) == 2
  end

  test "a message in flight when the link drops is pushed again once joined, under its ref" do
    {id, _} = open!(:issue)
    FakeSauron.hold("message")

    task = Task.async(fn -> Support.send_message(id, "perdu en route ?", ref: "ref-1") end)
    assert_receive {:fake_sauron, "message", %{"ref" => "ref-1"}}, 1_000
    FakeSauron.drop_connections()

    assert {:ok, %{"message" => %{"ref" => "ref-1", "id" => message_id}}} = Task.await(task)

    assert [%{"id" => ^message_id}] =
             Enum.filter(FakeSauron.conversation(id).messages, &(&1["author"]["kind"] == "user"))

    assert ["ref-1", "ref-1"] = for({"message", %{"ref" => r}} <- FakeSauron.calls(), do: r)
    assert %{buffered: 0, in_flight: 0} = Support.status()
  end

  test "a call Sauron would not answer the same twice is never pushed again" do
    {id, _} = open!(:issue)
    FakeSauron.hold("submit")

    task = Task.async(fn -> Support.submit(id) end)
    assert_receive {:fake_sauron, "submit", _}, 1_000
    FakeSauron.drop_connections()

    assert {:error, :disconnected} = Task.await(task)
    await_status(:joined)
    Process.sleep(50)
    assert [_] = for({"submit", _} = call <- FakeSauron.calls(), do: call)
  end

  test "an in-flight retry still expires with the buffer's time" do
    Application.put_env(
      :sauron_reporter,
      :support,
      Keyword.merge(Support.config(), buffer_ttl: 300)
    )

    {id, _} = open!(:issue)
    FakeSauron.hold("message")
    task = Task.async(fn -> Support.send_message(id, "trop tard") end)
    assert_receive {:fake_sauron, "message", _}, 1_000

    FakeSauron.accept(false)
    FakeSauron.drop_connections()
    assert {:error, :disconnected} = Task.await(task, 5_000)
  end

  test "resumes asked together go in one resume_many, each caller its user's threads" do
    {mine, _} = open!(:live_chat)
    {karims, _} = open!(:live_chat, %{id: 43, name: "Karim"})

    tasks = for user <- [42, 43, 44, 42], do: Task.async(fn -> Support.resume(user) end)

    assert [
             {:ok, [%{"conversation" => %{"id" => ^mine}}]},
             {:ok, [%{"conversation" => %{"id" => ^karims}}]},
             {:ok, []},
             {:ok, [%{"conversation" => %{"id" => ^mine}}]}
           ] = Enum.map(tasks, &Task.await/1)

    assert [{"resume_many", %{"user_ids" => ids}}] =
             for({"resume" <> _, _} = call <- FakeSauron.calls(), do: call)

    assert Enum.sort(ids) == ["42", "43", "44"]
  end

  test "resume_many asks 200 users at most" do
    Application.put_env(
      :sauron_reporter,
      :support,
      Keyword.merge(Support.config(), resume_window: 300)
    )

    tasks = for user <- 1..450, do: Task.async(fn -> Support.resume(user) end)
    assert Enum.all?(tasks, &(Task.await(&1) == {:ok, []}))

    sizes = for {"resume_many", %{"user_ids" => ids}} <- FakeSauron.calls(), do: length(ids)
    assert Enum.sort(sizes, :desc) == [200, 200, 50]
  end

  test "a resume while the link is down waits for it" do
    {mine, _} = open!(:live_chat)
    FakeSauron.accept(false)
    FakeSauron.drop_connections()
    await_status(:connecting)

    task = Task.async(fn -> Support.resume(42) end)
    eventually(fn -> Support.status().buffered == 1 end)
    FakeSauron.accept(true)

    assert {:ok, [%{"conversation" => %{"id" => ^mine}}]} = Task.await(task)
  end

  @tag :tmp_dir
  test "a file is read back for its user only, bounded", %{tmp_dir: dir} do
    {id, _} = open!(:issue)
    png = Path.join(dir, "capture.png")
    File.write!(png, @png)
    {:ok, %{"id" => file_id}} = Support.upload(id, png, "capture.png", "image/png")

    assert {:ok, %{content_type: "image/png", body: @png}} = Support.fetch_file(file_id, 42)
    assert {:error, :not_found} = Support.fetch_file(file_id, 43)
    assert {:error, :not_found} = Support.fetch_file(Ecto.UUID.generate(), 42)
    assert {:error, :too_large} = Support.fetch_file(file_id, 42, max_size: 8)
    assert {:error, :unsupported_type} = Support.fetch_file(file_id, 42, types: ["image/gif"])
    assert {:error, :not_found} = Support.fetch_file(file_id, nil)
    assert Enum.all?(FakeSauron.fetches(), fn {_, user} -> user in ["42", "43"] end)
  end

  @tag :tmp_dir
  test "a file goes to the files API with the token, then into the conversation", %{tmp_dir: dir} do
    {id, _} = open!(:issue)
    png = Path.join(dir, "capture.png")
    File.write!(png, @png)

    assert {:ok, %{"message" => %{"content" => content}}} =
             Support.attach(id, png, "capture.png", "image/png", "L'écran")

    assert %{"type" => "image", "name" => "capture.png", "caption" => "L'écran"} = content

    text = Path.join(dir, "notes.txt")
    File.write!(text, "pas une image")
    assert {:error, :unsupported_type} = Support.upload(id, text, "notes.txt", "text/plain")
    assert {:error, :not_found} = Support.upload(Ecto.UUID.generate(), png, "x.png")

    Application.put_env(:sauron_reporter, :token, "wrong")
    assert {:error, :unauthorized} = Support.upload(id, png, "x.png")
  end
end
