defmodule SauronReporter.AnalyticsTest do
  use SauronReporter.AnalyticsCase, async: false

  alias SauronReporter.Analytics.Buffer

  describe "configuration" do
    test "enabled only when switched on, with an app and a way to deliver" do
      assert Analytics.enabled?()

      configure_analytics(enabled: false)
      refute Analytics.enabled?()

      configure_analytics(deliver: nil)
      assert Analytics.enabled?(), "url and token are enough"

      configure_analytics([deliver: nil], token: "")
      refute Analytics.enabled?()

      configure_analytics([], app: nil)
      refute Analytics.enabled?()

      Application.delete_env(:sauron_reporter, :analytics)
      refute Analytics.enabled?()
    end

    test "disabled, track sends nothing" do
      configure_analytics(enabled: false)
      assert :ok = Analytics.track(%{site: "www.example.fr"}, "signup")
      Analytics.flush()
      refute_receive {:delivered, _, _}, 50
    end
  end

  describe "user_id/1" do
    test "HMAC-SHA256 with the app's key, 32 hex characters, of the id as text" do
      expected =
        :crypto.mac(:hmac, :sha256, "test-user-key", "42")
        |> Base.encode16(case: :lower)
        |> binary_part(0, 32)

      assert Analytics.user_id(42) == expected
      assert Analytics.user_id("42") == expected
      assert Analytics.user_id(nil) == nil
    end

    test "nothing without a key: no user leaves the app" do
      configure_analytics(user_key: nil)
      assert Analytics.user_id(42) == nil
    end
  end

  describe "track/3" do
    test "from a map: a custom event with its props, filtered as Sauron would" do
      props =
        %{"plan" => "pro", seats: 3, ok: true, nested: %{a: 1}, list: [1]}
        |> Map.put(String.duplicate("k", 41), "too long a key")
        |> Map.merge(Map.new(1..12, &{"p#{String.pad_leading("#{&1}", 2, "0")}", &1}))

      :ok =
        Analytics.track(
          [
            site: "WWW.Example.fr",
            path: "/offres?token=x",
            ip: "203.0.113.7",
            ua: "Mozilla/5.0",
            user_id: 7
          ],
          :signup,
          props
        )

      [event] = flushed_events()

      assert %{
               "kind" => "event",
               "name" => "signup",
               "site" => "www.example.fr",
               "path" => "/offres",
               "ip" => "203.0.113.7",
               "ua" => "Mozilla/5.0",
               "user" => user,
               "at" => at
             } = event

      assert user == Analytics.user_id(7)
      assert {:ok, _, 0} = DateTime.from_iso8601(at)
      assert map_size(event["props"]) == 10
      # By name: "ok", "p01"… "p12", "plan", "seats" — the first ten.
      assert Map.keys(event["props"]) ==
               ["ok", "p01", "p02", "p03", "p04", "p05", "p06", "p07", "p08", "p09"]

      assert event["props"]["ok"] == "true"
    end

    test "without ip and ua, no visitor fields; without a site, nothing" do
      Analytics.track(%{site: "www.example.fr"}, "export")
      Analytics.track(%{path: "/x"}, "no site")

      [event] = flushed_events()
      refute Map.has_key?(event, "ip")
      refute Map.has_key?(event, "ua")
      refute Map.has_key?(event, "props")
    end

    test "from a conn: its host, path, visitor and user" do
      conn =
        Plug.Test.conn(:post, "https://www.example.fr/contact?x=1")
        |> Plug.Conn.put_req_header("user-agent", "Mozilla/5.0")
        |> Plug.Conn.assign(:sauron_user_id, "u-1")
        |> Map.put(:remote_ip, {203, 0, 113, 9})

      Analytics.track(conn, "contact", %{form: "devis"})

      assert [
               %{
                 "kind" => "event",
                 "site" => "www.example.fr",
                 "path" => "/contact",
                 "ip" => "203.0.113.9",
                 "ua" => "Mozilla/5.0",
                 "props" => %{"form" => "devis"},
                 "user" => user
               }
             ] = flushed_events()

      assert user == Analytics.user_id("u-1")
    end

    test "only the allowlisted sites, when there is a list" do
      configure_analytics(sites: ["www.example.fr"])
      Analytics.track(%{site: "www.example.fr"}, "kept")
      Analytics.track(%{site: "vm-cms.internal"}, "dropped")

      assert [%{"name" => "kept"}] = flushed_events()
    end

    @tag :capture_log
    test "never raises" do
      assert :ok = Analytics.track(:not_a_place, "x", "not props")
      assert :ok = Analytics.track(%{site: "a"}, %{"weird" => "name"})
    end
  end

  describe "ours (0.6.0)" do
    setup do
      configure_analytics(ignore_emails: ["@nutshell-lab.com", "Staff.Example.fr"])
    end

    test "an email under ignore_emails, without case; an entry without @ is a suffix too" do
      assert Analytics.ignored_email?("nathan@nutshell-lab.com")
      assert Analytics.ignored_email?("  Nathan@NUTSHELL-LAB.COM ")
      assert Analytics.ignored_email?("ops@staff.example.fr")

      assert Analytics.ignored_email?(%SauronReporter.Test.CiString{
               value: "A@Nutshell-Lab.com"
             })

      refute Analytics.ignored_email?("nathan@nutshell-lab.com.evil.fr")
      refute Analytics.ignored_email?("client@example.fr")
      refute Analytics.ignored_email?("")
      refute Analytics.ignored_email?(%{not: "text"})

      configure_analytics([])
      refute Analytics.ignored_email?("nathan@nutshell-lab.com"), "default: nobody"
    end

    test "the rule on assigns: the user_assign's email (default :current_user), or :sauron_ignore" do
      assert Analytics.ours_assigns?(%{current_user: %{id: 1, email: "x@nutshell-lab.com"}})
      refute Analytics.ours_assigns?(%{current_user: %{id: 1, email: "x@example.fr"}})
      refute Analytics.ours_assigns?(%{current_user: %{id: 1}})
      refute Analytics.ours_assigns?(%{current_user: %{id: 1, email: nil}})
      refute Analytics.ours_assigns?(%{})
      assert Analytics.ours_assigns?(%{sauron_ignore: true, current_user: %{id: 1}})
      refute Analytics.ours_assigns?(%{sauron_ignore: "yes"})

      configure_analytics(ignore_emails: ["@nutshell-lab.com"], user_assign: :admin)
      assert Analytics.ours_assigns?(%{admin: %{email: "x@nutshell-lab.com"}})
      refute Analytics.ours_assigns?(%{current_user: %{email: "x@nutshell-lab.com"}})
    end

    test "track/3 from an ours conn: :ok, nothing sent — by email, by assign, by cookie" do
      conn =
        Plug.Test.conn(:post, "https://www.example.fr/contact")
        |> Plug.Conn.put_req_header("user-agent", "Mozilla/5.0")

      staff = Plug.Conn.assign(conn, :current_user, %{id: 3, email: "n@nutshell-lab.com"})
      flagged = Plug.Conn.assign(conn, :sauron_ignore, true)
      cookie = Plug.Conn.put_req_header(conn, "cookie", "sauron_ignore=1")

      for ours <- [staff, flagged, cookie] do
        assert Analytics.ours?(ours)
        assert :ok = Analytics.track(ours, "contact")
      end

      refute Analytics.ours?(conn)
      Analytics.track(conn, "kept")
      assert [%{"name" => "kept"}] = flushed_events()
    end

    test "a map is never ours" do
      refute Analytics.ours?(%{site: "www.example.fr", sauron_ignore: true})
    end
  end

  describe "bot?/1" do
    test "Sauron's own test, monitors included" do
      for ua <- [
            "Mozilla/5.0 (compatible; Googlebot/2.1)",
            "curl/8.0",
            "Sauron/1.0 (+https://sauron.nutshell-lab.com)",
            "Mozilla/5.0 (compatible; UptimeRobot/2.0)",
            "Pingdom.com_bot_version_1.4",
            "Mozilla/5.0 (compatible; StatusCake)",
            "Better Stack Better Uptime Bot",
            "Checkly/1.0",
            "HetrixTools Uptime Monitoring Bot",
            "Site24x7",
            "check_http/v2.3 (nagios-plugins 2.3)",
            "Zabbix"
          ],
          do: assert(Analytics.bot?(ua), ua)

      refute Analytics.bot?(
               "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Mobile/15E148 Safari/604.1"
             )

      refute Analytics.bot?(nil)
    end
  end

  describe "the buffer" do
    test "sends as soon as batch_size events wait" do
      configure_analytics(batch_size: 3)
      for n <- 1..3, do: Analytics.track(%{site: "a.fr"}, "e#{n}")

      assert_receive {:delivered, "m2-app", %{"events" => events}}, 1_000
      assert Enum.map(events, & &1["name"]) == ["e1", "e2", "e3"]
    end

    test "sends every flush_every" do
      configure_analytics(flush_every: 30)
      Analytics.track(%{site: "a.fr"}, "tick")
      assert_receive {:delivered, "m2-app", %{"events" => [%{"name" => "tick"}]}}, 1_000
    end

    test "beyond max_buffer the oldest go, counted" do
      configure_analytics(max_buffer: 3)
      before = Analytics.stats()
      for n <- 1..5, do: Analytics.track(%{site: "a.fr"}, "e#{n}")

      stats = Analytics.stats()
      assert stats.dropped - before.dropped == 2
      assert stats.buffered == 3
      assert Enum.map(flushed_events(), & &1["name"]) == ["e3", "e4", "e5"]
    end

    test "at most 200 events in one send" do
      for n <- 1..250, do: Analytics.track(%{site: "a.fr"}, "e#{n}")
      Analytics.flush()
      assert_receive {:delivered, _, %{"events" => first}}
      assert_receive {:delivered, _, %{"events" => second}}
      assert {length(first), length(second)} == {200, 50}
    end

    @tag :capture_log
    test "a failed send loses its batch, counted, and tells telemetry" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:sauron_reporter, :analytics, :failed]])

      Application.put_env(:sauron_reporter, :test_reply, {:error, :econnrefused})
      before = Analytics.stats()

      Analytics.track(%{site: "a.fr"}, "lost")
      Analytics.track(%{site: "a.fr"}, "lost too")
      Analytics.flush()

      assert Analytics.stats().failed - before.failed == 2
      assert Analytics.stats().buffered == 0

      assert_receive {[:sauron_reporter, :analytics, :failed], ^ref, %{count: 2},
                      %{reason: :econnrefused, app: "m2-app"}}
    end

    test "Sauron's dropped is counted; sent tells telemetry" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:sauron_reporter, :analytics, :sent],
          [:sauron_reporter, :analytics, :dropped]
        ])

      Application.put_env(:sauron_reporter, :test_reply, {:ok, %{accepted: 1, dropped: 1}})
      before = Analytics.stats()

      Analytics.track(%{site: "a.fr"}, "a")
      Analytics.track(%{site: "a.fr"}, "b")
      Analytics.flush()

      stats = Analytics.stats()
      assert {stats.sent - before.sent, stats.dropped - before.dropped} == {1, 1}

      assert_receive {[:sauron_reporter, :analytics, :sent], ^ref, %{count: 1, dropped: 1}, _}

      assert_receive {[:sauron_reporter, :analytics, :dropped], ^ref, %{count: 1},
                      %{reason: :rejected}}
    end

    test "a buffer that is not running costs a cast, nothing more" do
      assert :ok = Buffer.push(%{"kind" => "event"})
    end
  end

  describe "over HTTP" do
    setup do
      configure_analytics(deliver: nil, req_options: [plug: {Req.Test, SauronReporter.Analytics}])
      :ok
    end

    # The buffer posts from its own process.
    defp stub(plug) do
      Req.Test.stub(SauronReporter.Analytics, plug)
      Req.Test.allow(SauronReporter.Analytics, self(), Process.whereis(Buffer))
    end

    test "POST /report/events with the report token, as JSON; 202's counts read" do
      test = self()

      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/report/events"

        assert Plug.Conn.get_req_header(conn, "authorization") == [
                 "Bearer test-report-token-00001"
               ]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:posted, Jason.decode!(body)})
        conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{accepted: 1, dropped: 1})
      end)

      before = Analytics.stats()
      Analytics.track(%{site: "a.fr"}, "a")
      Analytics.track(%{site: "a.fr"}, "b")
      Analytics.flush()

      assert_received {:posted, %{"events" => [%{"name" => "a"}, %{"name" => "b"}]}}
      stats = Analytics.stats()
      assert {stats.sent - before.sent, stats.dropped - before.dropped} == {1, 1}
    end

    @tag :capture_log
    test "a status but 202, or no answer: the batch is lost and counted" do
      stub(&Plug.Conn.send_resp(&1, 500, "not recorded"))
      before = Analytics.stats()
      Analytics.track(%{site: "a.fr"}, "a")
      Analytics.flush()
      assert Analytics.stats().failed - before.failed == 1

      stub(&Req.Test.transport_error(&1, :econnrefused))
      Analytics.track(%{site: "a.fr"}, "b")
      Analytics.flush()
      assert Analytics.stats().failed - before.failed == 2
    end
  end
end
