# SauronReporter

Sends an Elixir app's errors — and, opt-in, its visits (0.5.0) — to
[Sauron](https://sauron.nutshell-lab.com), the Nutshell fleet's error
manager, and links its users to Sauron's support chat (0.8.0): every occurrence
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
{:sauron_reporter, github: "nutshell-lab/sauron_reporter", tag: "v0.8.0"}
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
and signed-in users, consolidated in Sauron — and since 0.7.0 (plan 32)
every page served, people and robots told apart there — beside the app's own
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
    sites: ["www.example.fr"],                   # optional allowlist of hosts
    ignore_emails: ["@nutshell-lab.com"],        # optional: our people are not counted (0.6.0)
    redact_paths: ["/annuler/:token"]            # optional: secret-bearing routes, sent as their pattern (0.6.1)
  ]
```

```elixir
# endpoint.ex — after Plug.Static and whatever sets conn.remote_ip
plug SauronReporter.Analytics.Plug

# the LiveView socket passes what the hook reads
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [:peer_data, :user_agent, :x_headers, session: @session_options]]

# router.ex — on every live_session with pages, after the hook that assigns the user
live_session :default, on_mount: [MyAppWeb.UserAuth, SauronReporter.Analytics.Hook] do

# anywhere: a custom event, from a conn, a socket or a map
SauronReporter.Analytics.track(conn, "signup", %{plan: "pro"})
```

- **The plug**: a timing for every request (method, the router's
  pattern, status, duration), a page request for an HTML page served (a
  `GET` answered 2xx with `text/html`, or a 304); not redirects,
  prefetches, assets, health checks or the live socket. Robots' too
  (0.7.0): Sauron sorts them. `page_requests: false` / `timings: false`
  split it between the endpoint and a pipeline.
- **The hook**: the page views (0.7.0) — one when a page's live
  connection opens, with the request's path, one per live navigation
  (a `patch` to another path, a `navigate`); never the HTTP render nor a
  reconnection.
- **The user**: the assign `:sauron_user_id`, else `user_assign:`'s
  `id` (`:current_user` by default), hashed with `user_key`
  (HMAC-SHA256, 32 hex) before it leaves.
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

## Support chat (0.8.0)

Sauron's plan 29: a signed-in user reports a problem, proposes an idea
or speaks to somebody now — « J'ai une idée », « J'ai un problème »,
« Parler à quelqu'un » — without leaving the app, and Nutshell answers
from Sauron. The library gives the app the launcher and the side panel
(boards 75–76 of the mockups), styled by the app's CSS variables, and
the app's **one link** to Sauron: a WebSocket per app node, the report
token in a header. **The browser never talks to Sauron**: the panel is
a LiveView on the app's server, which vouches for its user.

```elixir
# config/runtime.exs, beside the reporter's url/token/app
config :sauron_reporter,
  support: [
    enabled: System.get_env("SAURON_SUPPORT") in ~w(1 true),
    pubsub: MyApp.PubSub          # Sauron's events are relayed on it
  ]
```

Nothing to add to the supervision tree: the library's application runs
the client, inert until support is enabled (read at boot). It connects
to `wss://<SAURON_URL>/support/socket/websocket` and posts files to
`/support/files`; on Sauron's side those paths must be open to the
app's server (infra: the sauron release's `private_paths`, plan 31).
Options (`socket_url`, `call_timeout`, `buffer_ttl`, `max_buffer`,
backoffs, `req_options`) are in `SauronReporter.Support`'s moduledoc.

### Mounting it

In the layout of the `live_session`(s) where users are signed in — once,
it is a sticky LiveView that survives live navigation:

```heex
<SauronReporter.Support.panel
  :if={@current_user}
  socket={@socket}
  user={%{id: @current_user.id, name: @current_user.name, email: @current_user.email}}
  org={%{id: @current_org.id, name: @current_org.name}}
  title="Assistance"
  team="l'équipe m2"
  page={@current_path}
/>
```

