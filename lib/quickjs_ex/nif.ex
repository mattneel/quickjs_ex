defmodule QuickjsEx.NIF do
  @required_zig_version "0.15.2"

  @zig_on_path (case System.find_executable("zig") do
                  nil ->
                    raise """
                    quickjs_ex requires Zig #{@required_zig_version} on PATH.
                    Install it from https://ziglang.org/download/
                    """

                  path ->
                    path
                end)

  @zig_executable (case System.cmd(@zig_on_path, [@required_zig_version, "env"],
                          stderr_to_stdout: true
                        ) do
                     {versioned_env_output, 0} ->
                       case Regex.run(
                              ~r/(?:\"zig_exe\"\s*:\s*|\.zig_exe\s*=\s*)\"([^\"]+)\"/,
                              versioned_env_output,
                              capture: :all_but_first
                            ) do
                         [resolved_path] ->
                           resolved_path

                         _ ->
                           @zig_on_path
                       end

                     _ ->
                       @zig_on_path
                   end)

  # Force Zigler to use the same local Zig executable used in CI and docs.
  System.put_env("ZIG_EXECUTABLE_PATH", @zig_executable)

  @detected_zig_version (case System.cmd(@zig_executable, ["version"], stderr_to_stdout: true) do
                           {version_output, 0} ->
                             case Regex.run(~r/\d+\.\d+\.\d+/, version_output) do
                               [version] ->
                                 version

                               _ ->
                                 raise """
                                 failed to parse Zig version output from #{@zig_executable}: #{String.trim(version_output)}
                                 """
                             end

                           {error_output, status} ->
                             raise """
                             failed to run Zig from #{@zig_executable} (exit #{status}): #{String.trim(error_output)}
                             """
                         end)

  if @detected_zig_version != @required_zig_version do
    raise """
    quickjs_ex requires Zig #{@required_zig_version}, found #{@detected_zig_version} at #{@zig_executable}
    """
  end

  use Zig,
    otp_app: :quickjs_ex,
    zig_code_path: "nif.zig",
    extra_modules: [
      quickjs_c: {"../../priv/zig/zig_quickjs_ng/quickjs_c.zig", []},
      zig_quickjs_ng: {"../../priv/zig/zig_quickjs_ng/quickjs.zig", [:quickjs_c]}
    ],
    # QuickJS-NG C sources (vendored at c_src/quickjs_ng/)
    # Pulled in here so they are compiled but not used until T2.
    c: [
      src: [
        "../../c_src/quickjs_ng/quickjs.c",
        "../../c_src/quickjs_ng/cutils.c",
        "../../c_src/quickjs_ng/dtoa.c",
        "../../c_src/quickjs_ng/libregexp.c",
        "../../c_src/quickjs_ng/libunicode.c"
      ],
      include_dirs: ["../../c_src/quickjs_ng"]
    ],
    resources: [:JsContextResource],
    nifs: [
      ping: [],
      nif_new: [:dirty_cpu],
      nif_eval: [:dirty_cpu],
      nif_get: [],
      nif_set_value: [],
      nif_set_path: [],
      nif_gc: [],
      nif_register_callback: [:dirty_cpu],
      nif_set_callback_runner: [],
      nif_signal_callback_result: [],
      nif_transfer_owner: []
    ]
end
