defmodule SauronReporter.Support.Files do
  @moduledoc """
  A user's file sent to Sauron's files API (plan 29): `POST
  /support/files?conversation_id=…&name=…`, the file as the raw body,
  the report token as a bearer — never from the browser. 10 MB at most;
  PNG, JPEG, GIF, WebP or PDF, which Sauron proves by the first bytes.
  The file then goes into the conversation with the channel's
  `upload_done` (`SauronReporter.Support.upload_done/3`).
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

  defp answer({:ok, %{status: 201, body: %{"file" => file}}}), do: {:ok, file}
  defp answer({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp answer({:ok, %{status: 404}}), do: {:error, :not_found}
  defp answer({:ok, %{status: 409}}), do: {:error, :over}
  defp answer({:ok, %{status: 413}}), do: {:error, :too_large}
  defp answer({:ok, %{status: 415}}), do: {:error, :unsupported_type}
  defp answer({:ok, %{status: status}}), do: {:error, {:status, status}}
  defp answer({:error, _}), do: {:error, :unavailable}
end
