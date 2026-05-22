# QuickjsEx.Server

`QuickjsEx.Server` is a GenServer wrapper around one owned `QuickjsEx` context.
Use it when JavaScript execution needs durable Elixir state, queued evaluation,
and promise-returning host callbacks without blocking the Server mailbox.

The lower-level `QuickjsEx` context API is still available for direct embedding.
The Server layer is pure Elixir on top of that runtime.

## Execution model

The Server process creates the context, so it is the context owner. It starts
runtime commands with the async NIF dispatch path, returns from `handle_call/3`
or `handle_cast/2`, and processes these runtime messages in its mailbox:

- `{:quickjs_ex_result, request_ref, result}`
- `{:quickjs_ex_async_request, request_ref, req_id, name, args}`
- `{:quickjs_ex_module_request, request_ref, req_id, specifier}`

This means the Server loop stays available while JavaScript is parked on a host
callback. Resolutions, rejections, module loads, gas reads, and queued evals all
move through the same serialized Server state. Queued sync calls are monitored
and dropped if their caller process dies before they start. If the active eval is
parked on deferred Server callbacks and its sync caller exits, those pending
callbacks are rejected; CPU-bound active evals continue until their effective
JavaScript timeout.

## Defining a server

```elixir
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
```

The `:callbacks` option registers global JavaScript functions. Server callbacks
are always promise-capable at the JavaScript level, so JavaScript authors can
`await` them uniformly. Returning `{:reply, value, state}` resolves immediately.

## Deferred callbacks

Use `{:noreply, state}` when callback work completes later. Capture
`QuickjsEx.Server.current_ref/0` during `handle_js_call/3` and resolve or reject
from the asynchronous worker.

```elixir
def handle_js_call("load_user", [id], state) do
  ref = QuickjsEx.Server.current_ref()

  Task.start(fn ->
    case MyApp.Users.fetch(id) do
      {:ok, user} -> QuickjsEx.Server.resolve(ref, user)
      {:error, reason} -> QuickjsEx.Server.reject(ref, reason)
    end
  end)

  {:noreply, state}
end
```

If deferred work changes state, pass a transition function to `resolve/3` or
`reject/3`. The transition runs in the Server process against the live state at
completion time.

```elixir
def handle_js_call("add_later", [amount], state) do
  ref = QuickjsEx.Server.current_ref()

  Task.start(fn ->
    QuickjsEx.Server.resolve(ref, amount, fn live_state ->
      Map.update!(live_state, :total, &(&1 + amount))
    end)
  end)

  {:noreply, state}
end
```

This avoids lost updates when multiple deferred callbacks complete out of order.

## Evaluating JavaScript

`eval_sync/3` uses `GenServer.call/3` and replies after the root value or promise
settles:

```elixir
{:ok, value} = QuickjsEx.Server.eval_sync(server, "awaitable()")
```

Useful options:

- `:timeout` - JavaScript execution timeout in milliseconds; omitted evals use
  the context default configured when the Server starts. The Server default is
  `5_000`; pass `timeout: 0` only when unbounded JS execution is intentional.
- `:call_timeout` - caller wait timeout for `GenServer.call/3`. For sync evals
  without an explicit `:timeout`, finite call timeouts also cap the JS timeout so
  CPU-bound work is interrupted before the caller exits.
- `:type` - `:script` or `:module`.
- `:on_busy` - `:queue` (default) or `:error`.

`eval_async/3` returns a ref immediately and sends the result to the requester:

```elixir
{:ok, ref} = QuickjsEx.Server.eval_async(server, "40 + 2")

receive do
  {:quickjs_ex_server_result, ^ref, {:ok, 42}} -> :ok
  {:quickjs_ex_server_result, ^ref, {:error, reason}} -> {:error, reason}
end
```

Eval commands are serialized. `eval_sync/3` and `eval_async/3` queue behind the
active eval by default. Pass `on_busy: :error` to receive
`{:error, :context_busy}` instead. The Server also has a bounded queue,
configured by `:max_queue_size` at startup and defaulting to 64; excess work
returns `{:error, :context_busy}`.

```elixir
{:ok, ref} = QuickjsEx.Server.eval_async(server, "work()", on_busy: :error)
```

Sync callers are monitored. Queued work from dead callers is dropped. If the
active eval is waiting on deferred Server callbacks and the original sync caller
exits, pending callback refs are rejected with `"eval caller unavailable"` so the
Server can start the next eval. CPU-bound active evals are bounded by the
effective eval timeout unless you explicitly pass `timeout: 0`.

## Module loader

Pass `:module_loader` when starting the Server to support static and dynamic
imports:

```elixir
{:ok, server} =
  MyRuntime.start_link(
    module_loader: fn
      "settings" -> {:ok, "export let answer = 42;"}
      specifier -> {:error, "unknown module: #{specifier}"}
    end
  )

{:ok, 42} =
  QuickjsEx.Server.eval_sync(server, """
  (async () => {
    const module = await import("settings");
    return module.answer;
  })()
  """)
```

Loader failures normalize to `{:error, :module_load_error}`. The loader receives
JavaScript-controlled specifiers, so deny by default and only serve known module
names or normalized allowlisted paths. Avoid raw `File.read/1`, HTTP fetching,
or package resolution from untrusted specifiers.

## Stateful API modules

Server APIs reuse `QuickjsEx.API` metadata for JavaScript names and scopes, but
the implementation is `handle_js_call/3` over a per-API state slice.

```elixir
defmodule CartAPI do
  use QuickjsEx.API, scope: "cart"

  defjs(add_item(item), do: :server_callback)
  defjs(count(), do: :server_callback)

  def handle_js_call("add_item", [item], state) do
    {:reply, :ok, %{state | items: [item | state.items]}}
  end

  def handle_js_call("count", [], state) do
    {:reply, length(state.items), state}
  end
end

defmodule Runtime do
  use QuickjsEx.Server, apis: [{CartAPI, %{items: []}}]
end

{:ok, server} = Runtime.start_link([])
{:ok, 1} =
  QuickjsEx.Server.eval_sync(server, """
  (async () => {
    await cart.add_item("sku-1");
    return await cart.count();
  })()
  """)
```

You can also add an API after startup with `QuickjsEx.Server.load_api/3` when no
eval is active. Each API module has its own state entry, isolated from the root
Server state and from other API modules.

## Gas and errors

`QuickjsEx.Server.gas/1` returns the owned runtime's gas accounting through the
same serialized command queue:

```elixir
{:ok, %{last: last, total: total, quantum: 10_000}} = QuickjsEx.Server.gas(server)
```

Server evals use the same normalized error contract as `QuickjsEx.eval/3`,
including:

- `:timeout`
- `:oom`
- `:context_poisoned`
- `:context_busy`
- `:sandbox_violation`
- `:unsettled_promise`
- `:module_load_error`
- `:internal_error`
- `{:js_error, message}`
- `{:callback_error, callback_name, message}`

Because `eval_sync/3` is a `GenServer.call/3`, callers also get normal GenServer
monitor behavior if the Server exits mid-eval instead of waiting forever.
