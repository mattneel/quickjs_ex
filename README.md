# QuickjsEx

QuickjsEx embeds the QuickJS-NG engine in Elixir through Zig NIFs, without Node.js, and executes modern JavaScript (ES2023) inside a sandboxed runtime.

## What it is

QuickjsEx embeds the QuickJS-NG JavaScript engine directly inside the BEAM, targeting modern ES2023 without a Node.js dependency. It is implemented with Zig/Zigler NIFs and executes callbacks directly (no trampoline replay layer).

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

### 5) `put_private/3` + `get_private!/2` inside a callback

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

## `new/1` options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `:memory_limit` | integer | `4_000_000` | Runtime heap limit in bytes. |
| `:stack_limit` | integer | `0` | Native stack limit in bytes (`0` disables limit). |
| `:timeout` | integer | `0` | Default evaluation timeout in milliseconds (`0` disables limit). |

## Error contract

Operations that return `{:error, reason}` normalize engine failures into typed categories:

- `:timeout` - evaluation exceeded the configured timeout.
- `:oom` - the JavaScript runtime ran out of memory; the context is non-recoverable.
- `:context_poisoned` - the context is already poisoned by a prior non-recoverable failure.
- `:not_owner` - the calling process does not own the context.
- `:sandbox_violation` - sandbox policy blocked a restricted operation.
- `:async_not_supported` - Promise/async evaluation is intentionally unsupported.
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

## Migration from mquickjs_ex

For migration steps and intentional breaking changes, see [MIGRATION.md](MIGRATION.md).
