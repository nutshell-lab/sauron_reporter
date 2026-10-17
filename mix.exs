defmodule SauronReporter.MixProject do
  use Mix.Project

  def project do
    [
      app: :sauron_reporter,
      version: "0.4.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Sends an app's ErrorTracker occurrences to Sauron, the Nutshell fleet's error manager.",
      source_url: "https://github.com/nutshell-lab/sauron_reporter"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SauronReporter.Application, []}
    ]
  end

  defp deps do
    [
      {:error_tracker, "~> 0.6"},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
