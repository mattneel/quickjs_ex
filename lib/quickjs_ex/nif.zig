const beam = @import("beam");
const e = @import("erl_nif");
const std = @import("std");
const zig_quickjs_ng = @import("zig_quickjs_ng");

const Runtime = zig_quickjs_ng.Runtime;
const Context = zig_quickjs_ng.Context;
const Value = zig_quickjs_ng.Value;
const Atom = zig_quickjs_ng.Atom;
const c = zig_quickjs_ng.c;

const MAX_MARSHAL_DEPTH: u32 = 100;
const INTERRUPT_GAS_QUANTUM: u64 = 10_000;

pub const JsContext = struct {
    runtime_ptr: usize,
    context_ptr: usize,
    owner_pid: beam.pid,
    deadline_ms: u64,
    poisoned: bool,
    was_interrupted: bool,
    callback_runner_pid: beam.pid,
    has_runner: bool,
    callback_mutex: std.Thread.Mutex,
    callback_condvar: std.Thread.Condition,
    callback_req_id: u64,
    callback_result_env: beam.env,
    callback_result: beam.term,
    callback_result_ready: bool,
    callback_error_env: beam.env,
    callback_error: ?beam.term,
    self_resource_env: beam.env,
    self_resource_term: e.ErlNifTerm,
    gas_quanta_total: u64,
    gas_quanta_last: u64,
};

fn runtime_ptr(ctx_res: *JsContext) *Runtime {
    return @ptrFromInt(ctx_res.runtime_ptr);
}

fn context_ptr(ctx_res: *JsContext) *Context {
    return @ptrFromInt(ctx_res.context_ptr);
}

const CallbackEntry = struct {
    name: [:0]u8,
    ctx_res: *JsContext,
};

fn callbackEntryFinalizer(entry: ?*CallbackEntry) void {
    const callback_entry = entry orelse return;
    beam.allocator.free(callback_entry.name);
    beam.allocator.destroy(callback_entry);
}

fn throw_type_error(ctx: *Context, msg: []const u8) Value {
    const msg_z = alloc_z_string(msg) catch {
        return ctx.throwTypeError("callback error");
    };
    defer beam.allocator.free(msg_z);
    return ctx.throwTypeError(msg_z);
}

fn callback_wait_timeout_ns(deadline_ms: u64) ?u64 {
    if (deadline_ms == 0) return null;
    if (deadline_ms > @as(u64, @intCast(std.math.maxInt(i64)))) return null;

    const now = std.time.milliTimestamp();
    if (now <= 0) return 0;

    const deadline: i64 = @intCast(deadline_ms);
    if (now >= deadline) return 0;

    const remaining_ms_i64 = deadline - now;
    const remaining_ms: u64 = @intCast(remaining_ms_i64);
    if (remaining_ms > std.math.maxInt(u64) / std.time.ns_per_ms) {
        return std.math.maxInt(u64);
    }

    return remaining_ms * std.time.ns_per_ms;
}

