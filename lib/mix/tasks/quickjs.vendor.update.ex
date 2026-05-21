defmodule Mix.Tasks.Quickjs.Vendor.Update do
  @moduledoc """
  Updates checked-in QuickJS vendor snapshots from their upstream repositories.

      mix quickjs.vendor.update
      mix quickjs.vendor.update --latest
      mix quickjs.vendor.update --quickjs-ng-ref <ref> --zig-quickjs-ng-ref <ref>

  With no options, the task refreshes the currently pinned commits from
  `vendor/quickjs_sources.exs`. Use `--latest` to update both sources to each
  repository's default branch HEAD.
  """

  @shortdoc "Updates checked-in QuickJS vendor snapshots"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    opts = parse_args!(args)

    sources =
      QuickjsEx.Vendor.update!(File.cwd!(),
        latest: Keyword.get(opts, :latest, false),
        refs: refs_from_opts(opts)
      )

    Mix.shell().info("Updated vendored QuickJS snapshots:")

    Enum.each(sources, fn source ->
      Mix.shell().info("* #{source.label}: #{source.commit}")
    end)

    Mix.shell().info("Run mix quickjs.vendor.check and the normal test suite before committing.")
  end

  defp parse_args!(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          latest: :boolean,
          quickjs_ng_ref: :string,
          zig_quickjs_ng_ref: :string
        ]
      )

    if rest != [] do
      Mix.raise("Unexpected positional arguments: #{Enum.join(rest, " ")}")
    end

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    opts
  end

  defp refs_from_opts(opts) do
    %{}
    |> maybe_put_ref(:quickjs_ng, opts[:quickjs_ng_ref])
    |> maybe_put_ref(:zig_quickjs_ng, opts[:zig_quickjs_ng_ref])
  end

  defp maybe_put_ref(refs, _name, nil), do: refs
  defp maybe_put_ref(refs, name, ref), do: Map.put(refs, name, ref)
end
