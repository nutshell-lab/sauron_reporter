defmodule SauronReporter.MixProject do
  use Mix.Project

  def project do
    [
      app: :sauron_reporter,
      version: "0.6.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Sends an app's ErrorTracker occurrences and analytics events to Sauron, the Nutshell fleet's error manager.",
      source_url: "https://github.com/nutshell-lab/sauron_reporter"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SauronReporter.Application, []}
    ]
  end

  # Test structs compiled before protocols consolidate (a String.Chars email).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:error_tracker, "~> 0.6"},
      {:req, "~> 0.5"},
      # Analytics (0.5.0): the plug and the LiveView hook. ErrorTracker
      # brings both already; named for what this library calls.
      {:plug, "~> 1.14"},
      {:phoenix_live_view, "~> 1.0"},
      # LiveViewTest's HTML parser, for the hook's tests.
      {:lazy_html, ">= 0.1.0", only: :test},
      {:telemetry, "~> 1.0"}
    ]
  end
end
