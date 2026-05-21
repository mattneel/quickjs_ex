# QuickjsEx

QuickjsEx embeds the QuickJS-NG engine in Elixir through Zig NIFs, without Node.js, and executes modern JavaScript (ES2023) inside a sandboxed runtime.

## What it is

QuickjsEx embeds the QuickJS-NG JavaScript engine directly inside the BEAM, targeting modern ES2023 without a Node.js dependency. It is implemented with Zig/Zigler NIFs and executes callbacks directly in the calling process.

## Execution model

Each context owns one dedicated OS thread for its `JSRuntime` and `JSContext`. Runtime-touching operations are enqueued to that thread and public Elixir APIs wait for a ref-tagged result message.

Callbacks, async host requests, and module loader requests from JavaScript are delivered to the same caller receive loop, so blocking host work does not occupy BEAM dirty scheduler threads. Evaluation timeout and gas accounting measure JavaScript execution time, not time parked on a host callback, async resolution, or module load.

Contexts are owned by the process that created them. Calls from other processes return `:not_owner`; attempts to re-enter the same context while it is already running return `:context_busy`; owner death stops the context thread and poisons retained handles.

## Installation

Add `quickjs_ex` to your dependencies in `mix.exs`:

```elixir
defp deps do
  [
    {:quickjs_ex, "~> 0.1.0"}
  ]
end
```

QuickjsEx requires Zig `0.15.2` on your `PATH`:

- <https://ziglang.org/download/>

## Quick Start

### 1) `new/1` + `eval/3`

```elixir
{:ok, ctx} = QuickjsEx.new(timeout: 100)
{:ok, 42} = QuickjsEx.eval(ctx, "40 + 2")
```

### 2) `get/2` + `set/3` with a scalar value

```elixir
{:ok, ctx} = QuickjsEx.new()
{:ok, ctx} = QuickjsEx.set(ctx, :answer, 42)
{:ok, 42} = QuickjsEx.get(ctx, :answer)
```

### 3) `set/3` with an Elixir function callback, then `eval/3`

```elixir
{:ok, ctx} = QuickjsEx.new()
{:ok, ctx} = QuickjsEx.set(ctx, :sum, fn [a, b] -> a + b end)
{:ok, 7} = QuickjsEx.eval(ctx, "sum(3, 4)")
```

### 4) `defjs` API module + `load_api/3` + `eval/3`

```elixir
defmodule MathAPI do
  use QuickjsEx.API

  defjs add(a, b), do: a + b
end

{:ok, ctx} = QuickjsEx.new()
{:ok, ctx} = QuickjsEx.load_api(ctx, MathAPI)
{:ok, 9} = QuickjsEx.eval(ctx, "add(4, 5)")
```

### 5) `set_async/3` with JavaScript `await`

```elixir
{:ok, ctx} = QuickjsEx.new()
{:ok, ctx} = QuickjsEx.set_async(ctx, :host_value, fn [value] -> value + 1 end)
{:ok, 42} = QuickjsEx.eval(ctx, "(async () => await host_value(41))()")
```

### 6) ES modules with an Elixir loader

```elixir
{:ok, ctx} = QuickjsEx.new()

{:ok, ctx} =
  QuickjsEx.set_module_loader(ctx, fn
    "settings" -> {:ok, "export let answer = 42;"}
    specifier -> {:error, "unknown module: #{specifier}"}
  end)

{:ok, nil} =
  QuickjsEx.eval(ctx, """
  import { answer } from "settings";
  globalThis.answer = answer;
  """, type: :module)

{:ok, 42} = QuickjsEx.get(ctx, :answer)
```

### 7) `put_private/3` + `get_private!/2` inside a callback

```elixir
{:ok, ctx} = QuickjsEx.new()
ctx = QuickjsEx.put_private(ctx, :prefix, "Hello")

{:ok, ctx} =
  QuickjsEx.set(ctx, :greet, fn [name] ->
    prefix = QuickjsEx.get_private!(ctx, :prefix)
    "#{prefix}, #{name}!"
  end)

{:ok, "Hello, Ada!"} = QuickjsEx.eval(ctx, "greet('Ada')")
```

### 8) `QuickjsEx.Server` for stateful JavaScript runtimes

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

  def handle_js_call("count", [], state), do: {:reply, state.count, state}
