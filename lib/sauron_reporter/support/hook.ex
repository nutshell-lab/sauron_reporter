defmodule SauronReporter.Support.Hook do
  @moduledoc """
  What the page's LiveView and the support panel tell each other — an
  `on_mount` hook for the app's `live_session`s that carry the panel:

      live_session :app, on_mount: [MyAppWeb.UserAuth, SauronReporter.Support.Hook] do

    * **the unread count**: the hook assigns `@sauron_support_unread`
      (an integer, 0 at first) and keeps it as the panel counts the
      answers that arrive while it is closed — for the app's own menu
      button and its dot (`launcher={false}`);
    * **the page**: on each live navigation the panel hears the new path
      and tells Sauron where the user is (a sticky panel outlives the
      page that rendered it, so its `page` attribute is the first page
      only).

  The two find each other by the socket's transport (the browser tab),
  in `SauronReporter.Support.Registry`. Without the hook the panel works
  all the same; the app has no unread count, and the page Sauron sees
  is the one the panel was mounted on.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias SauronReporter.Support

  @registry SauronReporter.Support.Registry

  @doc false
  def on_mount(_arg, _params, _session, socket) do
    socket = assign(socket, :sauron_support_unread, 0)

    if connected?(socket) and Support.enabled?() and socket.transport_pid do
      Registry.register(@registry, socket.transport_pid, :listener)
      tell_panels(socket, {Support, :hello, self()})

      socket =
        socket
        |> attach_hook(:sauron_support_unread, :handle_info, &unread/2)
        |> then(fn socket ->
          if root?(socket),
            do: attach_hook(socket, :sauron_support_page, :handle_params, &page/3),
            else: socket
        end)

      {:cont, socket}
    else
      {:cont, socket}
    end
  rescue
    _ -> {:cont, socket}
  end

  defp unread({Support, :unread, count}, socket) when is_integer(count),
    do: {:halt, assign(socket, :sauron_support_unread, count)}

  defp unread(_message, socket), do: {:cont, socket}

  defp page(_params, uri, socket) do
    tell_panels(socket, {Support, :page, URI.parse(uri).path})
    {:cont, socket}
  end

  defp tell_panels(socket, message) do
    for {pid, :panel} <- Registry.lookup(@registry, socket.transport_pid), do: send(pid, message)
  end

  # `handle_params` hooks belong to LiveViews mounted by the router.
  defp root?(socket), do: is_nil(socket.parent_pid) and socket.router != nil
end