fn callback_dispatch_fn(raw_ctx: ?*Context, _this: Value, argv: []const c.JSValue, _magic: c_int, entry: ?*CallbackEntry) Value {
    _ = _this;
    _ = _magic;

    const ctx = raw_ctx orelse return Value.exception;
    const callback_entry = entry orelse return ctx.throwTypeError("callback dispatch missing entry");
    const ctx_res = callback_entry.ctx_res;
    const env = beam.context.env;

    if (ctx_res.poisoned) {
        return ctx.throwTypeError("javascript context poisoned");
    }

    if (!ctx_res.has_runner) {
        return ctx.throwTypeError("callback runner not configured");
    }

    var args = beam.allocator.alloc(beam.term, argv.len) catch {
        return ctx.throwTypeError("failed to allocate callback args");
    };
    defer beam.allocator.free(args);

    for (argv, 0..) |arg_raw, index| {
        const arg_value: Value = @bitCast(arg_raw);
        args[index] = js_to_erl(env, ctx, arg_value, 0) catch {
            return ctx.throwTypeError("failed to convert callback argument");
        };
    }

    const args_list = beam.make(args, .{ .env = env });

    ctx_res.callback_mutex.lock();
    ctx_res.callback_req_id += 1;
    const req_id = ctx_res.callback_req_id;
    ctx_res.callback_result_ready = false;
    if (ctx_res.callback_result_env) |previous_env| {
        e.enif_free_env(previous_env);
    }
    ctx_res.callback_result_env = null;
    ctx_res.callback_result = .{ .v = undefined };
    ctx_res.callback_mutex.unlock();

    const ctx_ref = beam.term{
        .v = e.enif_make_copy(env, ctx_res.self_resource_term),
    };

    const message = beam.make(.{
        .callback_request,
        req_id,
        callback_entry.name[0..callback_entry.name.len],
        args_list,
        ctx_ref,
    }, .{ .env = env });

    var runner_pid = ctx_res.callback_runner_pid;
    if (e.enif_send(env, &runner_pid, null, message.v) == 0) {
        ctx_res.poisoned = true;
        return ctx.throwTypeError("callback runner unavailable");
    }

    ctx_res.callback_mutex.lock();
    while (!ctx_res.callback_result_ready) {
        if (callback_wait_timeout_ns(ctx_res.deadline_ms)) |timeout_ns| {
            ctx_res.callback_condvar.timedWait(&ctx_res.callback_mutex, timeout_ns) catch {
                ctx_res.was_interrupted = true;
                ctx_res.callback_mutex.unlock();
                return ctx.throwTypeError("callback timed out");
            };
            continue;
        }

        ctx_res.callback_condvar.wait(&ctx_res.callback_mutex);
    }

    const callback_result = ctx_res.callback_result;
    const callback_result_env = ctx_res.callback_result_env;
    ctx_res.callback_result = .{ .v = undefined };
    ctx_res.callback_result_env = null;
    ctx_res.callback_result_ready = false;
    ctx_res.callback_mutex.unlock();

    const result_env = callback_result_env orelse {
        return ctx.throwTypeError("callback result env missing");
    };
    defer e.enif_free_env(result_env);

    const local_result = beam.term{
        .v = e.enif_make_copy(env, callback_result.v),
    };

    var response_arity: c_int = 0;
    var response_items: [*c]const e.ErlNifTerm = undefined;
    if (e.enif_get_tuple(env, local_result.v, &response_arity, @ptrCast(&response_items)) == 0 or response_arity != 2) {
        return ctx.throwTypeError("invalid callback response");
    }

    const status_term = beam.term{ .v = response_items[0] };
    const payload_term = beam.term{ .v = response_items[1] };

    if (term_is_atom(env, status_term, "ok")) {
        return erl_to_js(env, ctx, payload_term, 0) catch {
            return ctx.throwTypeError("failed to encode callback result");
        };
    }

    if (term_is_atom(env, status_term, "error")) {
        var error_arity: c_int = 0;
        var error_items: [*c]const e.ErlNifTerm = undefined;
        if (e.enif_get_tuple(env, payload_term.v, &error_arity, @ptrCast(&error_items)) == 0 or error_arity != 3) {
            return ctx.throwTypeError("invalid callback error");
        }

        const error_tag = beam.term{ .v = error_items[0] };
        if (!term_is_atom(env, error_tag, "cb")) {
            return ctx.throwTypeError("invalid callback error tag");
        }

        const message_term = beam.term{ .v = error_items[2] };
        const callback_message = beam.get([]const u8, message_term, .{ .env = env }) catch "callback failed";

        if (ctx_res.callback_error_env) |old_env| {
            e.enif_free_env(old_env);
        }

        const callback_error_env = e.enif_alloc_env();
        if (callback_error_env != null) {
            const copied_error = e.enif_make_copy(callback_error_env, local_result.v);
            ctx_res.callback_error_env = callback_error_env;
            ctx_res.callback_error = .{ .v = copied_error };
        } else {
            ctx_res.callback_error_env = null;
            ctx_res.callback_error = null;
        }

        return throw_type_error(ctx, callback_message);
    }

    return ctx.throwTypeError("invalid callback response");
}

const JsContextCallbacks = struct {
    pub fn dtor(ctx_res: *JsContext) void {
        if (ctx_res.callback_result_env) |result_env| {
            e.enif_free_env(result_env);
            ctx_res.callback_result_env = null;
        }

        if (ctx_res.callback_error_env) |error_env| {
            e.enif_free_env(error_env);
            ctx_res.callback_error_env = null;
            ctx_res.callback_error = null;
        }

        if (ctx_res.self_resource_env) |resource_env| {
            e.enif_free_env(resource_env);
            ctx_res.self_resource_env = null;
        }

        context_ptr(ctx_res).deinit();
        runtime_ptr(ctx_res).deinit();
    }
};

pub const JsContextResource = beam.Resource(JsContext, @import("root"), .{
    .Callbacks = JsContextCallbacks,
});

fn interrupt_handler(opaque_ptr: ?*JsContext, runtime: *Runtime) bool {
    _ = runtime;

    const ctx_res = opaque_ptr orelse return false;
    ctx_res.gas_quanta_total +|= 1;
    if (ctx_res.deadline_ms == 0) return false;
    if (ctx_res.deadline_ms > @as(u64, @intCast(std.math.maxInt(i64)))) return false;

    const now = std.time.milliTimestamp();
    if (now <= 0) return false;

    if (now > @as(i64, @intCast(ctx_res.deadline_ms))) {
        ctx_res.was_interrupted = true;
        return true;
    }

    return false;
}

