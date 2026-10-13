defmodule KnotraBots.MixProject do
  use Mix.Project

  def project do
    [
      app: :knotra_bots,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      aliases: [setup: ["deps.get", "knotra_bots.migrate"]],
      deps: deps()
    ]
  end

  def application do
    [
      mod: {KnotraBots.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:knotra, path: "../.."},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.3"},
      {:bandit, "~> 1.12"},
      {:req_llm, "~> 1.24"},
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, "~> 0.25.0"},
      {:dotenvy, "~> 1.1"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
