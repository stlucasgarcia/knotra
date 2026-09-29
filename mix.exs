defmodule Knotra.MixProject do
  use Mix.Project

  def project do
    [
      app: :knotra,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [~r"/support/"],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req_llm, "~> 1.24.0"},
      {:ecto, "~> 3.14", optional: true},
      {:ecto_sql, "~> 3.14", optional: true},
      {:ecto_sqlite3, "~> 0.25.0", only: :test}
    ]
  end
end