pub fn ping() beam.term {
    return beam.make(.ok, .{});
}

pub fn nif_new(memory_limit_bytes: u64, stack_limit_bytes: u64, timeout_ms: u64) beam.term {
    _ = timeout_ms;

    const runtime = Runtime.init() catch {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };
    errdefer runtime.deinit();

    if (memory_limit_bytes > 0) {
        runtime.setMemoryLimit(memory_limit_bytes);
    }

    if (stack_limit_bytes > 0) {
        runtime.setMaxStackSize(stack_limit_bytes);
    }

    const context = Context.init(runtime) catch {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };
    errdefer context.deinit();

    const owner_pid = beam.self(.{}) catch {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };

    var resource = JsContextResource.create(.{
        .runtime_ptr = @intFromPtr(runtime),
        .context_ptr = @intFromPtr(context),
        .owner_pid = owner_pid,
        .deadline_ms = 0,
        .poisoned = false,
        .was_interrupted = false,
        .callback_runner_pid = std.mem.zeroes(beam.pid),
        .has_runner = false,
        .callback_mutex = .{},
        .callback_condvar = .{},
        .callback_req_id = 0,
        .callback_result_env = null,
        .callback_result = .{ .v = undefined },
        .callback_result_ready = false,
        .callback_error_env = null,
        .callback_error = null,
        .self_resource_env = null,
        .self_resource_term = undefined,
        .gas_quanta_total = 0,
        .gas_quanta_last = 0,
    }, .{}) catch {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };

    runtime.setInterruptHandler(JsContext, resource.__payload, interrupt_handler);
    context.setOpaque(JsContext, resource.__payload);

    const self_resource_env = e.enif_alloc_env();
    if (self_resource_env == null) {
        resource.release();
        return beam.make(.{ .@"error", .internal_error }, .{});
    }

    const self_resource_term = e.enif_make_resource(beam.context.env, @ptrCast(resource.__payload));
    resource.__payload.self_resource_env = self_resource_env;
    resource.__payload.self_resource_term = e.enif_make_copy(self_resource_env, self_resource_term);

    return beam.make(.{ .ok, resource }, .{});
}

pub fn nif_eval(resource_ref: beam.term, code_term: beam.term, timeout_ms: u64) beam.term {
    const env = beam.context.env;

    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };
    defer ctx_resource.release();
    const ctx_res = ctx_resource.__payload;

    if (ctx_res.poisoned) {
        return beam.make(.{ .@"error", .poisoned }, .{});
    }

    if (!is_owner(env, ctx_res.owner_pid)) {
        return beam.make(.{ .@"error", .not_owner }, .{});
    }

    const ctx = context_ptr(ctx_res);

    ctx_res.was_interrupted = false;

    if (timeout_ms > 0) {
        const now = std.time.milliTimestamp();
        if (now > 0) {
            const timeout_i64: i64 = if (timeout_ms > @as(u64, @intCast(std.math.maxInt(i64))))
                std.math.maxInt(i64)
            else
                @intCast(timeout_ms);
            const deadline_i64: i64 = if (now > std.math.maxInt(i64) - timeout_i64)
                std.math.maxInt(i64)
            else
                now + timeout_i64;
            ctx_res.deadline_ms = @intCast(deadline_i64);
        } else {
            ctx_res.deadline_ms = timeout_ms;
        }
    } else {
        ctx_res.deadline_ms = 0;
    }

    defer ctx_res.deadline_ms = 0;

    var code_binary: e.ErlNifBinary = undefined;
    if (e.enif_inspect_binary(env, code_term.v, &code_binary) == 0) {
        return beam.make(.{ .@"error", .internal_error }, .{});
    }

    const code = code_binary.data[0..code_binary.size];
    const code_copy = beam.allocator.alloc(u8, code.len + 1) catch {
        return poison_internal_error(ctx_res);
    };
    defer beam.allocator.free(code_copy);

    @memcpy(code_copy[0..code.len], code);
    code_copy[code.len] = 0;

    const gas_start = ctx_res.gas_quanta_total;
    defer {
        const gas_delta = ctx_res.gas_quanta_total - gas_start;
        ctx_res.gas_quanta_last = if (gas_delta == 0) 1 else gas_delta;
    }

    const result = ctx.eval(code_copy[0..code.len], "<eval>", .{});
    defer result.deinit(ctx);

    if (result.isException()) {
        const exc = ctx.getException();
        defer exc.deinit(ctx);

        if (ctx_res.was_interrupted) {
            return beam.make(.{ .@"error", .timeout }, .{});
        }

        if (ctx_res.callback_error) |callback_error| {
            const copied_callback_error = beam.term{
                .v = e.enif_make_copy(env, callback_error.v),
            };

            if (ctx_res.callback_error_env) |error_env| {
                e.enif_free_env(error_env);
                ctx_res.callback_error_env = null;
            }
            ctx_res.callback_error = null;

            return copied_callback_error;
        }

        if (exception_is_oom(ctx, exc)) {
            ctx_res.poisoned = true;
            return beam.make(.{ .@"error", .oom }, .{});
        }

        return js_error_from_exception(ctx, exc);
    }

    if (result.isPromise()) {
        return beam.make(.{ .@"error", .async }, .{});
    }

    if (result.isFunction(ctx)) {
        return beam.make(.{ .@"error", .{ .js, "value of type 'function' is not serializable" } }, .{});
    }

    const erl_term = js_to_erl(env, ctx, result, 0) catch |err| {
        return switch (err) {
            error.MaxDepth => beam.make(.{ .@"error", .{ .js, "maximum depth exceeded" } }, .{}),
            error.FunctionNotSerializable => beam.make(.{ .@"error", .{ .js, "value of type 'function' is not serializable" } }, .{}),
            error.JSError => current_js_error_with_poison(ctx_res, ctx),
            error.OutOfMemory => poison_internal_error(ctx_res),
        };
    };

    return beam.make(.{ .ok, erl_term }, .{});
}

