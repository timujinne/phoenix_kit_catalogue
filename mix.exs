defmodule PhoenixKitCatalogue.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_catalogue"

  def project do
    [
      app: :phoenix_kit_catalogue,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Elixir 1.19 mix test requires explicit filters to know which test
      # files to load and which to ignore. Without this it warns about
      # `test/support/*.ex` not matching either filter and skips running
      # the support modules through its loader, which means
      # `test_helper.exs` runs before they're available.
      test_load_filters: [~r/_test\.exs$/],
      test_ignore_filters: [~r{^test/support/}],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Catalogue module for PhoenixKit — manufacturers, suppliers, and product catalogues.",
      package: package(),
      dialyzer: [plt_add_apps: [:phoenix_kit]],
      name: "PhoenixKitCatalogue",
      source_url: @source_url,
      docs: docs(),
      aliases: aliases(),
      test_coverage: [
        ignore_modules: [
          ~r/^PhoenixKitCatalogue\.Test\./,
          PhoenixKitCatalogue.DataCase,
          PhoenixKitCatalogue.LiveCase,
          PhoenixKitCatalogue.ActivityLogAssertions,
          # NimbleCSV-generated parser modules — macro-defined CSV
          # readers from the `nimble_csv` dep, not production code
          # we own. Their internal branches are NimbleCSV's contract
          # to test, not ours.
          PhoenixKitCatalogue.Import.CommaParser,
          PhoenixKitCatalogue.Import.SemicolonParser,
          PhoenixKitCatalogue.Import.TabParser
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :phoenix_kit]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: ["compile", "quality"]
    ]
  end

  defp deps do
    [
      {:phoenix_kit, "~> 1.7"},
      {:phoenix_live_view, "~> 1.1"},
      {:xlsx_reader, "~> 0.8"},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Test-only: LazyHtml parses rendered HTML so Phoenix.LiveViewTest
      # can assert on LiveView output in `live/2` and friends.
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib guides .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitCatalogue",
      source_ref: @version,
      extras: [
        "guides/smart_catalogues.md": [title: "Smart Catalogues"]
      ],
      groups_for_extras: [
        Guides: ~r"guides/.+\.md"
      ]
    ]
  end
end
