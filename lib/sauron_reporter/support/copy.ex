defmodule SauronReporter.Support.Copy do
  @moduledoc """
  The panel's French words and formats: what a system line says in the
  app's voice (the team the app names, not Sauron's), times and days in
  the user's zone, sizes.

  Sauron sends each system message with a `code`, its own text and the
  facts to word it (the operator's first name, a phone, the user's
  email, a reason); the codes the panel knows are said here, with the
  app's team name and those facts; any other is shown as Sauron wrote
  it.
  """

  @days ~w(lundi mardi mercredi jeudi vendredi samedi dimanche)
  @months ~w(janvier février mars avril mai juin juillet août septembre octobre novembre décembre)

  @doc "`text` with its first letter in capitals, the rest untouched."
  def capitalize(nil), do: nil

  def capitalize(text) do
    case String.next_grapheme(text) do
      {first, rest} -> String.upcase(first) <> rest
      nil -> text
    end
  end

  @doc "The first word of a name: « Camille » for « Camille Roussel »."
  def first_name(nil), do: nil

  def first_name(name) when is_binary(name) do
    name |> String.split(~r/\s+/, trim: true) |> List.first()
  end

  @doc "The label of a kind, as the user chose it."
  def choice(:feature), do: "J'ai une idée"
  def choice(:issue), do: "J'ai un problème"
  def choice(:live_chat), do: "Parler à quelqu'un"

  @doc "The line under each choice."
  def hint(:feature, nil), do: "Une amélioration, une envie : nous les lisons toutes."
  def hint(:feature, hint), do: hint
  def hint(:issue, _), do: "Pas urgent : décrivez-le, nous répondons par e-mail."
  def hint(:live_chat, _), do: "Maintenant, en direct, si quelqu'un est disponible."

  @doc "While a live chat waits for somebody."
  def waiting_info do
    "D'habitude, quelqu'un répond en quelques minutes. Sans réponse sous 5 minutes, " <>
      "votre demande reste ouverte et nous vous répondons par e-mail."
  end

  @doc """
  A system message as the panel shows it: `{:line, text}` (a bubble in
  the assistant's voice), `{:paragraphs, [text]}`, `{:searching, text}`
  or `{:event, text}` (a short centred line). `ctx` holds `team`,
  `email`, `request`.

  Every code Sauron names is worded here, from the facts its event
  carries (Sauron's step 3): `operator` (the first name), `phone`,
  `email`, `reason` — the request's own facts when an older message has
  none. Sauron's French `text` is shown only for a code the panel does
  not know.
  """
  def system(%{"type" => "event", "code" => code} = content, ctx),
    do: event(code, content, ctx)

  def system(%{"type" => "text", "body" => body}, _ctx), do: {:line, body}
  def system(%{"text" => text}, _ctx) when is_binary(text), do: {:line, text}
  def system(_content, _ctx), do: {:line, ""}

  defp event("searching", _content, _ctx),
    do: {:searching, "Nous cherchons quelqu'un de disponible…"}

  defp event("describe_issue", _content, _ctx) do
    {:line,
     "Décrivez le problème : ce que vous faisiez, ce qui s'est passé. Ajoutez des captures " <>
       "d'écran — plus il y a de détails, plus vite nous corrigeons."}
  end

  defp event("describe_feature", _content, _ctx) do
    {:line,
     "Décrivez votre idée : ce qu'elle vous permettrait de faire. Appuyez sur « Terminé » " <>
       "pour l'envoyer."}
  end

  defp event("submitted", content, ctx) do
    {:line,
     "C'est envoyé à #{ctx.team} : nous vous répondrons ici, ou par e-mail#{to(content, ctx)}."}
  end

  defp event("no_operator", content, ctx) do
    {:paragraphs,
     [
       "Personne n'est disponible pour le moment. Votre demande reste ouverte : " <>
         "nous vous répondrons par e-mail#{to(content, ctx)}.",
       "Vous pouvez aussi demander à être rappelé."
     ]}
  end

  defp event("claimed", content, ctx) do
    case operator(content, ctx) do
      nil -> {:event, "Quelqu'un de #{ctx.team} a rejoint la conversation"}
      name -> {:event, "#{name}, de #{ctx.team}, a rejoint la conversation"}
    end
  end

  defp event("screenshot_asked", content, ctx),
    do:
      {:event,
       "#{operator(content, ctx) || capitalize(ctx.team)} vous demande une capture d'écran"}

  defp event("callback_requested", content, ctx) do
    case phone(content, ctx) do
      nil -> {:event, "Rappel demandé"}
      phone -> {:event, "Rappel demandé au #{phone}"}
    end
  end

  defp event("called", content, ctx) do
    who = operator(content, ctx) || capitalize(ctx.team)

    case phone(content, ctx) do
      nil -> {:event, "#{who} vous a appelé"}
      phone -> {:event, "#{who} vous a appelé au #{phone}"}
    end
  end

  defp event("resolved", content, ctx),
    do: {:event, "#{operator(content, ctx) || capitalize(ctx.team)} a clos cette demande"}

  defp event("rejected", content, ctx) do
    case filled(content["reason"]) do
      nil -> {:line, "#{capitalize(ctx.team)} n'a pas retenu votre demande."}
      reason -> {:line, "#{capitalize(ctx.team)} n'a pas retenu votre demande : #{reason}"}
    end
  end

  defp event("closed_by_user", _content, _ctx), do: {:event, "Vous avez clos cette demande"}

  defp event(_code, %{"text" => text}, _ctx) when is_binary(text), do: {:line, text}
  defp event(_code, _content, _ctx), do: {:line, ""}

  # The facts: the event's own, else the request's as it is now.
  defp operator(content, ctx) do
    first_name(filled(get_in(content, ["operator", "name"])) || operator_name(ctx[:request]))
  end

  defp phone(content, ctx) do
    filled(content["phone"]) || filled(get_in(ctx, [:request, "callback_phone"]))
  end

  defp to(content, ctx) do
    case filled(content["email"]) || filled(ctx[:email]) do
      nil -> ""
      email -> " à #{email}"
    end
  end

  defp filled(value) when is_binary(value) and value != "", do: value
  defp filled(_value), do: nil

  @doc "The name of the operator who claimed `request`, or `nil`."
  def operator_name(%{"claimed_by" => %{"name" => name}}) when is_binary(name) and name != "",
    do: name

  def operator_name(_request), do: nil

  # ---------- times ----------

  @doc "A wire time (ISO 8601) as a `DateTime`, or `nil`."
  def parse(nil), do: nil
  def parse(%DateTime{} = at), do: at

  def parse(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  def parse(_), do: nil

  @doc "`at` in `zone`, as a `NaiveDateTime` (Europe/Paris's rule is known without a time zone database)."
  def local(nil, _zone), do: nil

  def local(%DateTime{} = at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} ->
        DateTime.to_naive(local)

      {:error, _} when zone == "Europe/Paris" ->
        at |> DateTime.add(paris_offset(at), :second) |> DateTime.to_naive()

      {:error, _} ->
        DateTime.to_naive(at)
    end
  end

  # CET, CEST from the last Sunday of March to the last Sunday of
  # October, at 01:00 UTC.
  defp paris_offset(%DateTime{} = at) do
    utc = DateTime.to_naive(at)
    from = last_sunday(utc.year, 3)
    to = last_sunday(utc.year, 10)

    if NaiveDateTime.compare(utc, from) != :lt and NaiveDateTime.compare(utc, to) == :lt,
      do: 7_200,
      else: 3_600
  end

  defp last_sunday(year, month) do
    last = Date.new!(year, month, Date.days_in_month(Date.new!(year, month, 1)))
    sunday = Date.add(last, -rem(Date.day_of_week(last), 7))
    NaiveDateTime.new!(sunday, ~T[01:00:00])
  end

  @doc "« 09:05 »."
  def time(nil), do: ""

  def time(%NaiveDateTime{} = local),
    do: "#{pad(local.hour)}:#{pad(local.minute)}"

  @doc "« Jeudi 22 octobre » (and the year when it is not this one)."
  def day(%NaiveDateTime{} = local, %NaiveDateTime{} = today) do
    date = NaiveDateTime.to_date(local)
    name = Enum.at(@days, Date.day_of_week(date) - 1)
    month = Enum.at(@months, date.month - 1)
    year = if date.year == today.year, do: "", else: " #{date.year}"
    capitalize("#{name} #{date.day} #{month}#{year}")
  end

  @doc "« 1 min 12 », « 40 s »."
  def elapsed(seconds) when seconds < 60, do: "#{max(seconds, 0)} s"
  def elapsed(seconds), do: "#{div(seconds, 60)} min #{pad(rem(seconds, 60))}"

  @doc "« 1,2 Mo », « 340 ko »."
  def size(nil), do: ""
  def size(bytes) when bytes < 1_000, do: "#{bytes} o"
  def size(bytes) when bytes < 1_000_000, do: "#{round(bytes / 1_000)} ko"

  def size(bytes) do
    (bytes / 1_000_000)
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.replace(".", ",")
    |> Kernel.<>(" Mo")
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc "Why a call failed, for the user."
  def failure(:rate_limited), do: "Trop de demandes d'un coup : réessayez dans quelques secondes."
  def failure(:over), do: "Cette demande est close : ouvrez-en une nouvelle."
  def failure({:invalid, _}), do: "Ce message n'a pas pu être envoyé : vérifiez-le et réessayez."
  def failure(:too_large), do: "Ce fichier dépasse 10 Mo."

  def failure(:unsupported_type),
    do: "Seules les images (PNG, JPEG, GIF, WebP) et les PDF sont acceptés."

  def failure(_), do: "L'assistance ne répond pas pour l'instant. Réessayez dans un instant."

  @doc "Why an upload was refused in the browser."
  def upload_error(:too_large), do: "Ce fichier dépasse 10 Mo."

  def upload_error(:not_accepted),
    do: "Seules les images (PNG, JPEG, GIF, WebP) et les PDF sont acceptés."

  def upload_error(:too_many_files), do: "Cinq fichiers au plus à la fois."
  def upload_error(_), do: "Ce fichier n'a pas pu être joint."
end
