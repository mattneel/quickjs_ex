defmodule QuickjsEx.Server do
  @moduledoc """
  GenServer wrapper around one owned `QuickjsEx` context.

  `QuickjsEx.Server` is the stateful layer over the lower-level context API. The
  GenServer process creates and owns the context, so runtime messages from
  JavaScript are handled by normal `handle_info/2` callbacks instead of by a
  blocking receive loop in the caller.

  JavaScript-visible callbacks registered through the Server are always async at
  the JavaScript level. JS code should `await` them uniformly:

      defmodule CounterRuntime do
        use QuickjsEx.Server, callbacks: [:increment, :count]

        @impl QuickjsEx.Server
        def init(_opts), do: {:ok, %{count: 0}}

        @impl QuickjsEx.Server
        def handle_js_call("increment", [by], state) do
          next = state.count + by
          {:reply, next, %{state | count: next}}
        end

        def handle_js_call("count", [], state) do
          {:reply, state.count, state}
        end
      end

      {:ok, server} = CounterRuntime.start_link([])
      {:ok, 3} = QuickjsEx.Server.eval_sync(server, "increment(3)")
      {:ok, 3} = QuickjsEx.Server.eval_sync(server, "count()")

  A callback can defer completion by returning `{:noreply, new_state}` and later
  calling `resolve/2`, `resolve/3`, `reject/2`, or `reject/3` with the callback
  ref captured by `current_ref/0`. When deferred work mutates state, prefer
  `resolve(ref, value, transition_fun)` so the transition is applied against the
  live state at completion time, not against a stale snapshot captured by a Task.

  Runtime execution is serialized explicitly. `eval_sync/3` calls are queued.
  `eval_async/3` queues by default and can return `:context_busy` to the requester
  with `on_busy: :error`.
  """

  use GenServer

  alias QuickjsEx.Context
  alias QuickjsEx.NIF

  @current_ref_key {__MODULE__, :current_ref}
  @result_message :quickjs_ex_server_result

  @callback init(term()) :: {:ok, term()} | {:ok, term(), keyword()}
  @callback handle_js_call(String.t(), list(), term()) ::
              {:reply, term(), term()}
              | {:noreply, term()}
              | {:reject, term(), term()}

  @type server :: GenServer.server()
  @type callback_ref :: %__MODULE__.CallbackRef{}
  @type eval_result :: {:ok, term()} | {:error, term()}
  @type eval_opts :: [
          timeout: non_neg_integer(),
          call_timeout: timeout(),
          type: :script | :module,
          on_busy: :queue | :error
        ]

  defmodule CallbackRef do
    @moduledoc false
    @enforce_keys [:server, :token, :eval_ref, :req_id]
    defstruct [:server, :token, :eval_ref, :req_id]
  end

  defmodule State do
    @moduledoc false
    defstruct [
      :ctx,
      :callback_module,
      :root_state,
      :module_loader,
      registry: %{},
      api_states: %{},
      active: nil,
      queue: :queue.new(),
      pending_callbacks: %{}
    ]
  end

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour QuickjsEx.Server

      def start_link(init_arg \\ [], genserver_opts \\ []) do
        QuickjsEx.Server.start_link(__MODULE__, init_arg, genserver_opts)
      end

      def child_spec(init_arg) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_arg]},
          restart: :temporary,
          type: :worker
        }
      end

      @impl QuickjsEx.Server
      def init(init_arg), do: {:ok, init_arg}

      @doc false
      def __quickjs_ex_server_options__, do: unquote(Macro.escape(opts))

      defoverridable start_link: 1, start_link: 2, child_spec: 1, init: 1
    end
  end

  @doc """
  Starts a `QuickjsEx.Server` process for a callback module.

  Most users call the generated `start_link/1` from a module that uses
  `QuickjsEx.Server`. This lower-level function is useful when the callback module
  is selected dynamically.

  `init_arg` is passed to the callback module's `init/1`. Keyword values for
  `:memory_limit`, `:stack_limit`, `:timeout`, `:callbacks`, `:apis`, and
  `:module_loader` are used as Server configuration.
  """
  @spec start_link(module(), term(), GenServer.options()) :: GenServer.on_start()
  def start_link(callback_module, init_arg \\ [], genserver_opts \\ [])
      when is_atom(callback_module) and is_list(genserver_opts) do
    GenServer.start_link(__MODULE__, {callback_module, init_arg}, genserver_opts)
  end

  @doc """
  Evaluates JavaScript and waits for the settled result.

  This uses `GenServer.call/3`, but the Server replies later with
  `GenServer.reply/2` after the QuickJS root value or promise settles. While the
  evaluation is parked on a Server callback or module load, the Server mailbox
  remains available to process resolutions and queued work.

  Options:

  - `:timeout` - JavaScript execution timeout in milliseconds.
  - `:call_timeout` - `GenServer.call/3` timeout; defaults to `5_000`.
  - `:type` - `:script` or `:module`, matching `QuickjsEx.eval/3`.

  Returns the same normalized result shape as `QuickjsEx.eval/3`.
  """
  @spec eval_sync(server(), String.t(), eval_opts() | timeout()) :: eval_result()
  def eval_sync(server, source, opts \\ [])

  def eval_sync(server, source, timeout)
      when is_binary(source) and (is_integer(timeout) or timeout == :infinity) do
    GenServer.call(server, {:eval_sync, source, []}, timeout)
  end

  def eval_sync(server, source, opts) when is_binary(source) and is_list(opts) do
    call_timeout = Keyword.get(opts, :call_timeout, 5_000)
    GenServer.call(server, {:eval_sync, source, opts}, call_timeout)
  end

  @doc """
  Queues JavaScript evaluation and sends the result to the caller.

  Returns `{:ok, ref}` immediately. The caller receives:

      {:quickjs_ex_server_result, ref, {:ok, value}}
      {:quickjs_ex_server_result, ref, {:error, reason}}

  Async eval queues behind the active evaluation by default. Pass
  `on_busy: :error` to receive `{:error, :context_busy}` instead of queueing.
  """
  @spec eval_async(server(), String.t(), eval_opts()) :: {:ok, reference()}
  def eval_async(server, source, opts \\ []) when is_binary(source) and is_list(opts) do
    ref = make_ref()
    GenServer.cast(server, {:eval_async, self(), ref, source, opts})
    {:ok, ref}
  end

  @doc """
  Returns coarse gas accounting for the owned runtime.

  The gas command is serialized through the same queue as eval, so it observes
  runtime accounting without racing the active JavaScript command.
  """
  @spec gas(server(), timeout()) ::
          {:ok, %{last: integer(), total: integer(), quantum: integer()}} | {:error, term()}
  def gas(server, timeout \\ 5_000) do
    GenServer.call(server, :gas, timeout)
  end

  @doc """
  Loads a stateful API module into the server.

  The module must use `QuickjsEx.API` for function metadata and implement
  `handle_js_call/3` for Server-side state transitions. Each loaded API owns an
  isolated state slice, so different APIs cannot overwrite the Server root state
  or each other's state.

  This call is rejected with `{:error, :context_busy}` while an eval is active.
  """
  @spec load_api(server(), module(), term()) :: :ok | {:error, term()}
  def load_api(server, module, api_state \\ %{}) when is_atom(module) do
    GenServer.call(server, {:load_api, module, api_state})
  end

  @doc """
  Returns the callback reference for the currently running `handle_js_call/3`.

  Use this only when returning `{:noreply, state}` from `handle_js_call/3`; pass
  the returned ref to `resolve/2`, `resolve/3`, `reject/2`, or `reject/3` from
  the asynchronous work that completes the callback.
  """
  @spec current_ref() :: callback_ref()
  def current_ref do
    Process.get(@current_ref_key) ||
      raise ArgumentError,
            "QuickjsEx.Server.current_ref/0 is only available inside handle_js_call/3"
  end

  @doc """
  Resolves a deferred JavaScript callback.

  `resolve(ref, value)` fulfills the JavaScript promise with `value`.
  `resolve(ref, value, transition_fun)` also updates the callback's user-state
  slice by applying `transition_fun` against the live state in the Server process.
  """
  @spec resolve(callback_ref(), term(), (term() -> term()) | nil) :: :ok
  def resolve(%CallbackRef{} = ref, value, transition \\ nil)
      when is_nil(transition) or is_function(transition, 1) do
    GenServer.cast(ref.server, {:resolve_callback, ref, {:ok, value}, transition})
  end

  @doc """
  Rejects a deferred JavaScript callback.

  Rejects the JavaScript promise. The eventual eval result is normalized as
  `{:error, {:js_error, message}}` unless JavaScript catches the rejection.
  The optional transition function follows the same live-state rule as
  `resolve/3`.
  """
  @spec reject(callback_ref(), term(), (term() -> term()) | nil) :: :ok
  def reject(%CallbackRef{} = ref, reason, transition \\ nil)
      when is_nil(transition) or is_function(transition, 1) do
    GenServer.cast(
      ref.server,
      {:resolve_callback, ref, {:error, error_message(reason)}, transition}
    )
  end

  @impl GenServer
  def init({callback_module, init_arg}) do
    with {:ok, root_state, server_opts} <- init_callback_module(callback_module, init_arg),
         opts <- merged_server_options(callback_module, init_arg, server_opts),
         {:ok, ctx} <- QuickjsEx.new(context_options(init_arg, opts)),
         {:ok, ctx, registry, api_states} <- install_callbacks(ctx, callback_module, opts) do
      state = %State{
        ctx: ctx,
        callback_module: callback_module,
        root_state: root_state,
        module_loader: Keyword.get(opts, :module_loader),
        registry: registry,
        api_states: api_states
      }

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:eval_sync, source, opts}, from, state) do
    request = %{kind: :sync, from: from, source: source, opts: opts}
    {:noreply, enqueue_eval(request, state)}
  end

  def handle_call(:gas, from, state) do
    request = %{kind: :sync, op: :gas, from: from}
    {:noreply, enqueue_eval(request, state)}
  end

  def handle_call({:load_api, module, api_state}, _from, %State{active: nil} = state) do
    case install_api(state.ctx, state.registry, state.api_states, module, api_state) do
      {:ok, ctx, registry, api_states} ->
        {:reply, :ok, %{state | ctx: ctx, registry: registry, api_states: api_states}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:load_api, _module, _api_state}, _from, state) do
    {:reply, {:error, :context_busy}, state}
  end

  @impl GenServer
  def handle_cast({:eval_async, requester, result_ref, source, opts}, state) do
    request = %{
      kind: :async,
      requester: requester,
      result_ref: result_ref,
      source: source,
      opts: opts
    }

    busy? = state.active != nil or not :queue.is_empty(state.queue)

    cond do
      busy? and Keyword.get(opts, :on_busy) == :error ->
        send(requester, {@result_message, result_ref, {:error, :context_busy}})
        {:noreply, state}

      true ->
        {:noreply, enqueue_eval(request, state)}
    end
  end

  def handle_cast({:resolve_callback, %CallbackRef{} = ref, result, transition}, state) do
    {pending, pending_callbacks} = Map.pop(state.pending_callbacks, ref.token)
    state = %{state | pending_callbacks: pending_callbacks}

    if pending do
      {state, result} = apply_deferred_transition(state, pending.target, result, transition)
      _ = NIF.nif_resolve_async(state.ctx.ref, ref.eval_ref, ref.req_id, result)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(
        {:quickjs_ex_result, request_ref, result},
        %State{active: %{request_ref: request_ref}} = state
      ) do
    result = normalize_result(result)
    deliver_eval_result(state.active, result)

    state =
      state
      |> clear_active_eval()
      |> maybe_start_next()

    {:noreply, state}
  end

  def handle_info({:quickjs_ex_async_request, request_ref, req_id, callback_name, args}, state) do
    {:noreply, handle_async_request(state, request_ref, req_id, to_string(callback_name), args)}
  end

  def handle_info({:quickjs_ex_callback, request_ref, req_id, callback_name, _args}, state) do
    _ =
      NIF.nif_signal_callback_result(
        state.ctx.ref,
        request_ref,
        req_id,
        {:error, {:cb, to_string(callback_name), "QuickjsEx.Server callbacks must be async"}}
      )

    {:noreply, state}
  end

  def handle_info({:quickjs_ex_module_request, request_ref, req_id, specifier}, state) do
    result = run_module_loader(state.module_loader, specifier)
    _ = NIF.nif_signal_module_result(state.ctx.ref, request_ref, req_id, result)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp init_callback_module(callback_module, init_arg) do
    case callback_module.init(init_arg) do
      {:ok, root_state} -> {:ok, root_state, []}
      {:ok, root_state, opts} when is_list(opts) -> {:ok, root_state, opts}
      other -> {:error, {:invalid_server_init, other}}
    end
  end

  defp module_options(callback_module) do
    if function_exported?(callback_module, :__quickjs_ex_server_options__, 0) do
      callback_module.__quickjs_ex_server_options__()
    else
      []
    end
  end

  defp merged_server_options(callback_module, init_arg, server_opts) do
    init_opts = if is_list(init_arg), do: init_arg, else: []

    callback_module
    |> module_options()
    |> Keyword.merge(init_opts)
    |> Keyword.merge(server_opts)
  end

  defp context_options(init_arg, opts) do
    init_opts = if is_list(init_arg), do: init_arg, else: []

    [:memory_limit, :stack_limit, :timeout]
    |> Enum.reduce([], fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, value} -> Keyword.put(acc, key, value)
        :error -> acc
      end
    end)
    |> Keyword.merge(Keyword.take(init_opts, [:memory_limit, :stack_limit, :timeout]))
  end

  defp install_callbacks(ctx, callback_module, opts) do
    callbacks = Keyword.get(opts, :callbacks, [])
    apis = Keyword.get(opts, :apis, [])

    with {:ok, ctx, registry} <- install_root_callbacks(ctx, callback_module, callbacks),
         {:ok, ctx, registry, api_states} <- install_apis(ctx, registry, %{}, apis) do
      {:ok, ctx, registry, api_states}
    end
  end

  defp install_root_callbacks(ctx, callback_module, callbacks) do
    Enum.reduce_while(callbacks, {:ok, ctx, %{}}, fn callback, {:ok, ctx, registry} ->
      name = to_string(callback)
      target = %{kind: :root, module: callback_module, public_name: name}

      case register_callback_path(ctx, [name], target, registry) do
        {:ok, ctx, registry} -> {:cont, {:ok, ctx, registry}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp install_apis(ctx, registry, api_states, apis) do
    Enum.reduce_while(apis, {:ok, ctx, registry, api_states}, fn api_spec,
                                                                 {:ok, ctx, registry, api_states} ->
      {module, api_state} = normalize_api_spec(api_spec)

      case install_api(ctx, registry, api_states, module, api_state) do
        {:ok, ctx, registry, api_states} -> {:cont, {:ok, ctx, registry, api_states}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_api_spec({module, api_state}) when is_atom(module), do: {module, api_state}
  defp normalize_api_spec(module) when is_atom(module), do: {module, %{}}

  defp install_api(ctx, registry, api_states, module, api_state) do
    with {:ok, scope, functions} <- fetch_api_metadata(module) do
      Enum.reduce_while(functions, {:ok, ctx, registry}, fn {name, _uses_state, _variadic},
                                                            {:ok, ctx, registry} ->
        public_name = to_string(name)
        path = scope ++ [public_name]
        target = %{kind: :api, module: module, public_name: public_name}

        case register_callback_path(ctx, path, target, registry) do
          {:ok, ctx, registry} -> {:cont, {:ok, ctx, registry}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, ctx, registry} ->
          {:ok, ctx, registry, Map.put(api_states, module, api_state)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_api_metadata(module) do
    {:ok, module.scope(), module.__js_functions__()}
  rescue
    exception -> {:error, {:invalid_api_module, Exception.message(exception)}}
  end

  defp register_callback_path(ctx, [name], target, registry) do
    with {:ok, ctx} <-
           QuickjsEx.set_async(ctx, name, fn _args -> {:error, "server callback not handled"} end) do
      {:ok, ctx, Map.put(registry, name, target)}
    end
  end

  defp register_callback_path(ctx, path, target, registry) when is_list(path) do
    callback_name = scoped_callback_name(path)

    with {:ok, ctx} <-
           QuickjsEx.set_async(ctx, callback_name, fn _args ->
             {:error, "server callback not handled"}
           end),
         {:ok, _} <- QuickjsEx.eval(ctx, scoped_callback_binding_js(path, callback_name)) do
      {:ok, ctx, Map.put(registry, callback_name, target)}
    end
  end

  defp enqueue_eval(request, %State{active: nil} = state) do
    start_eval(request, state)
  end

  defp enqueue_eval(request, state) do
    %{state | queue: :queue.in(request, state.queue)}
  end

  defp maybe_start_next(%State{active: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, request}, queue} -> start_eval(request, %{state | queue: queue})
      {:empty, _queue} -> state
    end
  end

  defp maybe_start_next(state), do: state

  defp start_eval(request, state) do
    request_ref = make_ref()

    case dispatch_request(request, state.ctx, request_ref) do
      :ok ->
        %{state | active: Map.put(request, :request_ref, request_ref)}

      {:ok, _result} = ok ->
        deliver_eval_result(request, ok)
        maybe_start_next(state)

      {:error, raw_reason} ->
        deliver_eval_result(request, {:error, normalize_error(raw_reason)})
        maybe_start_next(state)
    end
  end

  defp dispatch_request(%{op: :gas}, %Context{} = ctx, request_ref) do
    NIF.nif_get_gas(ctx.ref, request_ref)
  end

  defp dispatch_request(request, %Context{} = ctx, request_ref) do
    timeout = Keyword.get(request.opts, :timeout, 0)
    eval_as_module? = Keyword.get(request.opts, :type, :script) == :module

    NIF.nif_eval(ctx.ref, request_ref, request.source, timeout, eval_as_module?)
  end

  defp clear_active_eval(state) do
    active_ref = state.active.request_ref

    pending_callbacks =
      Map.reject(state.pending_callbacks, fn {_token, pending} ->
        pending.eval_ref == active_ref
      end)

    %{state | active: nil, pending_callbacks: pending_callbacks}
  end

  defp deliver_eval_result(%{kind: :sync, from: from}, result), do: GenServer.reply(from, result)

  defp deliver_eval_result(%{kind: :async, requester: requester, result_ref: ref}, result) do
    send(requester, {@result_message, ref, result})
  end

  defp handle_async_request(
         %State{active: %{request_ref: request_ref}} = state,
         request_ref,
         req_id,
         callback_name,
         args
       ) do
    case Map.fetch(state.registry, callback_name) do
      {:ok, target} ->
        invoke_js_callback(state, request_ref, req_id, callback_name, args, target)

      :error ->
        _ =
          NIF.nif_resolve_async(
            state.ctx.ref,
            request_ref,
            req_id,
            {:error, "server callback `#{callback_name}` is not registered"}
          )

        state
    end
  end

  defp handle_async_request(state, request_ref, req_id, callback_name, _args) do
    _ =
      NIF.nif_resolve_async(
        state.ctx.ref,
        request_ref,
        req_id,
        {:error, "stale server callback `#{callback_name}`"}
      )

    state
  end

  defp invoke_js_callback(state, request_ref, req_id, callback_name, args, target) do
    ref = %CallbackRef{server: self(), token: make_ref(), eval_ref: request_ref, req_id: req_id}
    old_ref = Process.get(@current_ref_key)
    Process.put(@current_ref_key, ref)

    result =
      try do
        target.module.handle_js_call(target.public_name, args, get_user_state(state, target))
      rescue
        exception -> {:raised, Exception.message(exception)}
      catch
        kind, reason -> {:raised, Exception.format_banner(kind, reason)}
      after
        restore_current_ref(old_ref)
      end

    handle_callback_return(state, request_ref, req_id, callback_name, ref, target, result)
  end

  defp restore_current_ref(nil), do: Process.delete(@current_ref_key)
  defp restore_current_ref(old_ref), do: Process.put(@current_ref_key, old_ref)

  defp handle_callback_return(
         state,
         request_ref,
         req_id,
         _callback_name,
         _ref,
         target,
         {:reply, value, next_user_state}
       ) do
    state = put_user_state(state, target, next_user_state)
    _ = NIF.nif_resolve_async(state.ctx.ref, request_ref, req_id, {:ok, value})
    state
  end

  defp handle_callback_return(
         state,
         request_ref,
         req_id,
         _callback_name,
         _ref,
         target,
         {:reject, reason, next_user_state}
       ) do
    state = put_user_state(state, target, next_user_state)
    _ = NIF.nif_resolve_async(state.ctx.ref, request_ref, req_id, {:error, error_message(reason)})
    state
  end

  defp handle_callback_return(
         state,
         request_ref,
         _req_id,
         callback_name,
         ref,
         target,
         {:noreply, next_user_state}
       ) do
    state = put_user_state(state, target, next_user_state)

    pending = %{
      eval_ref: request_ref,
      callback_name: callback_name,
      target: target
    }

    %{state | pending_callbacks: Map.put(state.pending_callbacks, ref.token, pending)}
  end

  defp handle_callback_return(
         state,
         request_ref,
         req_id,
         callback_name,
         _ref,
         _target,
         {:raised, message}
       ) do
    _ =
      NIF.nif_resolve_async(
        state.ctx.ref,
        request_ref,
        req_id,
        {:error, "#{callback_name} failed: #{message}"}
      )

    state
  end

  defp handle_callback_return(state, request_ref, req_id, callback_name, _ref, _target, other) do
    _ =
      NIF.nif_resolve_async(
        state.ctx.ref,
        request_ref,
        req_id,
        {:error, "invalid return from #{callback_name}: #{inspect(other)}"}
      )

    state
  end

  defp apply_deferred_transition(state, _target, result, nil), do: {state, result}

  defp apply_deferred_transition(state, target, result, transition) do
    next_user_state = transition.(get_user_state(state, target))
    {put_user_state(state, target, next_user_state), result}
  rescue
    exception -> {state, {:error, Exception.message(exception)}}
  catch
    kind, reason -> {state, {:error, Exception.format_banner(kind, reason)}}
  end

  defp get_user_state(%State{} = state, %{kind: :root}), do: state.root_state

  defp get_user_state(%State{} = state, %{kind: :api, module: module}) do
    Map.fetch!(state.api_states, module)
  end

  defp put_user_state(%State{} = state, %{kind: :root}, next_user_state) do
    %{state | root_state: next_user_state}
  end

  defp put_user_state(%State{} = state, %{kind: :api, module: module}, next_user_state) do
    %{state | api_states: Map.put(state.api_states, module, next_user_state)}
  end

  defp run_module_loader(nil, specifier),
    do: {:error, "module loader is not registered for `#{specifier}`"}

  defp run_module_loader(loader, specifier) do
    case loader.(to_string(specifier)) do
      {:ok, source} when is_binary(source) -> {:ok, source}
      {:ok, _source} -> {:error, "module loader source must be a string"}
      {:error, reason} -> {:error, error_message(reason)}
      other -> {:error, "invalid module loader response: #{inspect(other)}"}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  defp normalize_result({:ok, _value} = ok), do: ok
  defp normalize_result({:error, reason}), do: {:error, normalize_error(reason)}

  defp normalize_error(:timeout), do: :timeout
  defp normalize_error(:oom), do: :oom
  defp normalize_error(:poisoned), do: :context_poisoned
  defp normalize_error(:not_owner), do: :not_owner
  defp normalize_error(:context_busy), do: :context_busy
  defp normalize_error(:sandbox), do: :sandbox_violation
  defp normalize_error(:async), do: :unsettled_promise
  defp normalize_error(:unsettled), do: :unsettled_promise
  defp normalize_error(:module_load), do: :module_load_error
  defp normalize_error(:internal), do: :internal_error
  defp normalize_error({:js, message}), do: {:js_error, message}
  defp normalize_error({:cb, name, message}), do: {:callback_error, name, message}
  defp normalize_error({:invalid_module, message}), do: {:invalid_api_module, message}
  defp normalize_error(other), do: other

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)

  defp scoped_callback_name(path) do
    path_hash = :erlang.phash2(path)

    encoded =
      path
      |> Enum.join("__")
      |> String.replace(~r/[^a-zA-Z0-9_]/u, "_")

    "__quickjs_ex_server_cb__#{encoded}__#{path_hash}"
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
end
