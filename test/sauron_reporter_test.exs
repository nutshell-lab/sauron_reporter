defmodule SauronReporterTest do
  # Sets the library's application config, so not async.
  use ExUnit.Case, async: false

  @token "test-report-token-00001"

  setup do
    previous = Application.get_all_env(:sauron_reporter)
    configure([])

    on_exit(fn ->
      for {k, _} <- Application.get_all_env(:sauron_reporter),
          do: Application.delete_env(:sauron_reporter, k)

      for {k, v} <- previous, do: Application.put_env(:sauron_reporter, k, v)
    end)
  end

  defp configure(extra) do
    for {k, _} <- Application.get_all_env(:sauron_reporter),
        do: Application.delete_env(:sauron_reporter, k)

    [
      url: "http://sauron.test/",
      token: @token,
      app: "m2-app",
      otp_apps: [:sauron_reporter],
      req_options: [plug: {Req.Test, SauronReporter}]
    ]
    |> Keyword.merge(extra)
    |> Enum.each(fn {k, v} -> Application.put_env(:sauron_reporter, k, v) end)
  end

  defp error(overrides \\ %{}) do
    struct(
      ErrorTracker.Error,
      Map.merge(
        %{
          id: 17,
          kind: "KeyError",
          reason: "key :caption not found",
          source_function: "M2Web.Asset.Identity.photos/2",
          source_line: "lib/m2_web/live/asset/identity.ex:318",
          fingerprint: String.duplicate("AB", 32),
          muted: false
        },
        overrides
      )
    )
  end

  defp occurrence(context \\ %{}, reason \\ "key :caption not found") do
    line = fn app, module, fun, file, n ->
      %ErrorTracker.Stacktrace.Line{
        application: app,
        module: module,
        function: fun,
        arity: 2,
        file: file,
        line: n
      }
    end

    %ErrorTracker.Occurrence{
      reason: reason,
      inserted_at: ~U[2026-10-14 08:44:40.000000Z],
      context: context,
      stacktrace: %ErrorTracker.Stacktrace{
        lines: [
          line.("elixir", "Enum", "map", "lib/enum.ex", 1688),
          line.(
            "sauron_reporter",
            "M2Web.Asset.Identity",
            "photos",
            "lib/m2_web/live/asset/identity.ex",
            318
          )
        ]
      }
    }
  end

  defp fire(error, occurrence) do
    SauronReporter.handle_event(
      [:error_tracker, :occurrence, :new],
      %{},
      %{error: error, occurrence: occurrence, muted: false},
      nil
    )
  end

  test "the payload: the occurrence, its frames marked, the context allowlisted" do
    payload =
      SauronReporter.payload(
        error(),
        occurrence(%{
          "request.method" => "GET",
          "request.path" => "/patrimoine/1/2",
          "request.params" => %{"password" => "x"},
          "request.headers" => %{"cookie" => "y"},
          "request.query" => "token=z",
          "job.args" => %{"id" => 1}
        })
      )

    assert payload["fingerprint"] == String.duplicate("AB", 32)
    assert payload["kind"] == "KeyError"
    assert payload["occurred_at"] == "2026-10-14T08:44:40.000000Z"

    assert [
             %{"app" => false, "application" => "elixir"},
             %{"app" => true, "module" => "M2Web.Asset.Identity", "arity" => 2}
           ] = payload["stacktrace"]

    assert Map.drop(payload["context"], ["node", "release.version"]) ==
             %{"request.method" => "GET", "request.path" => "/patrimoine/1/2"}

    assert payload["context"]["release.version"] ==
             to_string(Application.spec(:sauron_reporter, :vsn))
  end

  test "the reason: emails masked for every app, then the app's own redactor" do
    reason = "duplicate owner jane.doe+m2@example.fr on lot 12"
    payload = SauronReporter.payload(error(), occurrence(%{}, reason))
    assert payload["reason"] == "duplicate owner [email] on lot 12"

    configure(redact: {__MODULE__.Redactor, :reason})
    payload = SauronReporter.payload(error(), occurrence(%{}, reason))
    assert payload["reason"] == "duplicate owner [email] on lot [n]"
  end

  test "otp_app (one) is still understood, and version_app picks the release version" do
    configure(otp_apps: nil, otp_app: :sauron_reporter, version_app: :logger)
    payload = SauronReporter.payload(error(), occurrence())

    assert [%{"app" => false}, %{"app" => true}] = payload["stacktrace"]
    assert payload["context"]["release.version"] == to_string(Application.spec(:logger, :vsn))
  end

  test "what it posts: bearer token, JSON, the report path" do
    Req.Test.stub(SauronReporter, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      assert conn.request_path == "/report/errors"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:posted, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert {:ok, %Req.Response{status: 202}} =
             SauronReporter.deliver(SauronReporter.payload(error(), occurrence()))

    assert_received {:posted, %{"kind" => "KeyError", "dropped" => 0}}
  end

  test "in-process delivery, as Sauron reports its own errors" do
    configure(url: nil, token: nil, deliver: {__MODULE__.Inbox, :report})
    assert SauronReporter.configured?()

    assert {:ok, :group, :error_new} =
             SauronReporter.deliver(SauronReporter.payload(error(), occurrence()))

    assert_received {:in_process, "m2-app", %{"kind" => "KeyError"}}
  end

  test "configured only with an app and a way to deliver" do
    assert SauronReporter.configured?()
    configure(token: "")
    refute SauronReporter.configured?()
    configure(app: nil)
    refute SauronReporter.configured?()
  end

  @tag :capture_log
  test "a Sauron that does not answer costs nothing: no raise, an error tuple" do
    Req.Test.stub(SauronReporter, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, _} =
             SauronReporter.deliver(SauronReporter.payload(error(), occurrence()))
  end

  test "its own machinery never reports; a loop sends five a minute and counts the rest" do
    configure(self_noise: ["M2.Observability."])
    test = self()

    Req.Test.allow(SauronReporter, self(), fn ->
      Process.whereis(SauronReporter.TaskSupervisor)
    end)

    Req.Test.stub(SauronReporter, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posted, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 202, "")
    end)

    for f <- ["SauronReporter.deliver/1", "Elixir.M2.Observability.Something.run/0"],
        do: fire(error(%{source_function: f}), occurrence())

    refute_receive {:posted, _}, 200

    loop = error(%{fingerprint: "CD" <> String.duplicate("0", 62)})
    for _ <- 1..8, do: fire(loop, occurrence())

    for _ <- 1..5, do: assert_receive({:posted, %{"dropped" => 0}}, 1_000)
    refute_receive {:posted, _}, 200
    assert [{_, _minute, 5, 3}] = :ets.lookup(SauronReporter.Throttle, loop.fingerprint)
  end

  defmodule Redactor do
    def reason(reason), do: String.replace(reason, ~r/\d+/, "[n]")
  end

  defmodule Inbox do
    def report(app, payload) do
      send(self(), {:in_process, app, payload})
      {:ok, :group, :error_new}
    end
  end
end
