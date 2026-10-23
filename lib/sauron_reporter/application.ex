defmodule SauronReporter.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # The reports are sent from tasks under it: the erroring process never waits.
      {Task.Supervisor, name: SauronReporter.TaskSupervisor},
      # Owns the throttle table; attaches to ErrorTracker when configured.
      SauronReporter,
      # Analytics events (plan 28) wait here between two sends; inert
      # until `analytics: [enabled: true]`.
      SauronReporter.Analytics.Buffer,
      # Support (plan 29): the page's LiveView and the panel find each
      # other here; the client is the app's one WebSocket to Sauron,
      # inert until `support: [enabled: true, pubsub: ...]`.
      {Registry, keys: :duplicate, name: SauronReporter.Support.Registry},
      SauronReporter.Support.Client
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SauronReporter.Supervisor)
  end
end
