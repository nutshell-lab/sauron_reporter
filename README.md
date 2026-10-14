# SauronReporter

Sends an Elixir app's errors to [Sauron](https://sauron.nutshell-lab.com),
the Nutshell fleet's error manager: every occurrence
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
{:sauron_reporter, github: "nutshell-lab/sauron_reporter", tag: "v0.1.0"}
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

## Develop

```
mise install
mix deps.get
mix test
```

A change to the payload is a change to Sauron's contract: Sauron's own
tests post this library's payload to its endpoint. Tag a version, then
move each app's dependency to it.
