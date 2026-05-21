defmodule Mix.Tasks.Quickjs.Vendor.Check do
  @moduledoc "Validates vendored QuickJS source snapshots."
  @shortdoc "Validates vendored QuickJS source snapshots"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    case QuickjsEx.Vendor.check(File.cwd!()) do
      {:ok, sources} ->
        Mix.shell().info("Vendored QuickJS snapshots are consistent:")

        Enum.each(sources, fn source ->
          Mix.shell().info("* #{source.label}: #{source.commit}")
        end)

      {:error, errors} ->
        Mix.raise("Vendored QuickJS snapshot check failed:\n" <> Enum.join(errors, "\n"))
    end
  end
end
