// ADAPTER: exposes vendored QuickJS-NG C declarations as the `quickjs_c` Zig module.
pub const c = @cImport({
    @cInclude("quickjs.h");
});