| attr | default | |
|---|---|---|
| `socket` | — | the LiveView's socket (a dead page's conn works too) |
| `user` | — | `id`, `name` (or `first_name`/`last_name`), `email` — what Sauron shows and answers by email |
| `org` | `nil` | the user's organisation in the app: `id`, `name` |
| `title` | `"Aide"` | the panel's title and the launcher's word: « Assistance », « Aide » |
| `team` | `"l'équipe"` | who answers, as the copy says it: « l'équipe m2 », « l'équipe Nutshell » |
| `launcher` | `true` | the bottom-right launcher; `false` when the app opens the panel from its own menu |
| `page` | `nil` | where the user is (a path; no query, secrets masked as analytics does) |
| `note`, `idea_hint` | | the start's footnote and the line under « J'ai une idée » |
| `time_zone` | `"Europe/Paris"` | the times shown (Paris is known without a tz database) |
| `hook` | `true` | the `SauronSupport` JS hook is registered |
| `id`, `sticky` | `"sauron-support"`, `true` | |

```elixir
# router.ex — the page's LiveView and the panel talk: unread count, page
live_session :app, on_mount: [MyAppWeb.UserAuth, SauronReporter.Support.Hook] do
```

The socket needs no `connect_info` of its own: the user comes from the
layout, signed into the nested LiveView's session by the endpoint; the
page's LiveView and the panel find each other by the socket's transport.

**The app's own menu button** (m2-app's lifebuoy, `launcher={false}`),
without a script of the app's:

```heex
<button type="button" aria-label="Assistance" phx-click={SauronReporter.Support.open_panel()}>
  <.icon name="lifebuoy" />
  <span :if={@sauron_support_unread > 0} class="dot" aria-hidden="true"></span>
</button>
```

`open_panel/2` (or `toggle_panel/2`) pushes `"sauron_support:open"`
(`"sauron_support:toggle"`) to the panel's LiveView, found by its id,
and remembers the focus that closing gives back. `@sauron_support_unread`
is assigned by `SauronReporter.Support.Hook`: the answers that arrived
while the panel was closed (an operator's message, nobody available, a
screenshot asked, rejected, resolved, called).

**The stylesheet and the hook.** The CSS ships in
`priv/static/sauron_support.css` — every colour, face and radius from a
variable with a default — and the hook (paste an image, « Capturer cet
écran », Enter to send; the panel works without it) in
`priv/static/sauron_support.js`:

```css
/* assets/css/app.css */
@import "../../deps/sauron_reporter/priv/static/sauron_support.css";
:root {
  --aide-font: "Source Sans 3", system-ui, sans-serif;
  --aide-bg: #FFFFFF;  --aide-surface: #F3F6F9;  --aide-ink: #1E1F21;
  --aide-muted: #4E5052;  --aide-line: #CED1D4;  --aide-field: #848689;
  --aide-accent: #00516C;  --aide-accent-ink: #FFFFFF;
  --aide-mark: #900F21;  --aide-ok: #095717;
  --aide-radius: 6px;  --aide-button-radius: 6px;
  --aide-top: 0px;     /* where the panel starts: under a sticky header (edp-neo: 69px) */
}
```

```js
// assets/js/app.js
import {SauronSupport} from "../../deps/sauron_reporter/priv/static/sauron_support.js"
let liveSocket = new LiveSocket("/live", Socket, {hooks: {SauronSupport, ...hooks}, ...})
```

An app without a CSS build puts `<SauronReporter.Support.styles />` in
its root layout instead; one that cannot register the hook passes
`hook={false}` (no paste, no capture button: « Choisir une image »
stays).

### What it does

- **The start**: the three choices; the user's requests not over yet to
  resume. A live chat not over, or a request not sent yet, opens again
  by itself.
