# Migrating from mquickjs_ex to quickjs_ex

## Overview

`quickjs_ex` keeps the overall API shape familiar, but this migration includes intentional breaking behavior for callback execution, ownership isolation, and runtime defaults. Treat this as a contract migration, not a patch-level swap.

## Breaking changes

| Area | `mquickjs_ex` | `quickjs_ex` |
| --- | --- | --- |
| Module prefix | `MquickjsEx` | `QuickjsEx` |
| Memory option | `memory:` (default `65_536` bytes / 64KB) | `memory_limit:` (default `4_000_000` bytes / 4MB) |
| 64KB compatibility | Implicit via old default | Set `memory_limit: 65536` explicitly |
| Callback execution | Trampoline/replay semantics | Direct linear callback execution (no replay trampoline) |
| Context ownership | Implicit/shared assumptions were common | Owner-bound contexts; non-owner calls return `{:error, :not_owner}` |
| JavaScript dialect | Older QuickJS baseline | QuickJS-NG with ES2023 support |

## Step-by-step migration

1. Replace the dependency in `mix.exs`.

```elixir
defp deps do
  [
    {:quickjs_ex, "~> 0.1.0"}
  ]
end
```

2. Install Zig `0.15.2` and ensure it is on your `PATH`.

- <https://ziglang.org/download/>

3. Rename all module references globally:

```elixir
MquickjsEx   # old
QuickjsEx    # new
```

4. Rename context memory option usage and pin legacy memory limits where needed:

```elixir
# old
MquickjsEx.new(memory: 65_536)

# new
QuickjsEx.new(memory_limit: 4_000_000)
```

To preserve old 64KB behavior for compatibility-sensitive flows, set:

```elixir
QuickjsEx.new(memory_limit: 65536)
```

5. Audit callback code for replay-vs-linear behavior changes.

- Remove assumptions that callback work is replayed by a trampoline.
- Expect direct linear execution and make side effects correct under that model.

6. Audit cross-process context ownership boundaries.

- Non-owner calls now fail with `{:error, :not_owner}`.
- Use explicit ownership handoff where required via `QuickjsEx.NIF.nif_transfer_owner/2`.

7. Update error pattern matching to typed contracts.

- Match typed atoms/tuples (for example `:timeout`, `{:js_error, msg}`), not string error messages.

8. Run parity and security verification suites before rollout:

```bash
mix test test/quickjs_ex_test.exs
mix test test/security_test.exs
```

Both suites should pass without relaxing assertions: parity checks confirm migration behavior, and the security suite confirms denylist and ownership guarantees.

## What you gain

- ES2023 support via QuickJS-NG.
- No callback replay/trampoline layer.
- Typed, pattern-matchable error categories.
- Safer default memory budget (4 MB).
- Actively maintained engine/runtime integration.
