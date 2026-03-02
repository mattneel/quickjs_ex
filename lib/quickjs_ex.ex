defmodule QuickjsEx do
  @moduledoc """
  QuickjsEx embeds the QuickJS-NG engine in Elixir through Zig NIFs, without Node.js,
  and executes modern JavaScript (ES2023) inside a sandboxed runtime.

  ## Quick start

      iex> {:ok, ctx} = QuickjsEx.new(timeout: 100)
      iex> {:ok, 42} = QuickjsEx.eval(ctx, "40 + 2")
      iex> {:ok, ctx} = QuickjsEx.set(ctx, :sum, fn [a, b] -> a + b end)
      iex> {:ok, 7} = QuickjsEx.eval(ctx, "sum(3, 4)")

      iex> {:error, {:js_error, _message}} = QuickjsEx.eval(ctx, "throw new Error('boom')")

  ## See also

  For structured API modules, macros, and install hooks, see `QuickjsEx.API`.
  """

  alias QuickjsEx.CallbackRunner
  alias QuickjsEx.Context
  alias QuickjsEx.NIF
  alias QuickjsEx.RuntimeException

  @poisoned_ref_key {__MODULE__, :poisoned_ref}
  @callback_aliases_key {__MODULE__, :callback_aliases}
  @default_stack_limit 256 * 1024
  @bootstrap_min_memory 64 * 1024
  @runtime_bootstrap """
  (function () {
    var g = (typeof globalThis !== "undefined") ? globalThis : this;
    if (typeof g.console !== "object" || g.console === null) g.console = {};
    if (typeof g.console.log !== "function") {
      g.console.log = function () {
        return undefined;
      };
    }
  })();
  """

  @doc """
  Creates a new JavaScript context.

  ## Options

  | Option | Type | Default | Description |
  | --- | --- | --- | --- |
  | `:memory_limit` | integer | `4_000_000` | Runtime heap limit in bytes. |
  | `:stack_limit` | integer | `262_144` | C stack limit in bytes. |
  | `:timeout` | integer | `0` | Default evaluation timeout in milliseconds (`0` disables timeout). |

  ## Returns

  - `{:ok, ctx}` when the context is created.
  - `{:error, reason}` when creation fails, where `reason` is normalized to:
    - `:timeout`
    - `:oom`
    - `:context_poisoned`
    - `:not_owner`
    - `:sandbox_violation`
    - `:async_not_supported`
    - `:internal_error`
    - `{:js_error, message}`
    - `{:callback_error, callback_name, message}`
    - `{:invalid_api_module, message}`
    - any other passthrough error term

  ## Examples

      iex> {:ok, _ctx} = QuickjsEx.new(memory_limit: 8_000_000, timeout: 250)

      iex> match?({:error, _reason}, QuickjsEx.new(memory_limit: -1))
      true
  """
  def new(opts \\ []) do
    memory_limit = Keyword.get(opts, :memory_limit, 4_000_000)
    stack_limit = Keyword.get(opts, :stack_limit, @default_stack_limit)
    timeout = Keyword.get(opts, :timeout, 0)

    {:ok, runner_pid} = CallbackRunner.start_link()

    case NIF.nif_new(memory_limit, stack_limit, timeout) do
      {:ok, ref} ->
        clear_poisoned_ref(ref)

        ctx =
          ref
          |> Context.new()
          |> put_private(:__runner_pid__, runner_pid)
          |> sync_poisoned_context()

        case NIF.nif_set_callback_runner(ref, runner_pid) do
          :ok ->
            maybe_bootstrap_runtime(ref, memory_limit)
            {:ok, ctx}

          {:error, reason} ->
            send(runner_pid, :stop)
            {:error, normalise_error(reason)}
        end

      {:error, reason} ->
        send(runner_pid, :stop)
        {:error, normalise_error(reason)}
    end
  end

  @doc """
  Evaluates JavaScript code in a context.

  Accepts `ctx`, a JavaScript source string, and optional `opts`:

  - `:timeout` - evaluation timeout in milliseconds for this call (`0` disables timeout)

  Contexts remain reusable after JavaScript exceptions (`{:js_error, message}`).
  Recreate the context after non-recoverable errors like `:oom` or `:internal_error`.

  ## Returns

  - `{:ok, value}` on successful evaluation.
  - `{:error, reason}` on failure, where `reason` is one of:
    - `:timeout`
    - `:oom`
    - `:context_poisoned`
    - `:not_owner`
    - `:sandbox_violation`
    - `:async_not_supported`
    - `:internal_error`
    - `{:js_error, message}`
    - `{:callback_error, callback_name, message}`
    - `{:invalid_api_module, message}`
    - any other passthrough error term

  ## Examples

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> {:ok, 42} = QuickjsEx.eval(ctx, "40 + 2")

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> {:error, {:js_error, _message}} = QuickjsEx.eval(ctx, "throw new Error('boom')")
  """
  def eval(ctx, code, opts \\ [])

  def eval(%Context{} = ctx, code, opts) when is_binary(code) do
    if context_poisoned?(ctx) do
      {:error, :context_poisoned}
    else
      timeout = Keyword.get(opts, :timeout, 0)

      case NIF.nif_eval(ctx.ref, code, timeout) do
        {:ok, _result} = ok ->
          ok

        {:error, raw_reason} ->
          reason =
            raw_reason
            |> normalise_error()
            |> remap_callback_alias(ctx)

          _ = track_poisoned_error(ctx, reason)
          {:error, reason}
      end
    end
  end

  @doc """
  Evaluates JavaScript code and raises on failure.

  This is the raising variant of `eval/3`.

  ## Returns

  - `{result, ctx}` on success.

  ## Raises

  - `QuickjsEx.RuntimeException` for the same normalized error categories as `eval/3`.

  ## Examples

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> {42, _ctx} = QuickjsEx.eval!(ctx, "40 + 2")

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> try do
      ...>   QuickjsEx.eval!(ctx, "throw new Error('boom')")
      ...> rescue
      ...>   e in QuickjsEx.RuntimeException -> e.category
      ...> end
      :js_error
  """
  def eval!(%Context{} = ctx, code) when is_binary(code) do
    case eval(ctx, code) do
      {:ok, result} -> {result, sync_poisoned_context(ctx)}
      {:error, reason} -> raise_error(reason)
    end
  end

  @doc """
  Reads a JavaScript global value by name.

  `name` can be an atom or string.

  ## Returns

  - `{:ok, value}` when the global exists and can be converted.
  - `{:error, reason}` when access fails, where `reason` is one of:
    - `:timeout`
    - `:oom`
    - `:context_poisoned`
    - `:not_owner`
    - `:sandbox_violation`
    - `:async_not_supported`
    - `:internal_error`
    - `{:js_error, message}`
    - `{:callback_error, callback_name, message}`
    - `{:invalid_api_module, message}`
    - any other passthrough error term

  ## Examples

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> {:ok, ctx} = QuickjsEx.set(ctx, :answer, 42)
      iex> {:ok, 42} = QuickjsEx.get(ctx, :answer)

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> {:error, {:js_error, _message}} = QuickjsEx.get(ctx, "missing.value")
  """
  def get(%Context{} = ctx, name) when is_atom(name) or is_binary(name) do
    if context_poisoned?(ctx) do
      {:error, :context_poisoned}
    else
      case NIF.nif_get(ctx.ref, to_string(name)) do
        {:ok, _value} = ok ->
          ok

        {:error, raw_reason} ->
          reason = normalise_error(raw_reason)
          _ = track_poisoned_error(ctx, reason)
          {:error, reason}
      end
    end
  end

  @doc """
  Reads a JavaScript global and raises on failure.

  ## Returns

  - `value` on success.

  ## Raises

  - `QuickjsEx.RuntimeException` for the same normalized error categories as `get/2`.

  ## Examples

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> {:ok, ctx} = QuickjsEx.set(ctx, :answer, 42)
      iex> 42 = QuickjsEx.get!(ctx, :answer)

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> try do
      ...>   QuickjsEx.get!(ctx, "missing.value")
      ...> rescue
      ...>   e in QuickjsEx.RuntimeException -> e.category
      ...> end
      :js_error
  """
  def get!(%Context{} = ctx, name) when is_atom(name) or is_binary(name) do
    case get(ctx, name) do
      {:ok, value} -> value
      {:error, reason} -> raise_error(reason)
    end
  end

  @doc """
  Sets a JavaScript global value, callback, or nested path.

  Supported call forms:

  - `set(ctx, name, value)` sets a global scalar or structured Elixir value.
  - `set(ctx, name, fun)` registers a native callback callable from JavaScript.
    Callback functions receive a single list of arguments, e.g. `fn [a, b] -> a + b end`.
  - `set(ctx, path_list, value)` creates/updates nested globals by path segments,
    e.g. `set(ctx, [:config, :debug], true)`.

  ## Returns

  - `{:ok, ctx}` on success.
  - `{:error, reason}` on failure, where `reason` is one of:
    - `:timeout`
    - `:oom`
    - `:context_poisoned`
    - `:not_owner`
    - `:sandbox_violation`
    - `:async_not_supported`
    - `:internal_error`
    - `{:js_error, message}`
    - `{:callback_error, callback_name, message}`
    - `{:invalid_api_module, message}`
    - any other passthrough error term

  ## Examples

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> {:ok, ctx} = QuickjsEx.set(ctx, :answer, 42)
      iex> {:ok, 42} = QuickjsEx.eval(ctx, "answer")

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> {:ok, ctx} = QuickjsEx.set(ctx, :sum, fn [a, b] -> a + b end)
      iex> {:ok, 7} = QuickjsEx.eval(ctx, "sum(3, 4)")

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> {:ok, ctx} = QuickjsEx.set(ctx, [:config, :debug], true)
      iex> {:ok, true} = QuickjsEx.eval(ctx, "config.debug")

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> {:error, :context_poisoned} = QuickjsEx.set(QuickjsEx.Context.poison(ctx), :x, 1)
  """
  def set(%Context{} = ctx, name, fun)
      when (is_atom(name) or is_binary(name)) and is_function(fun) do
    if context_poisoned?(ctx) do
      {:error, :context_poisoned}
    else
      name_str = to_string(name)
      runner_pid = get_private!(ctx, :__runner_pid__)

      case NIF.nif_register_callback(ctx.ref, name_str, nil) do
        :ok ->
          :ok = CallbackRunner.register(runner_pid, name_str, fun)

          callback_ctx =
            ctx
            |> Context.put_callback(name_str, fun)
            |> sync_poisoned_context()

          {:ok, callback_ctx}

        {:error, raw_reason} ->
          reason = normalise_error(raw_reason)
          _ = track_poisoned_error(ctx, reason)
          {:error, reason}
      end
    end
  end

  def set(%Context{} = ctx, name, value) when is_atom(name) or is_binary(name) do
    if context_poisoned?(ctx) do
      {:error, :context_poisoned}
    else
      case NIF.nif_set_value(ctx.ref, to_string(name), value) do
        :ok ->
          {:ok, sync_poisoned_context(ctx)}

        {:error, raw_reason} ->
          reason = normalise_error(raw_reason)
          _ = track_poisoned_error(ctx, reason)
          {:error, reason}
      end
    end
  end

  def set(%Context{} = ctx, path, value) when is_list(path) do
    if context_poisoned?(ctx) do
      {:error, :context_poisoned}
    else
      path_segments = Enum.map(path, &to_string/1)

      case NIF.nif_set_path(ctx.ref, path_segments, value) do
        :ok ->
          {:ok, sync_poisoned_context(ctx)}

        {:error, raw_reason} ->
          reason = normalise_error(raw_reason)
          _ = track_poisoned_error(ctx, reason)
          {:error, reason}
      end
    end
  end

  @doc """
  Raising variant of `set/3`.

  ## Returns

  - `ctx` on success.

  ## Raises

  - `QuickjsEx.RuntimeException` for the same normalized error categories as `set/3`.

  ## Examples

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> _ctx = QuickjsEx.set!(ctx, :answer, 42)

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> try do
      ...>   QuickjsEx.set!(QuickjsEx.Context.poison(ctx), :x, 1)
      ...> rescue
      ...>   e in QuickjsEx.RuntimeException -> e.category
      ...> end
      :context_poisoned
  """
  def set!(%Context{} = ctx, name_or_path, value) do
    case set(ctx, name_or_path, value) do
      {:ok, new_ctx} -> new_ctx
      {:error, reason} -> raise_error(reason)
    end
  end

  @doc """
  Loads a `QuickjsEx.API` module into a context.

  The module must implement `scope/0` and `__js_functions__/0` as provided by
  `use QuickjsEx.API`.

  ## Returns

  - `{:ok, ctx}` when API callbacks and install hook succeed.
  - `{:error, {:invalid_api_module, message}}` when module callbacks are missing or invalid.
  - `{:error, reason}` for runtime registration failures, where `reason` can be:
    - `:timeout`
    - `:oom`
    - `:context_poisoned`
    - `:not_owner`
    - `:sandbox_violation`
    - `:async_not_supported`
    - `:internal_error`
    - `{:js_error, message}`
    - `{:callback_error, callback_name, message}`
    - `{:invalid_api_module, message}`
    - any other passthrough error term

  ## Examples

      iex> defmodule MathAPI do
      ...>   use QuickjsEx.API
      ...>   defjs add(a, b), do: a + b
      ...> end
      iex> {:ok, ctx} = QuickjsEx.new()
      iex> {:ok, ctx} = QuickjsEx.load_api(ctx, MathAPI)
      iex> {:ok, 3} = QuickjsEx.eval(ctx, "add(1, 2)")

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> {:error, {:invalid_api_module, _message}} = QuickjsEx.load_api(ctx, String)
  """
  def load_api(%Context{} = ctx, module, data \\ nil) when is_atom(module) do
    try do
      scope = module.scope()
      functions = module.__js_functions__()

      case register_api_callbacks(ctx, module, scope, functions) do
        {:ok, callbacks_ctx} ->
          installed_ctx =
            callbacks_ctx
            |> Context.add_loaded_api(module)
            |> QuickjsEx.API.install(module, scope, data)
            |> sync_poisoned_context()

          {:ok, installed_ctx}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e in UndefinedFunctionError ->
        {:error, normalise_error({:invalid_api_module, Exception.message(e)})}

      e in RuntimeException ->
        {:error, normalise_error({:invalid_api_module, Exception.message(e)})}
    end
  end

  @doc """
  Raising variant of `load_api/3`.

  ## Returns

  - `ctx` on success.

  ## Raises

  - `QuickjsEx.RuntimeException` for all normalized errors from `load_api/3`,
    including `{:invalid_api_module, message}`.

  ## Examples

      iex> defmodule MathAPI2 do
      ...>   use QuickjsEx.API
      ...>   defjs add(a, b), do: a + b
      ...> end
      iex> {:ok, ctx} = QuickjsEx.new()
      iex> _ctx = QuickjsEx.load_api!(ctx, MathAPI2)

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> try do
      ...>   QuickjsEx.load_api!(ctx, String)
      ...> rescue
      ...>   e in QuickjsEx.RuntimeException -> e.category
      ...> end
      :invalid_api_module
  """
  def load_api!(%Context{} = ctx, module, data \\ nil) when is_atom(module) do
    case load_api(ctx, module, data) do
      {:ok, new_ctx} -> new_ctx
      {:error, reason} -> raise_error(reason)
    end
  end

  @doc """
  Triggers QuickJS garbage collection for a context.

  ## Returns

  - `:ok` on success.
  - `{:error, reason}` on failure, where `reason` is one of:
    - `:timeout`
    - `:oom`
    - `:context_poisoned`
    - `:not_owner`
    - `:sandbox_violation`
    - `:async_not_supported`
    - `:internal_error`
    - `{:js_error, message}`
    - `{:callback_error, callback_name, message}`
    - `{:invalid_api_module, message}`
    - any other passthrough error term

  ## Examples

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> :ok = QuickjsEx.gc(ctx)

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> {:error, :context_poisoned} = QuickjsEx.gc(QuickjsEx.Context.poison(ctx))
  """
  def gc(%Context{} = ctx) do
    if context_poisoned?(ctx) do
      {:error, :context_poisoned}
    else
      case NIF.nif_gc(ctx.ref) do
        :ok ->
          :ok

        {:error, raw_reason} ->
          reason = normalise_error(raw_reason)
          _ = track_poisoned_error(ctx, reason)
          {:error, reason}
      end
    end
  end

  @doc """
  Stores Elixir-side private data on the context.

  Private values are not visible from JavaScript code.

  ## Returns

  - Updated `ctx`.

  ## Examples

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> ctx = QuickjsEx.put_private(ctx, :request_id, "abc-123")
      iex> {:ok, "abc-123"} = QuickjsEx.get_private(ctx, :request_id)

      iex> QuickjsEx.put_private(%{}, :k, :v)
      ** (FunctionClauseError) no function clause matching in QuickjsEx.put_private/3
  """
  def put_private(%Context{} = ctx, key, value) do
    %{ctx | private: Map.put(ctx.private, key, value)}
  end

  @doc """
  Reads Elixir-side private data from the context.

  ## Returns

  - `{:ok, value}` when the key exists.
  - `:error` when the key is not present.

  ## Examples

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> ctx = QuickjsEx.put_private(ctx, :request_id, "abc-123")
      iex> {:ok, "abc-123"} = QuickjsEx.get_private(ctx, :request_id)

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> :error = QuickjsEx.get_private(ctx, :missing)
  """
  def get_private(%Context{private: private}, key) do
    case Map.fetch(private, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  @doc """
  Reads Elixir-side private data and raises if the key is missing.

  ## Returns

  - `value` when the key exists.

  ## Raises

  - `RuntimeError` when the key is missing.

  ## Examples

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> ctx = QuickjsEx.put_private(ctx, :request_id, "abc-123")
      iex> "abc-123" = QuickjsEx.get_private!(ctx, :request_id)

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> try do
      ...>   QuickjsEx.get_private!(ctx, :missing)
      ...> rescue
      ...>   e in RuntimeError -> e.message
      ...> end
      "private key `:missing` does not exist"
  """
  def get_private!(%Context{} = ctx, key) do
    case get_private(ctx, key) do
      {:ok, value} -> value
      :error -> raise "private key `#{inspect(key)}` does not exist"
    end
  end

  @doc """
  Removes Elixir-side private data from the context.

  ## Returns

  - Updated `ctx` with the key removed.

  ## Examples

      iex> {:ok, ctx} = QuickjsEx.new()
      iex> ctx = QuickjsEx.put_private(ctx, :request_id, "abc-123")
      iex> ctx = QuickjsEx.delete_private(ctx, :request_id)
      iex> :error = QuickjsEx.get_private(ctx, :request_id)

      iex> QuickjsEx.delete_private(%{}, :request_id)
      ** (FunctionClauseError) no function clause matching in QuickjsEx.delete_private/2
  """
  def delete_private(%Context{} = ctx, key) do
    %{ctx | private: Map.delete(ctx.private, key)}
  end

  defp build_callback_path(scope, name), do: scope ++ [to_string(name)]

  defp build_callback_fun(_module, name, true, _variadic) do
    fn _args ->
      raise QuickjsEx.RuntimeException,
            {:callback_error, to_string(name),
             "stateful defjs callbacks (with state parameter) are not supported in v0.1; " <>
               "use QuickjsEx.get_private/put_private for shared state instead"}
    end
  end

  defp build_callback_fun(module, name, false, false) do
    fn args ->
      apply(module, name, args)
    end
  end

  defp build_callback_fun(module, name, false, true) do
    fn args ->
      apply(module, name, [args])
    end
  end

  defp register_api_callbacks(ctx, module, scope, functions) do
    Enum.reduce_while(functions, {:ok, ctx}, fn {name, uses_state, variadic}, {:ok, acc_ctx} ->
      callback_path = build_callback_path(scope, name)
      callback_fun = build_callback_fun(module, name, uses_state, variadic)

      case register_callback_path(acc_ctx, callback_path, callback_fun) do
        {:ok, new_ctx} ->
          {:cont, {:ok, new_ctx}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp register_callback_path(%Context{} = ctx, [name], callback_fun) do
    set(ctx, name, callback_fun)
  end

  defp register_callback_path(%Context{} = ctx, path, callback_fun) when is_list(path) do
    callback_name = scoped_callback_name(path)
    public_name = Enum.join(path, ".")

    with {:ok, callback_ctx} <- set(ctx, callback_name, callback_fun) do
      mapped_ctx = remember_callback_alias(callback_ctx, callback_name, public_name)

      with {:ok, _} <- eval(mapped_ctx, scoped_callback_binding_js(path, callback_name)) do
        {:ok, mapped_ctx}
      end
    end
  end

  defp scoped_callback_name(path) do
    path_hash = :erlang.phash2(path)

    encoded =
      path
      |> Enum.join("__")
      |> String.replace(~r/[^a-zA-Z0-9_]/u, "_")

    "__quickjs_ex_cb__#{encoded}__#{path_hash}"
  end

  defp scoped_callback_binding_js(path, callback_name) do
    path_expr =
      path
      |> Enum.map(&js_string_literal/1)
      |> Enum.join(", ")

    """
    (function () {
      var g = (typeof globalThis !== "undefined") ? globalThis : this;
      var path = [#{path_expr}];
      var obj = g;

      for (var i = 0; i < path.length - 1; i++) {
        var key = path[i];
        var next = obj[key];

        if (next === null || typeof next !== "object") {
          next = {};
          obj[key] = next;
        }

        obj = next;
      }

      obj[path[path.length - 1]] = g[#{js_string_literal(callback_name)}];
    })();
    """
  end

  defp js_string_literal(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"#{escaped}\""
  end

  defp maybe_bootstrap_runtime(ref, memory_limit)
       when is_integer(memory_limit) and memory_limit >= @bootstrap_min_memory do
    _ = NIF.nif_eval(ref, @runtime_bootstrap, 0)
    :ok
  end

  defp maybe_bootstrap_runtime(_ref, _memory_limit), do: :ok

  defp remember_callback_alias(%Context{} = ctx, callback_name, public_name) do
    aliases =
      case get_private(ctx, @callback_aliases_key) do
        {:ok, existing} when is_map(existing) -> existing
        _ -> %{}
      end

    put_private(ctx, @callback_aliases_key, Map.put(aliases, callback_name, public_name))
  end

  defp remap_callback_alias({:callback_error, callback_name, message}, %Context{} = ctx) do
    case get_private(ctx, @callback_aliases_key) do
      {:ok, aliases} when is_map(aliases) ->
        {:callback_error, Map.get(aliases, callback_name, callback_name), message}

      _ ->
        {:callback_error, callback_name, message}
    end
  end

  defp remap_callback_alias(reason, _ctx), do: reason

  defp normalise_error(:timeout), do: :timeout
  defp normalise_error(:oom), do: :oom
  defp normalise_error(:poisoned), do: :context_poisoned
  defp normalise_error(:not_owner), do: :not_owner
  defp normalise_error(:sandbox), do: :sandbox_violation
  defp normalise_error(:async), do: :async_not_supported
  defp normalise_error(:internal), do: :internal_error
  defp normalise_error({:js, message}), do: {:js_error, message}
  defp normalise_error({:cb, name, message}), do: {:callback_error, name, message}
  defp normalise_error({:invalid_module, message}), do: {:invalid_api_module, message}
  defp normalise_error(other), do: other

  defp context_poisoned?(%Context{} = ctx) do
    Context.poisoned?(ctx) or poisoned_ref?(ctx.ref)
  end

  defp sync_poisoned_context(%Context{} = ctx) do
    if context_poisoned?(ctx), do: Context.poison(ctx), else: ctx
  end

  defp track_poisoned_error(%Context{} = ctx, reason) do
    if reason in [:oom, :context_poisoned], do: mark_poisoned_ref(ctx.ref)
  end

  defp mark_poisoned_ref(ref) do
    Process.put({@poisoned_ref_key, ref}, true)
  end

  defp clear_poisoned_ref(ref) do
    Process.delete({@poisoned_ref_key, ref})
  end

  defp poisoned_ref?(ref) do
    Process.get({@poisoned_ref_key, ref}, false)
  end

  defp raise_error(reason), do: raise(RuntimeException, reason)
end
