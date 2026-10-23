# Changelog

## 0.8.0 — 2026-10-23

The support chat (Sauron plan 29, step 2): an app's signed-in users ask
for help from the app — an idea, a problem, somebody now — and Nutshell
answers from Sauron. Needs a Sauron with plan 29's step 1 (the support
socket and files API) and those paths open to the app's server.

- `SauronReporter.Support.Client`: the app's one WebSocket to Sauron per
  node (Slipstream, a Phoenix channel client), `x-sauron-token: <report
  token>`, joined to `support:<app>`; reconnects and rejoins with
  backoff; buffers the users' calls while the link is down (500 at most,
  30 s each), pushes them in order once joined again; answers a call in
  flight when the link drops `{:error, :disconnected}`, never twice;
  monitors the screens that show a conversation and tells Sauron the
  user's presence and page; relays Sauron's events to the app's PubSub
  (`local_broadcast`) on `sauron_support:user:<id>` and
  `sauron_support:conversation:<id>`, the link's state on
  `sauron_support:link`. Inert until `support: [enabled: true, pubsub:
  MyApp.PubSub]` with the reporter's url, token and app.
- `SauronReporter.Support`: the calls (`open/4`, `send_message/2`,
  `upload/4`, `upload_done/3`, `attach/5`, `typing/2`, `read/1`,
  `present/2`, `absent/1`, `submit/1`, `close/1`, `callback/2`,
  `resume/1`, `history/2`), `{:ok, …} | {:error, reason}`, never raising.
- `SauronReporter.Support.panel/1`: the launcher and the side panel, a
  sticky nested LiveView (`SauronReporter.Support.Live`) — the guided
  start, a problem or an idea with attachments and « Terminé », a live
  chat searching then answered (typing shown), nobody in 5 minutes then
  a callback, a screenshot asked, a request closed. Title and team
  named by the app; French copy; the system's lines in the app's voice.
  `launcher={false}` and `open_panel/2` / `toggle_panel/2` for the app's
  own menu button.
- `SauronReporter.Support.Hook` (`on_mount`): `@sauron_support_unread`
  for that button, and the page followed across live navigation.
- Uploads through the panel's `allow_upload` (10 MB; PNG, JPEG, GIF,
  WebP, PDF; five at a time), forwarded by the app's server to Sauron's
  `POST /support/files` with the token, then `upload_done`.
- `priv/static/sauron_support.css`: every colour, face and radius from
  `--aide-font`, `--aide-bg`, `--aide-surface`, `--aide-ink`,
  `--aide-muted`, `--aide-line`, `--aide-field`, `--aide-accent`,
  `--aide-accent-ink`, `--aide-mark`, `--aide-ok`, `--aide-radius`,
  `--aide-button-radius`, `--aide-top`, each with a default;
  `SauronReporter.Support.styles/1` inlines it.
- `priv/static/sauron_support.js`: the `SauronSupport` hook — paste an
  image, capture the screen (`getDisplayMedia`), Enter to send. The
  panel works without it.
- Dependencies: `slipstream ~> 1.2` (with `mint_web_socket`); `bandit`
  for the tests only.

## 0.7.0 — 2026-10-22

People and robots (Sauron plan 32): a page served is a request, a page
view is a person's — the proof a browser ran the page. Sauron sorts the
rest and names the robots. Needs a Sauron that takes `page_request`.

- The plug sends each HTML page served as `"kind" => "page_request"`,
  no longer a `page_view`: the same fields (site, path, route, referrer
  host, UTM, IP, user agent, user) and the response's `status` (200,
  304). Its option `page_views: false` is now `page_requests: false`;
  the old name is still read.
- The hook sends every `page_view`: when a page's live connection opens
  (the connected mount — the first page of a visit, with the path its
  request had) and on each live navigation, as `count: :connected` did.
  Not the HTTP render, not a reconnection. `count:` is no longer read:
  `count: :request` (the old default) left the first page to the plug,
  which no longer sends a page view — kept, it would lose every first
  page.
- Sauron pairs a request with its page view by visitor (IP and user
  agent) and path. The hook reads every `X-Forwarded-For` header of the
  socket's `:x_headers`, joined as the plug joins the request's, so the
  two forward the same IP under `trust_forwarded`.
- A dead page (no LiveView) is a request only — as in the apps that
  count on the live connection.