pub fn nif_get_gas(resource_ref: beam.term) beam.term {
    const env = beam.context.env;

    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };
    defer ctx_resource.release();
    const ctx_res = ctx_resource.__payload;

    if (ctx_res.poisoned) {
        return beam.make(.{ .@"error", .poisoned }, .{});
    }

    if (!is_owner(env, ctx_res.owner_pid)) {
        return beam.make(.{ .@"error", .not_owner }, .{});
    }

    const gas = beam.make(.{
        .last = ctx_res.gas_quanta_last,
        .total = ctx_res.gas_quanta_total,
        .quantum = INTERRUPT_GAS_QUANTUM,
    }, .{});

    return beam.make(.{ .ok, gas }, .{});
}

pub fn nif_get(resource_ref: beam.term, name: []const u8) beam.term {
    const env = beam.context.env;

    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };
    defer ctx_resource.release();
    const ctx_res = ctx_resource.__payload;

    if (ctx_res.poisoned) {
        return beam.make(.{ .@"error", .poisoned }, .{});
    }

    if (!is_owner(env, ctx_res.owner_pid)) {
        return beam.make(.{ .@"error", .not_owner }, .{});
    }

    const ctx = context_ptr(ctx_res);

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const name_z = alloc_z_string(name) catch {
        return poison_internal_error(ctx_res);
    };
    defer beam.allocator.free(name_z);

    const prop = global.getPropertyStr(ctx, name_z);
    defer prop.deinit(ctx);

    if (prop.isException()) {
        return current_js_error_with_poison(ctx_res, ctx);
    }

    const erl_term = js_to_erl(env, ctx, prop, 0) catch |err| {
        return switch (err) {
            error.MaxDepth => beam.make(.{ .@"error", .{ .js, "maximum depth exceeded" } }, .{}),
            error.FunctionNotSerializable => beam.make(.{ .@"error", .{ .js, "value of type 'function' is not serializable" } }, .{}),
            error.JSError => current_js_error_with_poison(ctx_res, ctx),
            error.OutOfMemory => poison_internal_error(ctx_res),
        };
    };

    return beam.make(.{ .ok, erl_term }, .{});
}

pub fn nif_set_value(resource_ref: beam.term, name: []const u8, value: beam.term) beam.term {
    const env = beam.context.env;

    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };
    defer ctx_resource.release();
    const ctx_res = ctx_resource.__payload;

    if (ctx_res.poisoned) {
        return beam.make(.{ .@"error", .poisoned }, .{});
    }

    if (!is_owner(env, ctx_res.owner_pid)) {
        return beam.make(.{ .@"error", .not_owner }, .{});
    }

    const ctx = context_ptr(ctx_res);

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const name_z = alloc_z_string(name) catch {
        return poison_internal_error(ctx_res);
    };
    defer beam.allocator.free(name_z);

    const js_val = erl_to_js(env, ctx, value, 0) catch |err| {
        return erl_to_js_error_term(ctx_res, ctx, err);
    };

    global.setPropertyStr(ctx, name_z, js_val) catch {
        return property_set_error_term(ctx_res, ctx);
    };

    return beam.make(.ok, .{});
}