end

{:ok, server} = CounterRuntime.start_link([])
{:ok, 2} = QuickjsEx.Server.eval_sync(server, "increment(2)")
{:ok, 2} = QuickjsEx.Server.eval_sync(server, "count()")
```

`QuickjsEx.Server` owns one context in a GenServer, queues evals, and handles
JavaScript callback requests in the Server mailbox. Server callbacks are
promise-capable from JavaScript and can return `{:reply, value, state}` or defer
with `{:noreply, state}` plus `QuickjsEx.Server.resolve/2` or `reject/2`.

See [docs/server.md](docs/server.md) for deferred callbacks, `eval_async/3`,
module loaders, API state namespaces, and gas accounting.

## `new/1` options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `:memory_limit` | integer | `4_000_000` | Runtime heap limit in bytes. |
| `:stack_limit` | integer | `1_048_576` | QuickJS soft stack limit in bytes; the context thread requests an OS stack with headroom above this value. |
| `:timeout` | integer | `0` | Default evaluation timeout in milliseconds (`0` disables limit). |

## Error contract

Operations that return `{:error, reason}` normalize engine failures into typed categories:

- `:timeout` - evaluation exceeded the configured timeout.
- `:oom` - the JavaScript runtime ran out of memory; the context is non-recoverable.
- `:context_poisoned` - the context is already poisoned by a prior non-recoverable failure.
- `:not_owner` - the calling process does not own the context.
- `:context_busy` - the context is already running a command, including reentrant use from a callback.
- `:sandbox_violation` - sandbox policy blocked a restricted operation.
- `:unsettled_promise` - a promise could not settle because no jobs or external resolutions remained.
- `:module_load_error` - an import could not be resolved by the registered module loader.
- `:internal_error` - internal runtime/NIF failure; the context is non-recoverable.
- `{:js_error, message}` - JavaScript raised an exception.
- `{:callback_error, callback_name, message}` - an Elixir callback failed while invoked from JavaScript.
- `{:invalid_api_module, message}` - `load_api/3` received an invalid API module contract.

## Sandbox guarantees

Capability guarantees:

- The following names are denylisted and guaranteed unavailable:
  - `process`
  - `require`
  - `fs`
  - `Deno`
  - `Bun`
  - `__dirname`
  - `__filename`
  - `load`
  - `fetch`
  - `XMLHttpRequest`
  - `WebSocket`
  - `window`
  - `document`
  - `navigator`
  - `location`
  - `child_process`
  - `os`
  - `Buffer`
  - `setTimeout`
  - `print`
- Only values and callbacks explicitly injected through `QuickjsEx` are available.

Security validation:

- The project includes a dedicated security test suite (`test/security_test.exs`) that exercises sandbox restrictions.

## Context recovery rules

- Reusable: `:timeout`, `{:js_error, _}`, and `{:callback_error, _, _}`.
- Recreate required: `:oom` and `:internal_error`.
- If a call returns `:context_poisoned`, the context has already entered a non-recoverable state and must be recreated.

## Gas accounting

Use `QuickjsEx.gas/1` to read coarse runtime cost for the current context:

```elixir
{:ok, ctx} = QuickjsEx.new()
{:ok, _result} = QuickjsEx.eval(ctx, "1 + 1")
{:ok, %{last: 1, total: 1, quantum: 10_000}} = QuickjsEx.gas(ctx)
```

Gas is reported in interrupt quanta, not exact VM instructions. One quantum currently
represents `10_000` internal QuickJS interrupt-counted instructions, which makes it
useful as a deterministic billing or budgeting baseline even before deeper pricing sweeps.

## Platform support

| Platform | Support |
| --- | --- |
| Linux x86_64 | First-class |
| Linux arm64 | First-class |
| macOS | Best effort |
| Windows | Out of scope |

## Vendored QuickJS updates

QuickJS-NG and the Zig bindings are vendored as checked-in snapshots, not git
submodules. Validate the snapshot with:

```sh
mix quickjs.vendor.check
```

See [docs/vendor_quickjs.md](docs/vendor_quickjs.md) for the update workflow.

## Migration from mquickjs_ex

For migration steps and intentional breaking changes, see [MIGRATION.md](MIGRATION.md).
