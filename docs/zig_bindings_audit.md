# Zig Bindings Audit

This audit captures coverage of the required QuickJS-NG APIs in the vendored `mitchellh/zig-quickjs-ng` bindings, based on direct source inspection of the vendored Zig files under `priv/zig/zig_quickjs_ng/`.

## Audited Versions

- Zig bindings commit: `b3731c9` (`mitchellh/zig-quickjs-ng`)
- Transitive QuickJS-NG C commit: `85640f81e04bc93940acc2756c792c66076dd768` (`quickjs-ng/quickjs`)

## Coverage Table

| Function | Coverage Status | Notes |
|---|---|---|
| `JS_Eval` | **COVERED** | Found in `priv/zig/zig_quickjs_ng/context.zig` via `c.JS_Eval` wrapper. |
| `JS_GetException` | **COVERED** | Found in `priv/zig/zig_quickjs_ng/context.zig` via `c.JS_GetException` wrapper. |
| `JS_SetMemoryLimit` | **COVERED** | Found in `priv/zig/zig_quickjs_ng/runtime.zig` via `c.JS_SetMemoryLimit` wrapper. |
| `JS_SetMaxStackSize` | **COVERED** | Found in `priv/zig/zig_quickjs_ng/runtime.zig` via `c.JS_SetMaxStackSize` wrapper. |
| `JS_SetInterruptHandler` | **COVERED** | Found in `priv/zig/zig_quickjs_ng/runtime.zig` via `c.JS_SetInterruptHandler` wrapper. |
| `JS_NewCFunction` | **COVERED** | Found in `priv/zig/zig_quickjs_ng/value.zig` via `c.JS_NewCFunction` wrapper. |
| `JS_SetPropertyStr` | **COVERED** | Found in `priv/zig/zig_quickjs_ng/value.zig` via `c.JS_SetPropertyStr` wrapper. |

## Next steps

- No missing APIs from this required set. T2 can consume these existing wrappers directly.