pub fn nif_set_path(resource_ref: beam.term, path: [][]const u8, value: beam.term) beam.term {
    const env = beam.context.env;

    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };
    defer ctx_resource.release();
    const ctx_res = ctx_resource.__payload;

    if (ctx_res.poisoned) {
        return beam.make(.{ .@"error", .poisoned }, .{});
    }

    if (!is_owner(env, ctx_res.owner_pid)) {
        return beam.make(.{ .@"error", .not_owner }, .{});
    }

    if (path.len < 1) {
        return beam.make(.{ .@"error", .{ .js, "path must not be empty" } }, .{});
    }

    const ctx = context_ptr(ctx_res);

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    var current = global.dup(ctx);
    defer current.deinit(ctx);

    for (path[0 .. path.len - 1]) |segment| {
        const segment_z = alloc_z_string(segment) catch {
            return poison_internal_error(ctx_res);
        };
        defer beam.allocator.free(segment_z);

        var child = current.getPropertyStr(ctx, segment_z);

        if (child.isException()) {
            child.deinit(ctx);
            return current_js_error_with_poison(ctx_res, ctx);
        }

        if (child.isNull() or child.isUndefined()) {
            child.deinit(ctx);

            const new_obj = Value.initObject(ctx);
            if (new_obj.isException()) {
                return current_js_error_with_poison(ctx_res, ctx);
            }

            current.setPropertyStr(ctx, segment_z, new_obj) catch {
                return property_set_error_term(ctx_res, ctx);
            };

            child = current.getPropertyStr(ctx, segment_z);
            if (child.isException()) {
                child.deinit(ctx);
                return current_js_error_with_poison(ctx_res, ctx);
            }
        } else if (!is_plain_object(ctx, child)) {
            child.deinit(ctx);
            return beam.make(.{ .@"error", .{ .js, "cannot set nested path: intermediate is not an object" } }, .{});
        }

        const prev = current;
        current = child;
        prev.deinit(ctx);
    }

    const last_segment_z = alloc_z_string(path[path.len - 1]) catch {
        return poison_internal_error(ctx_res);
    };
    defer beam.allocator.free(last_segment_z);

    const js_val = erl_to_js(env, ctx, value, 0) catch |err| {
        return erl_to_js_error_term(ctx_res, ctx, err);
    };

    current.setPropertyStr(ctx, last_segment_z, js_val) catch {
        return property_set_error_term(ctx_res, ctx);
    };

    return beam.make(.ok, .{});
}

pub fn nif_gc(resource_ref: beam.term) beam.term {
    const env = beam.context.env;

    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };
    defer ctx_resource.release();
    const ctx_res = ctx_resource.__payload;

    if (ctx_res.poisoned) {
        return beam.make(.{ .@"error", .poisoned }, .{});
    }

    if (!is_owner(env, ctx_res.owner_pid)) {
        return beam.make(.{ .@"error", .not_owner }, .{});
    }

    runtime_ptr(ctx_res).runGC();
    return beam.make(.ok, .{});
}

pub fn nif_register_callback(resource_ref: beam.term, name: []const u8, _fun_term: beam.term) beam.term {
    _ = _fun_term;

    const env = beam.context.env;

    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };
    defer ctx_resource.release();
    const ctx_res = ctx_resource.__payload;

    if (ctx_res.poisoned) {
        return beam.make(.{ .@"error", .poisoned }, .{});
    }

    if (!is_owner(env, ctx_res.owner_pid)) {
        return beam.make(.{ .@"error", .not_owner }, .{});
    }

    const callback_name = alloc_z_string(name) catch {
        return poison_internal_error(ctx_res);
    };

    const callback_entry = beam.allocator.create(CallbackEntry) catch {
        beam.allocator.free(callback_name);
        return poison_internal_error(ctx_res);
    };

    callback_entry.* = .{
        .name = callback_name,
        .ctx_res = ctx_res,
    };

    const ctx = context_ptr(ctx_res);
    const fn_value = Value.initCClosure(
        ctx,
        CallbackEntry,
        callback_dispatch_fn,
        callback_entry.name,
        callbackEntryFinalizer,
        0,
        0,
        callback_entry,
    );

    if (fn_value.isException()) {
        callbackEntryFinalizer(callback_entry);
        return beam.make(.{ .@"error", .internal_error }, .{});
    }

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    global.setPropertyStr(ctx, callback_entry.name, fn_value) catch {
        ctx_res.poisoned = true;
        return beam.make(.{ .@"error", .internal_error }, .{});
    };

    return beam.make(.ok, .{});
}

pub fn nif_set_callback_runner(resource_ref: beam.term, runner_pid: beam.pid) beam.term {
    const env = beam.context.env;

    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };
    defer ctx_resource.release();
    const ctx_res = ctx_resource.__payload;

    if (!is_owner(env, ctx_res.owner_pid)) {
        return beam.make(.{ .@"error", .not_owner }, .{});
    }

    ctx_res.callback_runner_pid = runner_pid;
    ctx_res.has_runner = true;

    return beam.make(.ok, .{});
}

