defmodule ElixirToSilicaPoc.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_to_silica_poc,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: false,
      deps: [],
      escript: [main_module: E2s.CLI, name: "e2s"],
      # The test environment also compiles the contract's Erlang binding and its checker (check_frame needs
      # tcp_transport_v1.beam with debug_info). Nothing is written outside _build.
      # test/fixtures holds Elixir sources the tests read (the split's fixture), not tests.
      test_ignore_filters: [~r"^test/fixtures/"],
      erlc_paths: erlc_paths(Mix.env()),
      erlc_options: [:debug_info]
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp erlc_paths(:test), do: ["../contract/bindings/erlang"]
  defp erlc_paths(_), do: []
end
