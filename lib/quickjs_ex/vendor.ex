defmodule QuickjsEx.Vendor do
  @moduledoc false

  @manifest_path "vendor/quickjs_sources.exs"
  @safe_targets ["c_src/quickjs_ng", "priv/zig/zig_quickjs_ng"]

  def manifest_path(root \\ File.cwd!()) do
    Path.join(root, @manifest_path)
  end

  def load_manifest!(root \\ File.cwd!()) do
    path = manifest_path(root)

    with {sources, []} <- Code.eval_file(path) do
      Enum.map(sources, &normalize_source!/1)
    else
      {_sources, binding} ->
        raise "vendor manifest must not bind variables, got: #{inspect(binding)}"

      other ->
        raise "invalid vendor manifest result: #{inspect(other)}"
    end
  end

  def check(root \\ File.cwd!()) do
    sources = load_manifest!(root)
    errors = Enum.flat_map(sources, &check_source(root, &1))

    if errors == [] do
      {:ok, sources}
    else
      {:error, errors}
    end
  end

  def update!(root \\ File.cwd!(), opts \\ []) do
    sources = load_manifest!(root)
    latest? = Keyword.get(opts, :latest, false)
    refs = Keyword.get(opts, :refs, %{})

    updated_sources =
      Enum.map(sources, fn source ->
        ref = Map.get(refs, source.name) || if(latest?, do: "HEAD", else: source.commit)
        update_source!(root, source, ref)
      end)

    write_manifest!(root, updated_sources)

    case check(root) do
      {:ok, checked_sources} -> checked_sources
      {:error, errors} -> raise Enum.join(errors, "\n")
    end
  end

  def vendor_header(source, commit \\ nil) do
    commit = commit || source.commit
    text = "VENDORED: copied from #{source.upstream} commit #{commit}."

    case source.header_style do
      :c_block -> "/* #{text} */"
      :line_comment -> "// #{text}"
    end
  end

  defp normalize_source!(source) when is_map(source) do
    required = [
      :name,
      :label,
      :upstream,
      :repo,
      :commit,
      :source_dir,
      :target_dir,
      :header_style,
      :local_files,
      :replacements,
      :files
    ]

    missing = Enum.reject(required, &Map.has_key?(source, &1))

    if missing != [] do
      raise "vendor source #{inspect(source[:name])} missing keys: #{inspect(missing)}"
    end

    unless is_atom(source.name) do
      raise "vendor source name must be an atom: #{inspect(source.name)}"
    end

    unless source.header_style in [:c_block, :line_comment] do
      raise "unsupported vendor header style for #{source.name}: #{inspect(source.header_style)}"
    end

    unless Enum.all?(source.files, &is_binary/1) and Enum.all?(source.local_files, &is_binary/1) do
      raise "vendor source #{source.name} files and local_files must all be strings"
    end

    unless Enum.all?(source.replacements, &valid_replacement?/1) do
      raise "vendor source #{source.name} replacements must be {from, to} string tuples"
    end

    %{
      source
      | files: Enum.sort(source.files),
        local_files: Enum.sort(source.local_files),
        replacements: source.replacements
    }
  end

  defp normalize_source!(source) do
    raise "vendor source must be a map: #{inspect(source)}"
  end

  defp check_source(root, source) do
    target_dir = Path.expand(source.target_dir, root)

    case File.ls(target_dir) do
      {:ok, entries} ->
        actual_files =
          entries
          |> Enum.filter(&File.regular?(Path.join(target_dir, &1)))
          |> Enum.sort()

        directory_errors =
          entries
          |> Enum.filter(&File.dir?(Path.join(target_dir, &1)))
          |> Enum.map(
            &"#{source.label}: unexpected directory #{Path.join(source.target_dir, &1)}"
          )

        allowlist_errors =
          diff_allowlist(source, actual_files)

        header_errors =
          Enum.flat_map(source.files, fn file ->
            check_file_header(source, Path.join(target_dir, file))
          end)

        rewrite_errors =
          Enum.flat_map(source.files, fn file ->
            check_file_rewrites(source, Path.join(target_dir, file))
          end)

        directory_errors ++ allowlist_errors ++ header_errors ++ rewrite_errors

      {:error, reason} ->
        ["#{source.label}: target directory #{source.target_dir} is unavailable: #{reason}"]
    end
  end

  defp diff_allowlist(source, actual_files) do
    expected_files = Enum.sort(source.files ++ source.local_files)
    missing = expected_files -- actual_files
    extra = actual_files -- expected_files

    Enum.map(
      missing,
      &"#{source.label}: missing vendored file #{Path.join(source.target_dir, &1)}"
    ) ++
      Enum.map(
        extra,
        &"#{source.label}: unexpected vendored file #{Path.join(source.target_dir, &1)}"
      )
  end

  defp check_file_header(source, path) do
    case File.read(path) do
      {:ok, contents} ->
        expected = vendor_header(source)
        first_line = contents |> String.split("\n", parts: 2) |> hd()

        if first_line == expected do
          []
        else
          ["#{source.label}: #{Path.relative_to_cwd(path)} has stale or missing vendor header"]
        end

      {:error, reason} ->
        ["#{source.label}: could not read #{Path.relative_to_cwd(path)}: #{reason}"]
    end
  end

  defp update_source!(root, source, ref) do
    root = Path.expand(root)

    tmp_root =
      Path.join(System.tmp_dir!(), "quickjs_ex_vendor_#{System.unique_integer([:positive])}")

    checkout_dir = Path.join(tmp_root, Atom.to_string(source.name))
    tmp_target_dir = Path.join(tmp_root, "target")

    File.rm_rf!(tmp_root)
    File.mkdir_p!(tmp_root)

    try do
      run_git!(["clone", "--quiet", source.repo, checkout_dir])

      if ref != "HEAD" do
        run_git!(["-C", checkout_dir, "checkout", "--quiet", ref])
      end

      commit = run_git!(["-C", checkout_dir, "rev-parse", "HEAD"])
      File.mkdir_p!(tmp_target_dir)

      Enum.each(source.files, fn file ->
        source_path = Path.join([checkout_dir, source.source_dir, file])
        target_path = Path.join(tmp_target_dir, file)
        body = source_path |> File.read!() |> strip_vendor_header() |> apply_replacements(source)
        File.write!(target_path, vendor_header(source, commit) <> "\n" <> body)
      end)

      replace_target_files!(root, source, tmp_target_dir)
      %{source | commit: commit}
    after
      File.rm_rf(tmp_root)
    end
  end

  defp replace_target_files!(root, source, tmp_target_dir) do
    target_dir = Path.expand(source.target_dir, root)
    relative_target = Path.relative_to(target_dir, root)

    unless relative_target in @safe_targets do
      raise "refusing to replace unexpected vendored target: #{relative_target}"
    end

    File.mkdir_p!(target_dir)

    Enum.each(source.files, fn file ->
      File.rm(Path.join(target_dir, file))
      File.cp!(Path.join(tmp_target_dir, file), Path.join(target_dir, file))
    end)

    prune_unexpected_files!(source, target_dir)
  end

  defp prune_unexpected_files!(source, target_dir) do
    expected = MapSet.new(source.files ++ source.local_files)

    target_dir
    |> File.ls!()
    |> Enum.filter(&File.regular?(Path.join(target_dir, &1)))
    |> Enum.reject(&MapSet.member?(expected, &1))
    |> Enum.each(&File.rm!(Path.join(target_dir, &1)))
  end

  defp strip_vendor_header(contents) do
    case String.split(contents, "\n", parts: 2) do
      [first_line, rest] ->
        if String.contains?(first_line, "VENDORED: copied from") do
          rest
        else
          contents
        end

      [_] ->
        contents
    end
  end

  defp write_manifest!(root, sources) do
    manifest =
      sources
      |> render_manifest()
      |> Code.format_string!()
      |> IO.iodata_to_binary()

    File.write!(manifest_path(root), manifest)
  end

  defp render_manifest(sources) do
    inspect(sources, pretty: true, limit: :infinity, printable_limit: :infinity) <> "\n"
  end

  defp run_git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} ->
        String.trim(output)

      {output, status} ->
        raise "git #{Enum.join(args, " ")} failed with status #{status}:\n#{output}"
    end
  end

  defp valid_replacement?({from, to}), do: is_binary(from) and is_binary(to)
  defp valid_replacement?(_other), do: false

  defp apply_replacements(contents, source) do
    Enum.reduce(source.replacements, contents, fn {from, to}, acc ->
      String.replace(acc, from, to)
    end)
  end

  defp check_file_rewrites(source, path) do
    case File.read(path) do
      {:ok, contents} ->
        Enum.flat_map(source.replacements, fn {from, _to} ->
          if String.contains?(contents, from) do
            [
              "#{source.label}: #{Path.relative_to_cwd(path)} is missing local vendor rewrite #{inspect(from)}"
            ]
          else
            []
          end
        end)

      {:error, _reason} ->
        []
    end
  end
end
