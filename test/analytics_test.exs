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

  describe "paths carry no secret (0.6.1)" do
    # A booking's cancel token (phx-cms: 24 random bytes, url-safe), an
    # AshAuthentication magic link's JWT, a Phoenix.Token.
    @booking "Xb3kQ9vN2mLp7RtY5wZc1HfJ8sDg4AeU"
    @jwt "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyPzEyMyJ9.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    @phoenix_token "SFMyNTY.g2gDbQAAAAZ1c2VyOjFuBgCQ8VxXkwFiAAFRgA.k3lC9vR8sXqY2Wm-ZtP0aE7nH5jU4oL1iG6fD3bQ_cA"

    test "token-shaped segments: hex, signed, long url-safe with a digit or both cases" do
      for segment <- [
            @booking,
            # The same, drawn without a digit: both cases tell.
            "XbkQvNmLpRtYwZcHfJsDgAeUoPiKjMnB",
            @jwt,
            @phoenix_token,
            String.duplicate("a1b2c3d4", 4),
            :crypto.strong_rand_bytes(32) |> Base.encode16(),
            :crypto.strong_rand_bytes(16) |> Base.url_encode64(),
            # Lowercase, one word, a digit: base32, not a slug.
            "mfrggzdfmztwq2lknnwg23tp",
            "aB3dE5gH7jK9mN1pQ2rS"
          ],
          do: assert(Analytics.token?(segment), segment)
    end

    test "not a secret: slugs, ids, UUIDs, file names, short or plain words" do
      for segment <- [
            "l-ia-dans-un-back-office",
            "why-we-build-in-elixir",
            "rapport-annuel-2024-version-finale-v2",
            "comment-participer",
            "with_invitation",
            "calendrier.ics",
            "jquery.min.js",
            "app-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d.css",
            "0b1e7f7c-6a40-4b8e-9d1f-3c5a2e8f9b10",
            "0B1E7F7C-6A40-4B8E-9D1F-3C5A2E8F9B10",
            "42",
            "1234567890123456789",
            "aB3dE5gH7jK9mN1pQ2r",
            "patrimoine",
            "administrationgenerale",
            ":id",
            ""
          ],
          do: refute(Analytics.token?(segment), segment)

      refute Analytics.token?(nil)
    end

    test "the paths of our apps, as they are" do
      for path <- [
            "/dossiers/l-ia-dans-un-back-office",
            "/en/blog/why-we-build-in-elixir",
            "/patrimoine/0b1e7f7c-6a40-4b8e-9d1f-3c5a2e8f9b10/5f0c2a9e-1d3b-4c7a-8e6f-2b9d4a1c3e70",
            "/patrimoine/12/345",
            "/rendez-vous/annuler",
            "/",
            "/offres/"
          ],
          do: assert(Analytics.path(path) == path, path)
    end

    test "a token-shaped segment is sent as :token, wherever it is" do
      assert Analytics.path("/magic_link/#{@jwt}") == "/magic_link/:token"

      assert Analytics.path("/rendez-vous/annuler/#{@booking}?x=1") ==
               "/rendez-vous/annuler/:token"

      assert Analytics.path("/rendez-vous/#{@booking}/calendrier.ics") ==
               "/rendez-vous/:token/calendrier.ics"

      assert Analytics.path("/fr/checkin/ticket/#{@phoenix_token}/") ==
               "/fr/checkin/ticket/:token/"
    end

    test "mask_tokens: false sends them as they are" do
      configure_analytics(mask_tokens: false)
      assert Analytics.path("/magic_link/#{@jwt}") == "/magic_link/#{@jwt}"
    end

    test "redact_paths: the whole path by segment, :name sent as itself, * kept" do
      configure_analytics(
        mask_tokens: false,
        redact_paths: [
          "/annuler/:token",
          "/rendez-vous/:token/calendrier.ics",
          "/*/magiclink/:token",
          "/invitations/:id/:code/"
        ]
      )

      assert Analytics.path("/annuler/short") == "/annuler/:token"
      assert Analytics.path("/annuler/short/") == "/annuler/:token/"

      assert Analytics.path("/rendez-vous/abc/calendrier.ics") ==
               "/rendez-vous/:token/calendrier.ics"

      assert Analytics.path("/en/magiclink/abc") == "/en/magiclink/:token"
      assert Analytics.path("/invitations/7/abc") == "/invitations/:id/:code"

      # The whole path: not a prefix, not a shorter one, not an empty segment.
      for path <- [
            "/annuler/short/plus",
            "/annuler",
            "/annuler/",
            "/x/annuler/short",
            "/magiclink/abc",
            "/rendez-vous/abc/autre.ics",
            "/en//magiclink/abc"
          ],
          do: assert(Analytics.path(path) == path, path)
    end

    test "the first pattern that matches applies; masking follows it" do
      configure_analytics(redact_paths: ["/a/:first", "/a/:second", "/b/:code"])
      assert Analytics.path("/a/1") == "/a/:first"
      assert Analytics.path("/b/x/#{@booking}") == "/b/x/:token"
    end

    test "a pattern that cannot be read loses the path, never leaks it" do
      configure_analytics(redact_paths: [%{not: "a pattern"}])
      assert Analytics.path("/annuler/#{@booking}") == nil
    end

    test "track/3: the path without its secret" do
      Analytics.track(%{site: "www.example.fr", path: "/annuler/#{@booking}"}, "cancel")
      assert [%{"path" => "/annuler/:token"}] = flushed_events()
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
