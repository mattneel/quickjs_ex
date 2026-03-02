defmodule QuickjsEx.MixProject do
  use Mix.Project
  @version "0.1.0"

  def project do
    [
      app: :quickjs_ex,
      version: @version,
      name: "QuickjsEx",
      elixir: "~> 1.19",
      description: "Embed QuickJS-NG JavaScript engine in Elixir via Zig NIFs",
      source_url: "https://github.com/your-org/quickjs_ex",
      docs: [
        main: "readme",
        extras: ["README.md", "MIGRATION.md"],
        source_ref: "v#{@version}"
      ],
      compilers: Mix.compilers(),
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
      {:zigler, "== 0.15.2", runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