- **A problem or an idea**: described in messages, files attached
  (paperclip, paste, capture; 10 MB, PNG/JPEG/GIF/WebP/PDF, five at a
  time — a text sent with files is the first file's caption), then
  « Terminé »: sent, it waits for an operator.
- **A live chat**: « Nous cherchons quelqu'un » with the time waited;
  an operator joins and answers live, their typing shown; nobody in 5
  minutes: an email answer, and « Rappelez-moi » with a phone number.
- **A screenshot asked**: a banner — « Capturer cet écran » where the
  browser can, « Choisir une image », « Plus tard ».
- **The system's lines** speak in the app's voice: the team the app
  names, the user's email, the operator's first name — not Sauron's
  « l'équipe Nutshell ».
- **Accessible**: real buttons, labels and inputs; the panel is a
  dialog, focused on opening (the first choice, or the message field),
  Escape and « Réduire » close it and give the focus back; new messages
  in an `aria-live` log.
- **Only the user's**: the panel subscribes to its user's topic, drops
  any event naming someone else, and keeps no thread Sauron says is
  another user's.

### The link

- **Calls** (`SauronReporter.Support.open/4`, `send_message/2`,
  `upload_done/3`, `attach/5`, `submit/1`, `close/1`, `callback/2`,
  `resume/1`, `history/2`) answer `{:ok, map} | {:error, reason}`;
  `typing/2`, `read/1`, `present/2`, `absent/1` are fire-and-forget.
- **While the link is down** a call waits in a buffer (500 at most,
  each 30 s at most) and is pushed in order once the channel is joined
  again; past its time it answers `{:error, :disconnected}`, beyond the
  bound `{:error, :buffer_full}`. A call in flight when the link drops
  answers `{:error, :disconnected}` and is never pushed twice; the panel
  shows it « Non envoyé » with « Réessayer ». Typing and reads are
  dropped. Presence is said again after each reconnection, and the
  panel catches up with what happened meanwhile (`resume`).
- **Reconnects** with backoff, 100 ms up to 30 s.
- **Events** go on the app's PubSub, on this node only
  (`local_broadcast`: every node's client hears every event):
  `{SauronReporter.Support, %SauronReporter.Support.Event{}}` on
  `"sauron_support:user:<user_id>"` and
  `"sauron_support:conversation:<id>"`; `{SauronReporter.Support, :link,
  :up | :down}` on `"sauron_support:link"`.
- Telemetry: `[:sauron_reporter, :support, :connected | :disconnected
  | :dropped]`.

Not in 0.8.0: images are shown as file chips, not previews (the browser
never fetches Sauron's files); whether an operator is online is not
known, so the header shows who joined, not « en ligne ».

## Our own people are not counted (0.6.0)

An app never reports its own staff — for the fleet, Nutshell Lab's
people — to Sauron's analytics. A request or a socket is *ours* when:

- the signed-in user (`user_assign:`, `:current_user` by default) has
  an `email` — a string, or anything `to_string/1` takes, like
  `Ash.CiString` — ending with one of `ignore_emails`, without case
  (`"@nutshell-lab.com"`; an entry without `@` is a suffix all the same;
  default `[]`, nobody);
- the app assigns `:sauron_ignore` to `true` itself — the way out for a
  user without an email, or a rule of the app's own
  (`assign(conn, :sauron_ignore, true)` in a plug, the same on the
  socket in an `on_mount`);
- the request carries the cookie `sauron_ignore`.

Ours sends no page request, no page view and no custom event (`track/3`
answers `:ok` and sends nothing). Its timings still go: server performance is not about
who.

**The cookie.** The plug answers an ours signed-in request (or one the
app flagged) with `sauron_ignore=1`: a year, path `/`, `HttpOnly`,
`SameSite=Lax`, `Secure` over https, no identifier in it. Any later
request carrying it is ours, signed in or not — so a person of the app
browsing its public pages signed out stays left out. Its name is fixed.
The plug reads cookies itself; it needs no session for that.

**The hook.** The hook leaves out a signed-in user by the
socket's assigns (the app's hook assigning the user comes first, as
already required). A signed-out person with the cookie it learns from
the session — a connected mount reads no cookie, but its session is the
page's, merged with the session cookie the socket reads (`session:
@session_options` in `connect_info`). The plug puts `"sauron_ignore" =>
true` in the session when it finds a request ours **and the session is
already fetched** — it never fetches it. So for that case the plug must
run after `fetch_session`:

```elixir
# endpoint.ex — timings for every request
plug SauronReporter.Analytics.Plug, page_views: false

# router.ex — page views, once the session is fetched
pipeline :browser do
  plug :fetch_session
  # ...
  plug SauronReporter.Analytics.Plug, timings: false
end
```

(or `plug :fetch_session` right before the plug in the endpoint).
Without it, everything else holds — ours by the user, by the assign, by
the cookie on every HTTP request — but a signed-out person's page views
are counted (since 0.7.0 every page view is the hook's, the first one
included).

## People and robots (0.7.0)

Sauron's plan 32: every page Sauron hears of is a person's or a robot's,
and its audience figures are people's. A robot fetches HTML, posing as
a browser if it likes; it does not open a LiveView's live connection. So:

- **the plug** sends each HTML page served as a `page_request` — the
  fields 0.6's page view had (site, path, route, referrer host, UTM, IP,
  user agent, user) and the status (200, 304);
- **the hook** sends the `page_view`, a person's, when the page's live
  connection opens — the first page of a visit, with the request's path
  — and on each live navigation. `count: :connected` was that already;
  it is now the only way, and `count:` is not read;
- **a dead page** (no LiveView) is a request only — as in the apps that
  count their visits on the live connection (phx-cms's `count:
  :connected`);
- **robots** are sent: the client no longer drops a user agent that
  names a robot (`send_bots` is not read). Sauron names them (Googlebot,
  GPTBot, its own probes…) and sorts the disguised ones by network and
  by the requests no page view confirmed.

Sauron pairs a request with its page view by the visitor — the hash of
the IP and user agent forwarded on both — and the path, within 30
seconds. The hook must therefore forward what the plug forwards:

- the socket passes `connect_info: [:peer_data, :user_agent, :x_headers,
  session: @session_options]` (websocket and longpoll);
- behind a proxy, `trust_forwarded` is set: the plug reads the last
  `X-Forwarded-For` hop of the request, the hook the same hop of the
  socket's `:x_headers`. Without it the hook has the socket's peer only,
  which is the plug's `conn.remote_ip` only when nothing rewrites it.

What an app checks when it moves to 0.7.0:

1. the socket's `connect_info` above, on `/live`'s websocket and
   longpoll;
2. the hook on **every** `live_session` that serves pages — a page
   without it is no longer counted at all (its request is, as a
   request);
3. `{SauronReporter.Analytics.Hook, count: :connected}` can become the
   plain hook (`count:` is ignored);
4. `trust_forwarded` behind Caddy (the fleet's apps have it);
5. the plug after `:fetch_session` somewhere in the pipeline of the
   pages, so a signed-out person of ours is left out of the first page
   view too (it is the hook's now);
6. `send_bots` and `page_views: false` can go (`page_requests: false`
   is the plug option's name now; the old one is still read).

## Paths carry no secret (0.6.1)

A route that puts a secret in its path — a magic sign-in link, a
booking's cancel link, a calendar feed, a check-in ticket — would hand a
working token to Sauron with the page view. So a path leaves the app
without its query or fragment (as before) and without its secrets:

- **`redact_paths`**: the app's secret-bearing routes, as patterns
  matched against the whole path, segment by segment. A literal segment
  matches itself; `:name` matches any segment and is sent as `:name`;
  `*` matches any segment and is sent as it is. The first pattern that
  matches applies, and a trailing slash is kept:

  ```elixir
  redact_paths: [
    "/rendez-vous/annuler/:token",           # /rendez-vous/annuler/Xb3…  → /rendez-vous/annuler/:token
    "/rendez-vous/:token/calendrier.ics",
    "/magiclink/:token", "/*/magiclink/:token" # an app with locale prefixes lists each shape
  ]
  ```

- **Token-shaped segments**, on by default (`mask_tokens: false` turns
  it off): a segment is sent as `:token` when it is a hex string of 32
  characters or more; three dot-separated base64url parts, one of them
  secret-shaped (a JWT, a `Phoenix.Token`); or 20 characters or more of
  `[A-Za-z0-9_-]` (up to two `=` after) with a digit or both cases, that
  is not a lowercase slug (`^[a-z0-9]+(-[a-z0-9]+)+$`). UUIDs, integers,
  slugs (`/dossiers/l-ia-dans-un-back-office`) and short segments are
  never masked.

The shape test is a net, not a list: a random token can, now and then,
look like neither (24 random bytes drawn without a digit and in one
case) — `redact_paths` is the app's word for its own. Page views, live
navigations, timings and custom events all send the same path; the
router's pattern (`route`) and the referrer (a host only) carry no
secret. Sauron masks token-shaped segments again when it takes an event.

The hook now honours `ignore_paths` as the plug does: no live page view
on a path the plug never reports.

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
