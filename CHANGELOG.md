# Changelog

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
