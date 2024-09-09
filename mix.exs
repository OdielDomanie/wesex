defmodule Wesex.MixProject do
  use Mix.Project

  def project do
    [
      app: :wesex,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:mint_web_socket, "~> 1.0.4"},
      {:websock_adapter, "~> 0.5", only: [:dev, :test]},
      {:bandit, "~> 1.0", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
