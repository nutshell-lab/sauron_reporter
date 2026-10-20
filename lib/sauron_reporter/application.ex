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
      SauronReporter.Analytics.Buffer
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SauronReporter.Supervisor)
  end
end
