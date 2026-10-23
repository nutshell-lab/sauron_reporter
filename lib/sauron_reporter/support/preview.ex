defmodule SauronReporter.Support.Preview do
  @moduledoc """
  An image of the conversation, shown in the panel (0.8.1): a
  LiveComponent the panel renders for each `image` message.

  The panel's server fetches the image from Sauron for the panel's user
  (`SauronReporter.Support.fetch_file/3`, `GET /support/files/:id?user_id=…`,
  which Sauron answers only when the file's conversation is that
  user's) and renders it as a `data:` URL. The browser never sees
  Sauron's URL nor its token, and the app mounts no route.

  A component, so the image crosses the LiveView socket once: the
  panel's log re-renders on every message, a component only when its
  own assigns change. Images past `preview_max_size` (3 MB by default;
  `0` turns previews off), a fetch that fails, and PDFs stay chips. An
  app with a Content-Security-Policy allows `img-src data:`.
  """

  use Phoenix.LiveComponent

  alias SauronReporter.Support
  alias SauronReporter.Support.Copy

  @default_max 3_000_000

  @doc "The largest image previewed, in bytes (`preview_max_size`); 0 when previews are off."
  def max_size do
    case Support.setting(:preview_max_size, @default_max) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_max
    end
  end

  @impl true
  def mount(socket), do: {:ok, assign(socket, src: nil, state: :idle)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, file: assigns.file, user_id: assigns.user_id)
    {:ok, maybe_fetch(socket)}
  end

  defp maybe_fetch(%{assigns: %{state: :idle, file: file, user_id: user_id}} = socket) do
    max = max_size()
    size = file["size"]

    cond do
      not connected?(socket) ->
        socket

      max == 0 or not is_binary(file["file_id"]) or not is_binary(user_id) or
          (is_integer(size) and size > max) ->
        assign(socket, :state, :chip)

      true ->
        file_id = file["file_id"]

        socket
        |> assign(:state, :loading)
        |> start_async(:fetch, fn -> Support.fetch_file(file_id, user_id, max_size: max) end)
    end
  end

  defp maybe_fetch(socket), do: socket

  @impl true
  def handle_async(:fetch, {:ok, {:ok, %{content_type: type, body: body}}}, socket) do
    {:noreply, assign(socket, state: :shown, src: "data:#{type};base64," <> Base.encode64(body))}
  end

  def handle_async(:fetch, _result, socket), do: {:noreply, assign(socket, :state, :chip)}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="aide-shot-wrap">
      <img
        :if={@src}
        class="aide-shot"
        src={@src}
        alt={"Image jointe : #{@file["name"]}"}
        loading="lazy"
      />
      <div :if={is_nil(@src)} class="aide-file">
        <svg width="14" height="16" viewBox="0 0 18 20" aria-hidden="true">
          <path d="M2 1h9l5 5v13H2z M11 1v5h5" fill="none" stroke="currentColor" stroke-width="1.6" />
        </svg>
        <span>{@file["name"]} <small>{Copy.size(@file["size"])}</small></span>
      </div>
    </div>
    """
  end
end
