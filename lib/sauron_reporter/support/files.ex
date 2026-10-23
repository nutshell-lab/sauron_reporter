defmodule SauronReporter.Support.Files do
  @moduledoc """
  A user's file sent to Sauron's files API (plan 29): `POST
  /support/files?conversation_id=…&name=…`, the file as the raw body,
  the report token as a bearer — never from the browser. 10 MB at most;
  PNG, JPEG, GIF, WebP or PDF, which Sauron proves by the first bytes.
  The file then goes into the conversation with the channel's
  `upload_done` (`SauronReporter.Support.upload_done/4`).

  `fetch/3` reads one back for a user (0.8.1): `GET /support/files/:id?user_id=…`,
  which Sauron answers only when the file's conversation is that user's —
  what the panel shows as an image preview.
  """

  @max_size 10_000_000

  @doc "The largest file Sauron takes, in bytes."
  def max_size, do: @max_size

  @doc "The types Sauron takes."
  def content_types, do: ~w(image/png image/jpeg image/gif image/webp application/pdf)

  @doc "The extensions a LiveView upload accepts for them."
  def extensions, do: ~w(.png .jpg .jpeg .gif .webp .pdf)

  @doc """
  Uploads the file at `path` to `conversation_id` under `name`:
  `{:ok, file}` (Sauron's map: `id`, `name`, `content_type`, `size`…)
  or `{:error, reason}` — `:too_large`, `:unsupported_type`,
  `:not_found` (not this app's conversation), `:over` (its request is
  over), `:unauthorized`, `:disabled`, `{:status, status}` or
  `:unavailable`. Never raises.
  """
  def upload(conversation_id, path, name, content_type \\ nil) do
    reporter = Application.get_all_env(:sauron_reporter)
    support = reporter[:support] || []

    with true <- SauronReporter.Support.enabled?() || {:error, :disabled},
         {:ok, %{size: size}} when size <= @max_size <- File.stat(path),
         {:ok, body} <- File.read(path) do
      [
        url: String.trim_trailing(reporter[:url], "/") <> "/support/files",
        params: [conversation_id: conversation_id, name: name || Path.basename(path)],
        body: body,
        headers: [{"content-type", content_type || "application/octet-stream"}],
        auth: {:bearer, reporter[:token]},
        retry: false,
        connect_options: [timeout: 5_000],
        receive_timeout: 60_000
      ]
      |> Keyword.merge(support[:req_options] || [])
      |> Req.post()
      |> answer()
    else
      {:ok, %{size: _}} -> {:error, :too_large}
      {:error, :disabled} -> {:error, :disabled}
      {:error, _posix} -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @image_types ~w(image/png image/jpeg image/gif image/webp)

  @doc """
  The file `file_id` of one of `user_id`'s conversations, from Sauron
  (`GET /support/files/:id?user_id=…`, the token as a bearer): `{:ok,
  %{content_type: type, body: binary}}` or `{:error, reason}` —
  `:not_found` (no such file, or not that user's), `:too_large` (past
  `max_size`), `:unsupported_type`, `:unauthorized`, `:disabled`,
  `{:status, status}` or `:unavailable`. Never raises.

  Options: `max_size` (bytes, default 10 MB: the body is read no
  further), `types` (the content types taken, default the images).
  """
  def fetch(file_id, user_id, opts \\ []) do
    reporter = Application.get_all_env(:sauron_reporter)
    support = reporter[:support] || []
    max = Keyword.get(opts, :max_size, @max_size)
    types = Keyword.get(opts, :types, @image_types)

    with true <- SauronReporter.Support.enabled?() || {:error, :disabled},
         true <- (is_binary(file_id) and file_id != "") || {:error, :not_found},
         user_id when is_binary(user_id) and user_id != "" <-
           to_string(user_id || "") do
      [
        url:
          String.trim_trailing(reporter[:url], "/") <>
            "/support/files/" <> URI.encode(file_id, &URI.char_unreserved?/1),
        params: [user_id: user_id],
        auth: {:bearer, reporter[:token]},
        decode_body: false,
        compressed: false,
        retry: false,
        connect_options: [timeout: 5_000],
        receive_timeout: 30_000,
        into: &bounded(&1, &2, max)
      ]
      |> Keyword.merge(Keyword.drop(support[:req_options] || [], [:into, :decode_body]))
      |> Req.get()
      |> fetched(types)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  # The body read up to `max` bytes, no further.
  defp bounded({:data, data}, {request, response}, max) do
    if byte_size(response.body) + byte_size(data) > max,
      do: {:halt, {request, Req.Response.put_private(response, :too_large, true)}},
      else: {:cont, {request, %{response | body: response.body <> data}}}
  end

  defp fetched({:ok, %{private: %{too_large: true}}}, _types), do: {:error, :too_large}

  defp fetched({:ok, %{status: 200} = response}, types) do
    type =
      response
      |> Req.Response.get_header("content-type")
      |> List.first("")
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()

    if type in types,
      do: {:ok, %{content_type: type, body: response.body}},
      else: {:error, :unsupported_type}
  end

  defp fetched(response, _types), do: answer(response)

  defp answer({:ok, %{status: 201, body: %{"file" => file}}}), do: {:ok, file}
  defp answer({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp answer({:ok, %{status: 404}}), do: {:error, :not_found}
  defp answer({:ok, %{status: 409}}), do: {:error, :over}
  defp answer({:ok, %{status: 413}}), do: {:error, :too_large}
  defp answer({:ok, %{status: 415}}), do: {:error, :unsupported_type}
  defp answer({:ok, %{status: status}}), do: {:error, {:status, status}}
  defp answer({:error, _}), do: {:error, :unavailable}
end