pub fn nif_signal_callback_result(resource_ref: beam.term, req_id: u64, result: beam.term) beam.term {
    const env = beam.context.env;

    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };
    defer ctx_resource.release();
    const ctx_res = ctx_resource.__payload;

    if (!ctx_res.has_runner or !is_owner(env, ctx_res.callback_runner_pid)) {
        return beam.make(.{ .@"error", .not_owner }, .{});
    }

    const msg_env = e.enif_alloc_env();
    if (msg_env == null) {
        return beam.make(.{ .@"error", .internal_error }, .{});
    }

    const copied_result = e.enif_make_copy(msg_env, result.v);

    ctx_res.callback_mutex.lock();
    defer ctx_res.callback_mutex.unlock();

    if (ctx_res.callback_req_id != req_id) {
        e.enif_free_env(msg_env);
        return beam.make(.{ .@"error", .stale }, .{});
    }

    if (ctx_res.callback_result_env) |previous_env| {
        e.enif_free_env(previous_env);
    }

    ctx_res.callback_result_env = msg_env;
    ctx_res.callback_result = .{ .v = copied_result };
    ctx_res.callback_result_ready = true;
    ctx_res.callback_condvar.signal();

    return beam.make(.ok, .{});
}

pub fn nif_transfer_owner(resource_ref: beam.term, new_owner: beam.pid) beam.term {
    const env = beam.context.env;

    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };
    defer ctx_resource.release();
    const ctx_res = ctx_resource.__payload;

    if (!is_owner(env, ctx_res.owner_pid)) {
        return beam.make(.{ .@"error", .not_owner }, .{});
    }

    ctx_res.owner_pid = new_owner;
    return beam.make(.ok, .{});
}

fn fetch_js_context(env: beam.env, resource_ref: beam.term) ?JsContextResource {
    const resource = beam.get(JsContextResource, resource_ref, .{
        .env = env,
    }) catch return null;

    return resource;
}

fn is_owner(env: beam.env, owner_pid: beam.pid) bool {
    const self_pid = beam.self(.{ .env = env }) catch return false;

    const owner_term = beam.make(owner_pid, .{ .env = env });
    const self_term = beam.make(self_pid, .{ .env = env });

    return e.enif_is_identical(owner_term.v, self_term.v) != 0;
}

fn is_owner_or_runner(env: beam.env, ctx_res: *JsContext) bool {
    if (is_owner(env, ctx_res.owner_pid)) {
        return true;
    }

    return ctx_res.has_runner and is_owner(env, ctx_res.callback_runner_pid);
}

fn is_plain_object(ctx: *Context, val: Value) bool {
    return val.isObject() and
        !val.isArray() and
        !val.isFunction(ctx) and
        !val.isPromise() and
        !val.isDate() and
        !val.isError() and
        !val.isMap() and
        !val.isSet() and
        !val.isWeakRef() and
        !val.isWeakSet() and
        !val.isWeakMap() and
        !val.isArrayBuffer() and
        !val.isRegExp() and
        !val.isProxy() and
        !val.isDataView() and
        val.getTypedArrayType() == null;
}

fn alloc_z_string(input: []const u8) error{OutOfMemory}![:0]u8 {
    return std.fmt.allocPrintSentinel(beam.allocator, "{s}", .{input}, 0);
}

fn get_atom_name(env: beam.env, term: beam.term, buf: *[256]u8) ?[]const u8 {
    const len = e.enif_get_atom(env, term.v, buf, buf.len, e.ERL_NIF_LATIN1);
    if (len <= 0) return null;

    return buf[0..@as(usize, @intCast(len - 1))];
}

fn term_is_atom(env: beam.env, term: beam.term, name: []const u8) bool {
    if (term.term_type(.{ .env = env }) != .atom) return false;

    var buf: [256]u8 = undefined;
    const atom_name = get_atom_name(env, term, &buf) orelse return false;
    return std.mem.eql(u8, atom_name, name);
}

fn js_error_from_exception(ctx: *Context, exc: Value) beam.term {
    if (exc.toZigSlice(ctx)) |msg| {
        defer ctx.freeCString(msg.ptr);
        return beam.make(.{ .@"error", .{ .js, msg[0..msg.len] } }, .{});
    }

    return beam.make(.{ .@"error", .{ .js, "javascript exception" } }, .{});
}