- Robots are sent: the client no longer drops a user agent that names a
  crawler or a monitor, on the plug or the hook. `send_bots` is not
  read; `bot?/1` and its copy of Sauron's regex are gone (Sauron names
  robots from a maintained list now).
- Ours (`ignore_emails`, `:sauron_ignore`, the cookie and its session
  flag) is unchanged: no page request, no page view, no custom event.
  Custom events and timings are unchanged.

What an app must check when it moves to 0.7.0:

- the socket passes `connect_info: [:peer_data, :user_agent,
  :x_headers, session: @session_options]`, on websocket and longpoll;
- `trust_forwarded` behind a proxy, so the hook's IP is the plug's;
- `SauronReporter.Analytics.Hook` on every `live_session` that serves
  pages — without it a page is a request, never a page view;
- `{SauronReporter.Analytics.Hook, count: :connected}` can become the
  plain hook; `send_bots` can go;
- the plug after `:fetch_session` in the pages' pipeline, so a
  signed-out person of ours stays out of the first page view, now the
  hook's.

## 0.6.1 — 2026-10-21

Paths carry no secret: a magic sign-in link, a cancel link, a calendar
feed no longer hand a working token to Sauron.

- `analytics: [redact_paths: ["/annuler/:token", "/*/magiclink/:token"]]`:
  route patterns matched against the whole path, segment by segment —
  a literal matches itself, `:name` any segment and is sent as `:name`,
  `*` any segment, sent as it is. The first that matches applies; a
  trailing slash is kept. Default `[]`.
- Token-shaped segments are sent as `:token`, on by default
  (`mask_tokens: false` turns it off): a hex string of 32 characters or
  more; three dot-separated base64url parts, one secret-shaped (a JWT,
  a `Phoenix.Token`); 20 characters or more of `[A-Za-z0-9_-]` (two `=`
  of padding allowed) with a digit or both cases, not a lowercase slug.
  UUIDs, integers, slugs and short segments are kept.
- Both apply to every path sent: page views, live navigations, timings,
  custom events (`track/3` from a conn, a socket or a map's `:path`).
  The route and the referrer (a host) were never a path.
- The hook honours `ignore_paths` as the plug does: no live page view
  on a path the plug never reports.

## 0.6.0 — 2026-10-21

Our own people are not counted: an app never reports its own staff —
Nutshell Lab's people, for the fleet — to Sauron's analytics.

- `analytics: [ignore_emails: ["@nutshell-lab.com"]]`: a signed-in user
  whose `email` (the `user_assign`'s; a string or anything
  `to_string/1` takes) ends with one of them, without case, is *ours*;
  an entry without `@` is a suffix all the same. Default `[]`.
- The assign `:sauron_ignore` set to `true` by the app makes a request
  or a socket ours too — for a user without an email, or a rule of the
  app's own.
- Ours sends no page view and no custom event: `track/3` from its conn
  or socket answers `:ok` and sends nothing. Its timings still go.
- The plug answers an ours request with the cookie `sauron_ignore=1` (a
  year, `/`, `HttpOnly`, `SameSite=Lax`, `Secure` over https, no
  identifier); any request carrying it is ours, signed in or not. The
  plug fetches the cookies itself.
- The hook leaves ours out of live navigations: a signed-in user by the
  socket's assigns, a signed-out person by the session's
  `"sauron_ignore"`, which the plug puts there when the session is
  fetched before it (never fetching it itself).
- `user_assign` defaults to `:current_user`, as the moduledoc already
  said: an app with a `user_key` and a `:current_user` assign now sends
  its users' hashed ids without configuring it.
- The bot test follows Sauron's: monitors (`Sauron/`, UptimeRobot,
  Pingdom, StatusCake, Better Stack, Checkly, HetrixTools, Site24x7,
  Nagios, Zabbix, any `monitor`) are bots.

## 0.5.0 — 2026-10-20

Analytics (Sauron plan 28): page views, live navigations, timings and
custom events, buffered, cookieless, never in the app's way.

## 0.4.1, 0.4.0 — 2026-10-17

What the client caused is not reported: below 500, a closed connection,
an app's `ignore:` (a kind and a text within the reason).

## 0.3.0 — 2026-10-16

`JournalFormatter` wraps an app's own formatter.

## 0.2.0 — 2026-10-15

`JournalFormatter`: one journal entry per log event, with its severity.

## 0.1.0 — 2026-10-14

An app's ErrorTracker occurrences to Sauron.
