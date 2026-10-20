# SauronReporter

Sends an Elixir app's errors — and, opt-in, its visits (0.5.0) — to
[Sauron](https://sauron.nutshell-lab.com), the Nutshell fleet's error
manager: every occurrence
[ErrorTracker](https://hex.pm/packages/error_tracker) captures becomes a
small JSON summary posted to Sauron's `POST /report/errors`, where it is
grouped, alerted once per new error and classified.

One library for every Elixir app of the fleet — Sauron included — so the
contract with Sauron is written once. What leaves the app is listed in
`SauronReporter`'s moduledoc: kind, reason (emails masked), source,
stack trace and an allowlisted context. Never params, query strings,
IPs, headers or job arguments.

## Use

```elixir
# mix.exs
{:sauron_reporter, github: "nutshell-lab/sauron_reporter", tag: "v0.5.0"}
```

ErrorTracker is configured by the app (its repo is the local buffer):

```elixir
# config/config.exs — off until a token says otherwise
config :error_tracker, enabled: false, otp_app: :my_app, plugins: []

# config/runtime.exs
if token = System.get_env("SAURON_REPORT_TOKEN") do
  config :error_tracker,
    repo: MyApp.Repo,
    otp_app: :my_app,
    enabled: true,
    plugins: [{ErrorTracker.Plugins.Pruner, max_age: :timer.hours(24 * 14)}]

  config :sauron_reporter,
    url: System.fetch_env!("SAURON_URL"),
    token: token,
    app: "my-app",          # the app's name in Sauron; the token must belong to it
    otp_apps: [:my_app]
end
```

Nothing to add to the supervision tree: the library's application runs
the reporter, inert without a configuration. Options (`version_app`,
`redact`, `self_noise`, `deliver`, `req_options`) are in the moduledoc.

The token is 24 random bytes, URL-safe, in Sauron's `REPORT_TOKENS` as
`my-app:<token>` and in the app's sealed bundle — never in a repo.

## Analytics: visits, events and timings (0.5.0)

Sauron's plan 28: every app's page views, custom events, server timings
and signed-in users, consolidated in Sauron — beside the app's own
analytics, which it keeps. Cookieless: the app forwards each visitor's
IP and user agent, Sauron hashes them with a salt of the day and keeps
neither. Off until `analytics: [enabled: true]`; the same `url`, `token`
and `app` as the errors, posted to `POST /report/events`.

```elixir
# config/runtime.exs, beside the reporter's url/token/app
config :sauron_reporter,
  analytics: [
    enabled: System.get_env("SAURON_ANALYTICS") in ~w(1 true),
    user_key: System.get_env("SAURON_USER_KEY"), # optional: no key, no `user` sent
    sites: ["www.example.fr"]                    # optional allowlist of hosts
  ]
```

```elixir
# endpoint.ex — after Plug.Static and whatever sets conn.remote_ip
plug SauronReporter.Analytics.Plug

# the LiveView socket passes what the hook reads
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [:peer_data, :user_agent, :x_headers, session: @session_options]]

# router.ex — after the hook that assigns the user
live_session :default, on_mount: [MyAppWeb.UserAuth, SauronReporter.Analytics.Hook] do

# anywhere: a custom event, from a conn, a socket or a map
SauronReporter.Analytics.track(conn, "signup", %{plan: "pro"})
```

- **The plug**: a timing for every request (method, the router's
  pattern, status, duration), a page view for an HTML page served (a
  `GET` answered 2xx with `text/html`, or a 304); not redirects,
  prefetches, crawlers (Sauron's own user-agent test), assets, health
  checks or the live socket. `page_views: false` / `timings: false`
  split it between the endpoint and a pipeline.
- **The hook**: a page view per live navigation (a `patch` to another
  path, a `navigate`), never the first page (the plug's) nor a
  reconnection — unless `{SauronReporter.Analytics.Hook, count:
  :connected}`, for routes the plug does not count: the first page then
  counts when its live connection opens.
- **The user**: the assign `:sauron_user_id`, else `user_assign:`'s
  `id`, hashed with `user_key` (HMAC-SHA256, 32 hex) before it leaves.
- **The IP**: `conn.remote_ip` as the app's proxy handling sets it;
  `trust_forwarded: true` reads the last `X-Forwarded-For` hop instead
  (`:first`, the first, behind proxies the app trusts entirely).
- **The buffer**: sends every 5 s or at 50 events, one send at a time,
  at most 200 events each; beyond 5 000 waiting the oldest go. A send
  that fails is dropped, never retried: an hour without Sauron costs
  that hour's events, not the app's time. `SauronReporter.Analytics.stats/0`
  and the telemetry events `[:sauron_reporter, :analytics, :sent |
  :dropped | :failed]` count it all.

Every option is in `SauronReporter.Analytics`'s moduledoc.

## What the client caused is not reported (0.4.0)

A 404, a 400, a client that closed its connection: an exception whose
HTTP status (`Plug.Exception`) is below 500, and `Bandit.TransportError`,
stay in the app's ErrorTracker but are not sent to Sauron. `ignore:`
adds an app's own — `[{"MyApp.ClientError", "LiveView not connected"}]`
(a kind and a text within the reason), or a kind alone.

## Logs: one journal entry per event (0.2.0)

`SauronReporter.JournalFormatter` makes a release's logs follow the
fleet's log contract (infra `docs/logs.md`): under the journal, each
event is one line, its line breaks escaped, after a `<N>` systemd turns
into its priority — so an `[error]` is an error to Sauron's views, and a
stack trace is one entry, not one per frame.

```elixir
# config/runtime.exs — only when the output is the journal
if System.get_env("JOURNAL_STREAM") do
  config :logger, :default_handler,
    formatter:
      SauronReporter.JournalFormatter.new(
        format: "$metadata[$level] $message\n",
        metadata: [:request_id]
      )
end
```

Its options are `Logger.Formatter.new/1`'s; the journal stamps the time.
An app with a formatter of its own wraps it instead (0.3.0) —
`JournalFormatter.new(formatter: LoggerJSON.Formatters.Basic.new(...))`:
its lines unchanged, their level put in front.

## Develop

```
mise install
mix deps.get
mix test
```

A change to the payload is a change to Sauron's contract: Sauron's own
tests post this library's payload to its endpoint. Tag a version, then
move each app's dependency to it.