fn current_js_error_with_poison(ctx_res: *JsContext, ctx: *Context) beam.term {
    if (!ctx.hasException()) {
        return poison_internal_error(ctx_res);
    }

    const exc = ctx.getException();
    defer exc.deinit(ctx);

    if (exception_is_oom(ctx, exc)) {
        ctx_res.poisoned = true;
        return beam.make(.{ .@"error", .oom }, .{});
    }

    return js_error_from_exception(ctx, exc);
}

fn property_set_error_term(ctx_res: *JsContext, ctx: *Context) beam.term {
    if (!ctx.hasException()) {
        return poison_internal_error(ctx_res);
    }

    const exc = ctx.getException();
    defer exc.deinit(ctx);

    if (exception_is_oom(ctx, exc)) {
        ctx_res.poisoned = true;
        return beam.make(.{ .@"error", .oom }, .{});
    }

    return beam.make(.{ .@"error", .{ .js, "property set failed" } }, .{});
}

fn poison_internal_error(ctx_res: *JsContext) beam.term {
    ctx_res.poisoned = true;
    return beam.make(.{ .@"error", .internal_error }, .{});
}

fn exception_is_oom(ctx: *Context, exc: Value) bool {
    if (exc.isUncatchableError()) return true;

    const msg = exc.toZigSlice(ctx) orelse return false;
    defer ctx.freeCString(msg.ptr);

    return std.mem.indexOf(u8, msg, "out of memory") != null;
}

fn erl_to_js_error_term(ctx_res: *JsContext, ctx: *Context, err: anyerror) beam.term {
    return switch (err) {
        error.MaxDepth => beam.make(.{ .@"error", .{ .js, "maximum depth exceeded" } }, .{}),
        error.Unsupported => beam.make(.{ .@"error", .{ .js, "unsupported value type" } }, .{}),
        error.JSError => current_js_error_with_poison(ctx_res, ctx),
        error.OutOfMemory => poison_internal_error(ctx_res),
        else => poison_internal_error(ctx_res),
    };
}

