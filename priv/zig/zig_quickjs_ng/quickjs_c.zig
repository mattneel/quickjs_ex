// ADAPTER: exposes vendored QuickJS-NG C declarations as the `quickjs_c` Zig module.
pub const c = @cImport({
    @cInclude("/home/autark/src/quickjs_ex/c_src/quickjs_ng/quickjs.h");
});