fn js_to_erl(env: beam.env, ctx: *Context, val: Value, depth: u32) error{ MaxDepth, FunctionNotSerializable, JSError, OutOfMemory }!beam.term {
    _ = Atom;

    if (depth >= MAX_MARSHAL_DEPTH) return error.MaxDepth;

    if (val.isNull() or val.isUndefined()) {
        return beam.make(null, .{ .env = env });
    }

    if (val.isBool()) {
        const b = val.toBool(ctx) catch return error.JSError;
        return beam.make(b, .{ .env = env });
    }

    if (val.isNumber()) {
        if (val.tag == .int) {
            const i = val.toInt64(ctx) catch return error.JSError;
            return beam.make(i, .{ .env = env });
        }

        const f = val.toFloat64(ctx) catch return error.JSError;
        if (std.math.isFinite(f)) {
            const truncated = @trunc(f);
            if (truncated == f and
                truncated >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
                truncated <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
            {
                return beam.make(@as(i64, @intFromFloat(truncated)), .{ .env = env });
            }
        }

        return beam.make(f, .{ .env = env });
    }

    if (val.isString()) {
        const s = val.toZigSlice(ctx) orelse return error.JSError;
        defer ctx.freeCString(s.ptr);

        return beam.make(s[0..s.len], .{ .env = env });
    }

    if (val.isFunction(ctx)) {
        return error.FunctionNotSerializable;
    }

    if (val.isArray()) {
        const length_value = val.getPropertyStr(ctx, "length");
        defer length_value.deinit(ctx);

        if (length_value.isException()) return error.JSError;

        const length_u32 = length_value.toUint32(ctx) catch return error.JSError;
        const length: usize = @intCast(length_u32);

        var list_items = try beam.allocator.alloc(beam.term, length);
        defer beam.allocator.free(list_items);

        for (0..length) |index| {
            const item = val.getPropertyUint32(ctx, @intCast(index));
            defer item.deinit(ctx);

            if (item.isException()) return error.JSError;

            list_items[index] = try js_to_erl(env, ctx, item, depth + 1);
        }

        return beam.make(list_items, .{ .env = env });
    }

    if (val.isPromise()) {
        return error.JSError;
    }

    if (val.isObject()) {
        const props = val.getOwnPropertyNames(ctx, .enum_strings) catch return error.JSError;
        defer Value.freePropertyEnum(ctx, props);

        var map_term: beam.term = .{ .v = e.enif_make_new_map(env) };

        for (props) |prop| {
            const key = prop.atom.toZigSlice(ctx) orelse return error.JSError;
            defer ctx.freeCString(key.ptr);

            const key_term = beam.make(key[0..key.len], .{ .env = env });

            const item = val.getProperty(ctx, prop.atom);
            defer item.deinit(ctx);

            if (item.isException()) return error.JSError;

            const item_term = try js_to_erl(env, ctx, item, depth + 1);

            var updated_map: e.ErlNifTerm = undefined;
            if (e.enif_make_map_put(env, map_term.v, key_term.v, item_term.v, &updated_map) == 0) {
                return error.JSError;
            }

            map_term = .{ .v = updated_map };
        }

        return map_term;
    }

    return error.JSError;
}

fn erl_to_js(env: beam.env, ctx: *Context, term: beam.term, depth: u32) error{ MaxDepth, Unsupported, JSError, OutOfMemory }!Value {
    if (depth >= MAX_MARSHAL_DEPTH) return error.MaxDepth;

    const term_type = term.term_type(.{ .env = env });

    switch (term_type) {
        .atom => {
            if (term_is_atom(env, term, "nil")) {
                return Value.null_;
            }

            if (term_is_atom(env, term, "true")) {
                return Value.initBool(true);
            }

            if (term_is_atom(env, term, "false")) {
                return Value.initBool(false);
            }

            var atom_buf: [256]u8 = undefined;
            const atom_name = get_atom_name(env, term, &atom_buf) orelse return error.Unsupported;
            const atom_z = try alloc_z_string(atom_name);
            defer beam.allocator.free(atom_z);

            const atom_val = Value.initString(ctx, atom_z);
            if (atom_val.isException()) return error.JSError;
            return atom_val;
        },

        .integer => {
            const int_value = beam.get(i64, term, .{ .env = env }) catch return error.Unsupported;
            return Value.initInt64(int_value);
        },

        .float => {
            const float_value = beam.get(f64, term, .{ .env = env }) catch return error.Unsupported;
            return Value.initFloat64(float_value);
        },

        .bitstring => {
            const bytes = beam.get([]const u8, term, .{ .env = env }) catch return error.Unsupported;
            const string_val = Value.initStringLen(ctx, bytes);
            if (string_val.isException()) return error.JSError;
            return string_val;
        },

        .list => {
            const list_values = beam.get([]beam.term, term, .{ .env = env }) catch return error.Unsupported;
            defer beam.allocator.free(list_values);

            var array_val = Value.initArray(ctx);
            if (array_val.isException()) return error.JSError;
            errdefer array_val.deinit(ctx);

            for (list_values, 0..) |list_item, index| {
                const js_item = try erl_to_js(env, ctx, list_item, depth + 1);
                array_val.setPropertyUint32(ctx, @intCast(index), js_item) catch return error.JSError;
            }

            return array_val;
        },

        .map => {
            var object_val = Value.initObject(ctx);
            if (object_val.isException()) return error.JSError;
            errdefer object_val.deinit(ctx);

            var iter: e.ErlNifMapIterator = undefined;
            if (e.enif_map_iterator_create(env, term.v, &iter, e.ERL_NIF_MAP_ITERATOR_FIRST) == 0) {
                return error.Unsupported;
            }
            defer e.enif_map_iterator_destroy(env, &iter);

            while (true) {
                var key_raw: e.ErlNifTerm = undefined;
                var value_raw: e.ErlNifTerm = undefined;

                if (e.enif_map_iterator_get_pair(env, &iter, &key_raw, &value_raw) == 0) {
                    break;
                }

                const key_term: beam.term = .{ .v = key_raw };
                const value_term: beam.term = .{ .v = value_raw };

                const key_z = try map_key_to_z(env, key_term);
                defer beam.allocator.free(key_z);

                const js_item = try erl_to_js(env, ctx, value_term, depth + 1);
                object_val.setPropertyStr(ctx, key_z, js_item) catch return error.JSError;

                if (e.enif_map_iterator_next(env, &iter) == 0) {
                    break;
                }
            }

            return object_val;
        },

        else => return error.Unsupported,
    }
}

fn map_key_to_z(env: beam.env, key_term: beam.term) error{ OutOfMemory, Unsupported }![:0]u8 {
    switch (key_term.term_type(.{ .env = env })) {
        .bitstring => {
            const key = beam.get([]const u8, key_term, .{ .env = env }) catch return error.Unsupported;
            return alloc_z_string(key);
        },

        .atom => {
            var atom_buf: [256]u8 = undefined;
            const atom_name = get_atom_name(env, key_term, &atom_buf) orelse return error.Unsupported;
            return alloc_z_string(atom_name);
        },

        .integer => {
            const key = beam.get(i64, key_term, .{ .env = env }) catch return error.Unsupported;
            return std.fmt.allocPrintSentinel(beam.allocator, "{d}", .{key}, 0);
        },

        .float => {
            const key = beam.get(f64, key_term, .{ .env = env }) catch return error.Unsupported;
            return std.fmt.allocPrintSentinel(beam.allocator, "{d}", .{key}, 0);
        },

        else => return error.Unsupported,
    }
}
