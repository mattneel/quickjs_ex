const beam = @import("beam");
const e = @import("erl_nif");
const std = @import("std");
const zig_quickjs_ng = @import("zig_quickjs_ng");

const Runtime = zig_quickjs_ng.Runtime;
const Context = zig_quickjs_ng.Context;
const Value = zig_quickjs_ng.Value;
const Atom = zig_quickjs_ng.Atom;
const ModuleDef = zig_quickjs_ng.ModuleDef;
const EvalFlags = zig_quickjs_ng.EvalFlags;
const c = zig_quickjs_ng.c;

const MAX_MARSHAL_DEPTH: u32 = 100;
const MAX_RESULT_ARRAY_LENGTH: usize = 10_000;
const MAX_RESULT_OBJECT_PROPERTIES: usize = 10_000;
const MAX_RESULT_NODE_COUNT: usize = 50_000;
const MAX_PENDING_ASYNC_CALLBACKS: usize = 64;
const INTERRUPT_GAS_QUANTUM: u64 = 10_000;
const CALLBACK_OWNER_CHECK_NS: u64 = 100 * std.time.ns_per_ms;
const CONTEXT_THREAD_MIN_STACK_BYTES: u64 = 2 * 1024 * 1024;
const CONTEXT_THREAD_STACK_HEADROOM_BYTES: u64 = 512 * 1024;

const CommandKind = enum {
    eval,
    get,
    get_gas,
    set_value,
    set_path,
    gc,
    register_callback,
    register_async_callback,
    stop,
};

const CallbackAbortReason = enum {
    none,
    shutdown,
    owner_down,
};

const Command = struct {
    kind: CommandKind,
    ctx_res_ptr: usize = 0,
    caller_pid: beam.pid,
    ref_env: beam.env,
    ref_term: beam.term,
    term_env: beam.env = null,
    value_term: beam.term = .{ .v = undefined },
    code: ?[]u8 = null,
    eval_as_module: bool = false,
    timeout_ms: u64 = 0,
    name: ?[:0]u8 = null,
    path: ?[][:0]u8 = null,
    next: ?*Command = null,
};

pub const JsContext = struct {
    runtime_ptr: usize,
    context_ptr: usize,
    owner_pid: beam.pid,
    memory_limit_bytes: u64,
    stack_limit_bytes: u64,
    thread: e.ErlNifTid,
    thread_started: bool,
    thread_joined: bool,
    init_mutex: std.Thread.Mutex,
    init_condvar: std.Thread.Condition,
    init_done: bool,
    init_ok: bool,
    queue_mutex: std.Thread.Mutex,
    queue_condvar: std.Thread.Condition,
    queue_head_ptr: usize,
    queue_tail_ptr: usize,
    shutting_down: bool,
    busy: bool,
    deadline_ms: u64,
    poisoned: bool,
    was_interrupted: bool,
    active_caller_pid: beam.pid,
    active_ref_env: beam.env,
    active_ref_term: beam.term,
    has_active_command: bool,
    owner_check_ms: i64,
    callback_mutex: std.Thread.Mutex,
    callback_condvar: std.Thread.Condition,
    callback_req_id: u64,
    callback_result_env: beam.env,
    callback_result: beam.term,
    callback_result_ready: bool,
    callback_abort_reason: CallbackAbortReason,
    callback_error_env: beam.env,
    callback_error: ?beam.term,
    async_entries_head_ptr: usize,
    async_entries_count: usize,
    async_resolution_head_ptr: usize,
    async_resolution_tail_ptr: usize,
    module_load_error: bool,
    gas_quanta_total: u64,
    gas_quanta_last: u64,
};

fn runtime_ptr(ctx_res: *JsContext) *Runtime {
    return @ptrFromInt(ctx_res.runtime_ptr);
}

fn context_ptr(ctx_res: *JsContext) *Context {
    return @ptrFromInt(ctx_res.context_ptr);
}

fn command_ptr(raw: usize) ?*Command {
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

fn command_context_ptr(cmd: *Command) ?*JsContext {
    if (cmd.ctx_res_ptr == 0) return null;
    return @ptrFromInt(cmd.ctx_res_ptr);
}

fn command_raw(cmd: ?*Command) usize {
    return if (cmd) |value| @intFromPtr(value) else 0;
}

fn async_entry_ptr(raw: usize) ?*AsyncEntry {
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

fn async_entry_raw(entry: ?*AsyncEntry) usize {
    return if (entry) |value| @intFromPtr(value) else 0;
}

fn async_resolution_ptr(raw: usize) ?*AsyncResolution {
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

fn async_resolution_raw(resolution: ?*AsyncResolution) usize {
    return if (resolution) |value| @intFromPtr(value) else 0;
}

const ActiveCommandSnapshot = struct {
    caller_pid: beam.pid,
    ref_term: beam.term,
};

fn load_flag(flag: *const bool) bool {
    return @atomicLoad(bool, flag, .seq_cst);
}

fn store_flag(flag: *bool, value: bool) void {
    @atomicStore(bool, flag, value, .seq_cst);
}

fn context_is_poisoned(ctx_res: *JsContext) bool {
    return load_flag(&ctx_res.poisoned);
}

fn mark_context_poisoned(ctx_res: *JsContext) void {
    store_flag(&ctx_res.poisoned, true);
}

fn context_is_shutting_down(ctx_res: *JsContext) bool {
    return load_flag(&ctx_res.shutting_down);
}

fn mark_context_shutting_down(ctx_res: *JsContext) void {
    store_flag(&ctx_res.shutting_down, true);
}

fn active_command_snapshot(ctx_res: *JsContext, env: beam.env) ?ActiveCommandSnapshot {
    ctx_res.callback_mutex.lock();
    defer ctx_res.callback_mutex.unlock();

    if (!ctx_res.has_active_command) return null;

    return .{
        .caller_pid = ctx_res.active_caller_pid,
        .ref_term = .{ .v = e.enif_make_copy(env, ctx_res.active_ref_term.v) },
    };
}

fn active_request_matches_locked(ctx_res: *JsContext, env: beam.env, request_ref: beam.term) bool {
    if (!ctx_res.has_active_command) return false;

    const active_ref = e.enif_make_copy(env, ctx_res.active_ref_term.v);
    return e.enif_compare(request_ref.v, active_ref) == 0;
}

fn async_entry_exists_locked(ctx_res: *JsContext, req_id: u64) bool {
    var current = async_entry_ptr(ctx_res.async_entries_head_ptr);

    while (current) |entry| {
        if (entry.req_id == req_id) return true;
        current = entry.next;
    }

    return false;
}

fn active_command_caller(ctx_res: *JsContext) ?beam.pid {
    ctx_res.callback_mutex.lock();
    defer ctx_res.callback_mutex.unlock();

    if (!ctx_res.has_active_command) return null;
    return ctx_res.active_caller_pid;
}

fn set_active_command(ctx_res: *JsContext, cmd: *Command) void {
    ctx_res.callback_mutex.lock();
    defer ctx_res.callback_mutex.unlock();

    ctx_res.active_caller_pid = cmd.caller_pid;
    ctx_res.active_ref_env = cmd.ref_env;
    ctx_res.active_ref_term = cmd.ref_term;
    ctx_res.has_active_command = true;
}

fn clear_active_command(ctx_res: *JsContext) void {
    ctx_res.callback_mutex.lock();
    defer ctx_res.callback_mutex.unlock();

    ctx_res.has_active_command = false;
    ctx_res.active_ref_env = null;
    ctx_res.active_ref_term = .{ .v = undefined };
}

fn process_is_alive(pid: beam.pid) bool {
    const check_env = e.enif_alloc_env() orelse return true;
    defer e.enif_free_env(check_env);

    var local_pid = pid;
    return e.enif_is_process_alive(check_env, &local_pid) != 0;
}

fn set_callback_abort_locked(ctx_res: *JsContext, reason: CallbackAbortReason) void {
    if (reason == .none) return;

    if (ctx_res.callback_result_env) |result_env| {
        e.enif_free_env(result_env);
    }

    ctx_res.callback_result_env = null;
    ctx_res.callback_result = .{ .v = undefined };
    ctx_res.callback_result_ready = false;
    ctx_res.callback_abort_reason = reason;
    ctx_res.callback_condvar.signal();
}

fn request_context_shutdown(ctx_res: *JsContext, reason: CallbackAbortReason) void {
    ctx_res.queue_mutex.lock();
    mark_context_shutting_down(ctx_res);
    ctx_res.queue_condvar.signal();
    ctx_res.queue_mutex.unlock();

    ctx_res.callback_mutex.lock();
    set_callback_abort_locked(ctx_res, reason);
    ctx_res.callback_mutex.unlock();
}

const CallbackEntry = struct {
    name: [:0]u8,
    ctx_res: *JsContext,
};

const AsyncEntry = struct {
    req_id: u64,
    resolve: Value,
    reject: Value,
    next: ?*AsyncEntry = null,
};

const AsyncResolution = struct {
    req_id: u64,
    result_env: beam.env,
    result: beam.term,
    next: ?*AsyncResolution = null,
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

fn destroy_async_entry(ctx: *Context, entry: *AsyncEntry) void {
    entry.resolve.deinit(ctx);
    entry.reject.deinit(ctx);
    beam.allocator.destroy(entry);
}

fn destroy_async_resolution(resolution: *AsyncResolution) void {
    if (resolution.result_env) |result_env| {
        e.enif_free_env(result_env);
    }

    beam.allocator.destroy(resolution);
}

fn clear_async_entries(ctx_res: *JsContext, ctx: *Context) void {
    ctx_res.callback_mutex.lock();
    var entry = async_entry_ptr(ctx_res.async_entries_head_ptr);
    ctx_res.async_entries_head_ptr = 0;
    ctx_res.async_entries_count = 0;
    ctx_res.callback_mutex.unlock();

    while (entry) |current| {
        const next = current.next;
        destroy_async_entry(ctx, current);
        entry = next;
    }
}

fn clear_async_resolutions(ctx_res: *JsContext) void {
    ctx_res.callback_mutex.lock();
    var resolution = async_resolution_ptr(ctx_res.async_resolution_head_ptr);
    ctx_res.async_resolution_head_ptr = 0;
    ctx_res.async_resolution_tail_ptr = 0;
    ctx_res.callback_mutex.unlock();

    while (resolution) |current| {
        const next = current.next;
        destroy_async_resolution(current);
        resolution = next;
    }
}

fn async_entry_count(ctx_res: *JsContext) usize {
    ctx_res.callback_mutex.lock();
    defer ctx_res.callback_mutex.unlock();

    return ctx_res.async_entries_count;
}

fn insert_async_entry_locked(ctx_res: *JsContext, entry: *AsyncEntry) void {
    entry.next = async_entry_ptr(ctx_res.async_entries_head_ptr);
    ctx_res.async_entries_head_ptr = async_entry_raw(entry);
    ctx_res.async_entries_count += 1;
}

fn remove_async_entry(ctx_res: *JsContext, req_id: u64) ?*AsyncEntry {
    ctx_res.callback_mutex.lock();
    defer ctx_res.callback_mutex.unlock();

    var previous: ?*AsyncEntry = null;
    var current = async_entry_ptr(ctx_res.async_entries_head_ptr);

    while (current) |entry| {
        if (entry.req_id == req_id) {
            if (previous) |prev| {
                prev.next = entry.next;
            } else {
                ctx_res.async_entries_head_ptr = async_entry_raw(entry.next);
            }

            entry.next = null;
            ctx_res.async_entries_count -= 1;
            return entry;
        }

        previous = entry;
        current = entry.next;
    }

    return null;
}

fn append_async_resolution_locked(ctx_res: *JsContext, resolution: *AsyncResolution) void {
    resolution.next = null;

    if (async_resolution_ptr(ctx_res.async_resolution_tail_ptr)) |tail| {
        tail.next = resolution;
    } else {
        ctx_res.async_resolution_head_ptr = async_resolution_raw(resolution);
    }

    ctx_res.async_resolution_tail_ptr = async_resolution_raw(resolution);
    ctx_res.callback_condvar.signal();
}

fn pop_async_resolution(ctx_res: *JsContext) ?*AsyncResolution {
    ctx_res.callback_mutex.lock();
    defer ctx_res.callback_mutex.unlock();

    const resolution = async_resolution_ptr(ctx_res.async_resolution_head_ptr) orelse return null;
    ctx_res.async_resolution_head_ptr = async_resolution_raw(resolution.next);
    if (ctx_res.async_resolution_head_ptr == 0) {
        ctx_res.async_resolution_tail_ptr = 0;
    }
    resolution.next = null;
    return resolution;
}

fn callback_dispatch_fn(raw_ctx: ?*Context, _this: Value, argv: []const c.JSValue, _magic: c_int, entry: ?*CallbackEntry) Value {
    _ = _this;
    _ = _magic;

    const ctx = raw_ctx orelse return Value.exception;
    const callback_entry = entry orelse return ctx.throwTypeError("callback dispatch missing entry");
    const ctx_res = callback_entry.ctx_res;

    if (context_is_poisoned(ctx_res)) {
        return ctx.throwTypeError("javascript context poisoned");
    }

    const msg_env = e.enif_alloc_env() orelse {
        return ctx.throwTypeError("failed to allocate callback env");
    };
    defer e.enif_free_env(msg_env);

    const snapshot = active_command_snapshot(ctx_res, msg_env) orelse {
        return ctx.throwTypeError("callback invoked without active command");
    };

    const wait_started = std.time.milliTimestamp();

    var caller_pid = snapshot.caller_pid;

    if (!process_is_alive(caller_pid)) {
        request_context_shutdown(ctx_res, .owner_down);
        return ctx.throwTypeError("callback caller unavailable");
    }

    var args = beam.allocator.alloc(beam.term, argv.len) catch {
        return ctx.throwTypeError("failed to allocate callback args");
    };
    defer beam.allocator.free(args);

    for (argv, 0..) |arg_raw, index| {
        const arg_value: Value = @bitCast(arg_raw);
        args[index] = js_to_erl(msg_env, ctx, arg_value, 0) catch {
            return ctx.throwTypeError("failed to convert callback argument");
        };
    }

    const args_list = beam.make(args, .{ .env = msg_env });

    ctx_res.callback_mutex.lock();
    ctx_res.callback_req_id += 1;
    const req_id = ctx_res.callback_req_id;
    ctx_res.callback_result_ready = false;
    ctx_res.callback_abort_reason = .none;
    if (ctx_res.callback_result_env) |previous_env| {
        e.enif_free_env(previous_env);
    }
    ctx_res.callback_result_env = null;
    ctx_res.callback_result = .{ .v = undefined };
    ctx_res.callback_mutex.unlock();

    const message = beam.make(.{
        .quickjs_ex_callback,
        snapshot.ref_term,
        req_id,
        callback_entry.name[0..callback_entry.name.len],
        args_list,
    }, .{ .env = msg_env });

    if (e.enif_send(null, &caller_pid, msg_env, message.v) == 0) {
        mark_context_poisoned(ctx_res);
        return ctx.throwTypeError("callback caller unavailable");
    }

    ctx_res.callback_mutex.lock();
    while (!ctx_res.callback_result_ready and ctx_res.callback_abort_reason == .none) {
        ctx_res.callback_condvar.timedWait(&ctx_res.callback_mutex, CALLBACK_OWNER_CHECK_NS) catch {
            if (!process_is_alive(caller_pid)) {
                ctx_res.callback_mutex.unlock();
                request_context_shutdown(ctx_res, .owner_down);
                ctx_res.callback_mutex.lock();
                continue;
            }

            if (context_is_shutting_down(ctx_res)) {
                set_callback_abort_locked(ctx_res, .shutdown);
            }
        };
    }

    if (ctx_res.callback_abort_reason != .none) {
        const abort_reason = ctx_res.callback_abort_reason;
        ctx_res.callback_mutex.unlock();

        return switch (abort_reason) {
            .owner_down => ctx.throwTypeError("callback caller unavailable"),
            .shutdown => ctx.throwTypeError("javascript context stopped"),
            .none => unreachable,
        };
    }

    const callback_result = ctx_res.callback_result;
    const callback_result_env = ctx_res.callback_result_env;
    ctx_res.callback_result = .{ .v = undefined };
    ctx_res.callback_result_env = null;
    ctx_res.callback_result_ready = false;
    ctx_res.callback_mutex.unlock();

    const wait_finished = std.time.milliTimestamp();
    if (ctx_res.deadline_ms > 0 and wait_started > 0 and wait_finished > wait_started) {
        const waited_ms: u64 = @intCast(wait_finished - wait_started);
        ctx_res.deadline_ms +|= waited_ms;
    }

    const result_env = callback_result_env orelse {
        return ctx.throwTypeError("callback result env missing");
    };
    defer e.enif_free_env(result_env);

    const parse_env = e.enif_alloc_env() orelse {
        return ctx.throwTypeError("failed to allocate callback parse env");
    };
    defer e.enif_free_env(parse_env);

    const local_result = beam.term{
        .v = e.enif_make_copy(parse_env, callback_result.v),
    };

    var response_arity: c_int = 0;
    var response_items: [*c]const e.ErlNifTerm = undefined;
    if (e.enif_get_tuple(parse_env, local_result.v, &response_arity, @ptrCast(&response_items)) == 0 or response_arity != 2) {
        return ctx.throwTypeError("invalid callback response");
    }

    const status_term = beam.term{ .v = response_items[0] };
    const payload_term = beam.term{ .v = response_items[1] };

    if (term_is_atom(parse_env, status_term, "ok")) {
        return erl_to_js(parse_env, ctx, payload_term, 0) catch {
            return ctx.throwTypeError("failed to encode callback result");
        };
    }

    if (term_is_atom(parse_env, status_term, "error")) {
        var error_arity: c_int = 0;
        var error_items: [*c]const e.ErlNifTerm = undefined;
        if (e.enif_get_tuple(parse_env, payload_term.v, &error_arity, @ptrCast(&error_items)) == 0 or error_arity != 3) {
            return ctx.throwTypeError("invalid callback error");
        }

        const error_tag = beam.term{ .v = error_items[0] };
        if (!term_is_atom(parse_env, error_tag, "cb")) {
            return ctx.throwTypeError("invalid callback error tag");
        }

        const message_term = beam.term{ .v = error_items[2] };
        const callback_message = beam.get([]const u8, message_term, .{ .env = parse_env }) catch "callback failed";

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

fn async_dispatch_fn(raw_ctx: ?*Context, _this: Value, argv: []const c.JSValue, _magic: c_int, entry: ?*CallbackEntry) Value {
    _ = _this;
    _ = _magic;

    const ctx = raw_ctx orelse return Value.exception;
    const async_entry_info = entry orelse return ctx.throwTypeError("async dispatch missing entry");
    const ctx_res = async_entry_info.ctx_res;

    if (context_is_poisoned(ctx_res)) {
        return ctx.throwTypeError("javascript context poisoned");
    }

    const msg_env = e.enif_alloc_env() orelse {
        return ctx.throwTypeError("failed to allocate async callback env");
    };
    defer e.enif_free_env(msg_env);

    const snapshot = active_command_snapshot(ctx_res, msg_env) orelse {
        return ctx.throwTypeError("async callback invoked without active command");
    };

    var caller_pid = snapshot.caller_pid;

    if (!process_is_alive(caller_pid)) {
        request_context_shutdown(ctx_res, .owner_down);
        return ctx.throwTypeError("async callback caller unavailable");
    }

    var args = beam.allocator.alloc(beam.term, argv.len) catch {
        return ctx.throwTypeError("failed to allocate async callback args");
    };
    defer beam.allocator.free(args);

    for (argv, 0..) |arg_raw, index| {
        const arg_value: Value = @bitCast(arg_raw);
        args[index] = js_to_erl(msg_env, ctx, arg_value, 0) catch {
            return ctx.throwTypeError("failed to convert async callback argument");
        };
    }

    const promise: Value.Promise = Value.initPromiseCapability(ctx);
    if (promise.value.isException()) {
        return ctx.throwTypeError("failed to create async promise");
    }

    const pending = beam.allocator.create(AsyncEntry) catch {
        promise.value.deinit(ctx);
        promise.resolve.deinit(ctx);
        promise.reject.deinit(ctx);
        return ctx.throwTypeError("failed to allocate async promise entry");
    };

    ctx_res.callback_mutex.lock();
    if (ctx_res.callback_abort_reason != .none or context_is_shutting_down(ctx_res)) {
        ctx_res.callback_mutex.unlock();
        beam.allocator.destroy(pending);
        promise.value.deinit(ctx);
        promise.resolve.deinit(ctx);
        promise.reject.deinit(ctx);
        return ctx.throwTypeError("javascript context stopped");
    }

    if (ctx_res.async_entries_count >= MAX_PENDING_ASYNC_CALLBACKS) {
        ctx_res.callback_mutex.unlock();
        beam.allocator.destroy(pending);
        return reject_promise(ctx, promise, "maximum pending async callbacks exceeded");
    }

    ctx_res.callback_req_id += 1;
    const req_id = ctx_res.callback_req_id;
    pending.* = .{
        .req_id = req_id,
        .resolve = promise.resolve,
        .reject = promise.reject,
    };
    insert_async_entry_locked(ctx_res, pending);
    ctx_res.callback_mutex.unlock();

    const args_list = beam.make(args, .{ .env = msg_env });
    const message = beam.make(.{
        .quickjs_ex_async_request,
        snapshot.ref_term,
        req_id,
        async_entry_info.name[0..async_entry_info.name.len],
        args_list,
    }, .{ .env = msg_env });

    if (e.enif_send(null, &caller_pid, msg_env, message.v) == 0) {
        if (remove_async_entry(ctx_res, req_id)) |removed| {
            destroy_async_entry(ctx, removed);
        }
        promise.value.deinit(ctx);
        request_context_shutdown(ctx_res, .owner_down);
        return ctx.throwTypeError("async callback caller unavailable");
    }

    return promise.value;
}

fn module_def_from_value(value: Value) ?*ModuleDef {
    if (!value.isModule()) return null;
    if (Value.is_nan_boxed) {
        return @ptrCast(@alignCast(c.JS_VALUE_GET_PTR(value.cval())));
    }
    return @ptrCast(@alignCast(value.u.ptr));
}

fn module_loader_fn(raw_ctx_res: ?*JsContext, ctx: *Context, module_name: [:0]const u8) ?*ModuleDef {
    const ctx_res = raw_ctx_res orelse {
        _ = ctx.throwTypeError("module loader missing context");
        return null;
    };

    if (context_is_poisoned(ctx_res)) {
        ctx_res.module_load_error = true;
        _ = ctx.throwTypeError("javascript context poisoned");
        return null;
    }

    const msg_env = e.enif_alloc_env() orelse {
        ctx_res.module_load_error = true;
        _ = ctx.throwTypeError("failed to allocate module loader env");
        return null;
    };
    defer e.enif_free_env(msg_env);

    const wait_started = std.time.milliTimestamp();

    const snapshot = active_command_snapshot(ctx_res, msg_env) orelse {
        ctx_res.module_load_error = true;
        _ = ctx.throwTypeError("module loader invoked without active command");
        return null;
    };

    var caller_pid = snapshot.caller_pid;

    if (!process_is_alive(caller_pid)) {
        request_context_shutdown(ctx_res, .owner_down);
        ctx_res.module_load_error = true;
        _ = ctx.throwTypeError("module loader caller unavailable");
        return null;
    }

    ctx_res.callback_mutex.lock();
    ctx_res.callback_req_id += 1;
    const req_id = ctx_res.callback_req_id;
    ctx_res.callback_result_ready = false;
    ctx_res.callback_abort_reason = .none;
    if (ctx_res.callback_result_env) |previous_env| {
        e.enif_free_env(previous_env);
    }
    ctx_res.callback_result_env = null;
    ctx_res.callback_result = .{ .v = undefined };
    ctx_res.callback_mutex.unlock();

    const request_message = beam.make(.{
        .quickjs_ex_module_request,
        snapshot.ref_term,
        req_id,
        module_name[0..module_name.len],
    }, .{ .env = msg_env });

    if (e.enif_send(null, &caller_pid, msg_env, request_message.v) == 0) {
        ctx_res.module_load_error = true;
        request_context_shutdown(ctx_res, .owner_down);
        _ = ctx.throwTypeError("module loader caller unavailable");
        return null;
    }

    ctx_res.callback_mutex.lock();
    while (!ctx_res.callback_result_ready and ctx_res.callback_abort_reason == .none) {
        ctx_res.callback_condvar.timedWait(&ctx_res.callback_mutex, CALLBACK_OWNER_CHECK_NS) catch {
            if (!process_is_alive(caller_pid)) {
                ctx_res.callback_mutex.unlock();
                request_context_shutdown(ctx_res, .owner_down);
                ctx_res.callback_mutex.lock();
                continue;
            }

            if (context_is_shutting_down(ctx_res)) {
                set_callback_abort_locked(ctx_res, .shutdown);
            }
        };
    }

    if (ctx_res.callback_abort_reason != .none) {
        const abort_reason = ctx_res.callback_abort_reason;
        ctx_res.callback_mutex.unlock();

        ctx_res.module_load_error = true;
        _ = switch (abort_reason) {
            .owner_down => ctx.throwTypeError("module loader caller unavailable"),
            .shutdown => ctx.throwTypeError("javascript context stopped"),
            .none => unreachable,
        };
        return null;
    }

    const loader_result = ctx_res.callback_result;
    const loader_result_env = ctx_res.callback_result_env;
    ctx_res.callback_result = .{ .v = undefined };
    ctx_res.callback_result_env = null;
    ctx_res.callback_result_ready = false;
    ctx_res.callback_mutex.unlock();

    const wait_finished = std.time.milliTimestamp();
    if (ctx_res.deadline_ms > 0 and wait_started > 0 and wait_finished > wait_started) {
        const waited_ms: u64 = @intCast(wait_finished - wait_started);
        ctx_res.deadline_ms +|= waited_ms;
    }

    const result_env = loader_result_env orelse {
        ctx_res.module_load_error = true;
        _ = ctx.throwTypeError("module loader result env missing");
        return null;
    };
    defer e.enif_free_env(result_env);

    var response_arity: c_int = 0;
    var response_items: [*c]const e.ErlNifTerm = undefined;
    if (e.enif_get_tuple(result_env, loader_result.v, &response_arity, @ptrCast(&response_items)) == 0 or response_arity != 2) {
        ctx_res.module_load_error = true;
        _ = ctx.throwTypeError("invalid module loader response");
        return null;
    }

    const status_term = beam.term{ .v = response_items[0] };
    const payload_term = beam.term{ .v = response_items[1] };

    if (term_is_atom(result_env, status_term, "error")) {
        ctx_res.module_load_error = true;
        const error_message = beam.get([]const u8, payload_term, .{ .env = result_env }) catch "module load failed";
        _ = throw_type_error(ctx, error_message);
        return null;
    }

    if (!term_is_atom(result_env, status_term, "ok")) {
        ctx_res.module_load_error = true;
        _ = ctx.throwTypeError("invalid module loader response");
        return null;
    }

    const source = beam.get([]const u8, payload_term, .{ .env = result_env }) catch {
        ctx_res.module_load_error = true;
        _ = ctx.throwTypeError("module loader source must be a string");
        return null;
    };

    // Match top-level eval: keep a sentinel byte after the source for parser paths.
    const source_z = alloc_z_string(source) catch {
        ctx_res.module_load_error = true;
        _ = ctx.throwOutOfMemory();
        return null;
    };
    defer beam.allocator.free(source_z);

    const module_value = ctx.eval(source_z, module_name, .{ .type = .module, .compile_only = true });
    if (module_value.isException()) {
        ctx_res.module_load_error = true;
        return null;
    }

    return module_def_from_value(module_value) orelse {
        module_value.deinit(ctx);
        ctx_res.module_load_error = true;
        _ = ctx.throwTypeError("module loader source did not compile to a module");
        return null;
    };
}

const JsContextCallbacks = struct {
    pub fn dtor(ctx_res: *JsContext) void {
        shutdown_context_thread(ctx_res);

        if (ctx_res.callback_result_env) |result_env| {
            e.enif_free_env(result_env);
            ctx_res.callback_result_env = null;
        }

        if (ctx_res.callback_error_env) |error_env| {
            e.enif_free_env(error_env);
            ctx_res.callback_error_env = null;
            ctx_res.callback_error = null;
        }

        clear_async_resolutions(ctx_res);
    }
};

pub const JsContextResource = beam.Resource(JsContext, @import("root"), .{
    .Callbacks = JsContextCallbacks,
});

fn set_thread_beam_env(env: beam.env) void {
    beam.context = .{
        .mode = .threaded,
        .env = env,
        .allocator = beam.allocator,
    };
}

fn signal_init(ctx_res: *JsContext, ok: bool) void {
    ctx_res.init_mutex.lock();
    ctx_res.init_done = true;
    ctx_res.init_ok = ok;
    ctx_res.init_condvar.signal();
    ctx_res.init_mutex.unlock();
}

fn context_thread_stack_kilowords(stack_limit_bytes: u64) c_int {
    const desired_stack_bytes = if (stack_limit_bytes == 0)
        CONTEXT_THREAD_MIN_STACK_BYTES
    else
        @max(CONTEXT_THREAD_MIN_STACK_BYTES, stack_limit_bytes +| CONTEXT_THREAD_STACK_HEADROOM_BYTES);
    // ErlNifThreadOpts.suggested_stack_size is measured in kilowords.
    const bytes_per_kiloword = @as(u64, @sizeOf(usize) * 1024);
    const kilowords = (desired_stack_bytes + bytes_per_kiloword - 1) / bytes_per_kiloword;

    if (kilowords > @as(u64, @intCast(std.math.maxInt(c_int)))) {
        return std.math.maxInt(c_int);
    }

    return @intCast(kilowords);
}

fn context_thread_main(raw_ctx: ?*anyopaque) callconv(.c) ?*anyopaque {
    const ctx_res: *JsContext = @ptrCast(@alignCast(raw_ctx.?));
    set_thread_beam_env(null);

    const runtime = Runtime.init() catch {
        signal_init(ctx_res, false);
        return null;
    };
    ctx_res.runtime_ptr = @intFromPtr(runtime);

    if (ctx_res.memory_limit_bytes > 0) {
        runtime.setMemoryLimit(ctx_res.memory_limit_bytes);
    }

    if (ctx_res.stack_limit_bytes > 0) {
        runtime.setMaxStackSize(ctx_res.stack_limit_bytes);
    }

    runtime.updateStackTop();

    const context = Context.init(runtime) catch {
        runtime.deinit();
        ctx_res.runtime_ptr = 0;
        signal_init(ctx_res, false);
        return null;
    };
    ctx_res.context_ptr = @intFromPtr(context);

    runtime.setInterruptHandler(JsContext, ctx_res, interrupt_handler);
    context.setOpaque(JsContext, ctx_res);
    runtime.setModuleLoaderFunc(JsContext, ctx_res, null, module_loader_fn);

    signal_init(ctx_res, true);

    while (dequeue_command(ctx_res)) |cmd| {
        if (cmd.kind == .stop) {
            destroy_command(cmd);
            break;
        }

        execute_command(ctx_res, cmd);
        destroy_command(cmd);

        ctx_res.queue_mutex.lock();
        const should_stop = context_is_shutting_down(ctx_res);
        ctx_res.queue_mutex.unlock();

        if (should_stop) break;
    }

    drain_command_queue(ctx_res);

    if (ctx_res.context_ptr != 0) {
        clear_async_entries(ctx_res, context_ptr(ctx_res));
        clear_async_resolutions(ctx_res);
        context_ptr(ctx_res).deinit();
        ctx_res.context_ptr = 0;
    } else {
        clear_async_resolutions(ctx_res);
    }

    if (ctx_res.runtime_ptr != 0) {
        runtime_ptr(ctx_res).deinit();
        ctx_res.runtime_ptr = 0;
    }

    return null;
}

fn dequeue_command(ctx_res: *JsContext) ?*Command {
    ctx_res.queue_mutex.lock();
    defer ctx_res.queue_mutex.unlock();

    while (ctx_res.queue_head_ptr == 0 and !context_is_shutting_down(ctx_res)) {
        ctx_res.queue_condvar.timedWait(&ctx_res.queue_mutex, CALLBACK_OWNER_CHECK_NS) catch {
            ctx_res.queue_mutex.unlock();
            const owner_alive = process_is_alive(ctx_res.owner_pid);
            ctx_res.queue_mutex.lock();

            if (!owner_alive) {
                mark_context_shutting_down(ctx_res);
                ctx_res.queue_condvar.signal();
            }
        };
    }

    const cmd = command_ptr(ctx_res.queue_head_ptr) orelse return null;
    ctx_res.queue_head_ptr = command_raw(cmd.next);
    if (ctx_res.queue_head_ptr == 0) {
        ctx_res.queue_tail_ptr = 0;
    }
    cmd.next = null;
    return cmd;
}

fn drain_command_queue(ctx_res: *JsContext) void {
    ctx_res.queue_mutex.lock();
    var cmd = command_ptr(ctx_res.queue_head_ptr);
    ctx_res.queue_head_ptr = 0;
    ctx_res.queue_tail_ptr = 0;
    ctx_res.queue_mutex.unlock();

    while (cmd) |current| {
        const next = current.next;
        send_command_error(current, .poisoned);
        destroy_command(current);
        cmd = next;
    }
}

fn shutdown_context_thread(ctx_res: *JsContext) void {
    ctx_res.queue_mutex.lock();
    const should_join = ctx_res.thread_started and !ctx_res.thread_joined;
    ctx_res.queue_mutex.unlock();

    request_context_shutdown(ctx_res, .shutdown);

    if (should_join) {
        var result: ?*anyopaque = null;
        _ = e.enif_thread_join(ctx_res.thread, &result);
        ctx_res.thread_joined = true;
    }
}

fn destroy_command(cmd: *Command) void {
    if (cmd.code) |code| {
        beam.allocator.free(code);
    }

    if (cmd.name) |name| {
        beam.allocator.free(name);
    }

    if (cmd.path) |path| {
        for (path) |segment| {
            beam.allocator.free(segment);
        }
        beam.allocator.free(path);
    }

    if (cmd.term_env) |term_env| {
        e.enif_free_env(term_env);
    }

    if (cmd.ref_env) |ref_env| {
        e.enif_free_env(ref_env);
    }

    beam.allocator.destroy(cmd);
}

fn mark_command_complete(cmd: *Command) void {
    const ctx_res = command_context_ptr(cmd) orelse return;

    clear_active_command(ctx_res);

    ctx_res.queue_mutex.lock();
    ctx_res.busy = false;
    ctx_res.queue_mutex.unlock();
}

fn send_reply(cmd: *Command, reply_env: beam.env, response: beam.term) void {
    const ref_copy = beam.term{
        .v = e.enif_make_copy(reply_env, cmd.ref_term.v),
    };

    const message = beam.make(.{
        .quickjs_ex_result,
        ref_copy,
        response,
    }, .{ .env = reply_env });

    var caller_pid = cmd.caller_pid;
    mark_command_complete(cmd);
    _ = e.enif_send(null, &caller_pid, reply_env, message.v);
    e.enif_free_env(reply_env);
}

fn send_command_error(cmd: *Command, err: anytype) void {
    const reply_env = e.enif_alloc_env() orelse return;
    set_thread_beam_env(reply_env);
    send_reply(cmd, reply_env, beam.make(.{ .@"error", err }, .{ .env = reply_env }));
}

fn execute_command(ctx_res: *JsContext, cmd: *Command) void {
    switch (cmd.kind) {
        .eval => execute_eval(ctx_res, cmd),
        .get => execute_get(ctx_res, cmd),
        .get_gas => execute_get_gas(ctx_res, cmd),
        .set_value => execute_set_value(ctx_res, cmd),
        .set_path => execute_set_path(ctx_res, cmd),
        .gc => execute_gc(ctx_res, cmd),
        .register_callback => execute_register_callback(ctx_res, cmd),
        .register_async_callback => execute_register_async_callback(ctx_res, cmd),
        .stop => {},
    }
}

fn prepare_reply_env() ?beam.env {
    const reply_env = e.enif_alloc_env() orelse return null;
    set_thread_beam_env(reply_env);
    return reply_env;
}

fn set_eval_deadline(ctx_res: *JsContext, timeout_ms: u64) void {
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
}

const PendingJobDrain = union(enum) {
    drained,
    exception: *Context,
};

const RootPromiseResult = union(enum) {
    fulfilled: Value,
    rejected: Value,
    unsettled,
    job_exception: *Context,
};

const ExternalWaitResult = union(enum) {
    progressed,
    no_progress,
    aborted: *Context,
};

fn outstanding_external_resolution_count(ctx_res: *JsContext) usize {
    return async_entry_count(ctx_res);
}

fn reject_async_entry(ctx: *Context, entry: *AsyncEntry, message: []const u8) void {
    const rejection = Value.initStringLen(ctx, message);
    defer rejection.deinit(ctx);

    const call_result = entry.reject.call(ctx, Value.undefined, &.{rejection});
    defer call_result.deinit(ctx);
}

fn reject_promise(ctx: *Context, promise: Value.Promise, message: []const u8) Value {
    const rejection = Value.initStringLen(ctx, message);
    if (rejection.isException()) {
        promise.value.deinit(ctx);
        promise.resolve.deinit(ctx);
        promise.reject.deinit(ctx);
        return ctx.throwOutOfMemory();
    }
    defer rejection.deinit(ctx);

    const call_result = promise.reject.call(ctx, Value.undefined, &.{rejection});
    defer call_result.deinit(ctx);

    promise.resolve.deinit(ctx);
    promise.reject.deinit(ctx);
    return promise.value;
}

fn apply_async_resolution(ctx_res: *JsContext, ctx: *Context, resolution: *AsyncResolution) void {
    const entry = remove_async_entry(ctx_res, resolution.req_id) orelse return;
    defer destroy_async_entry(ctx, entry);

    const result_env = resolution.result_env orelse {
        reject_async_entry(ctx, entry, "async callback result env missing");
        return;
    };

    var response_arity: c_int = 0;
    var response_items: [*c]const e.ErlNifTerm = undefined;
    if (e.enif_get_tuple(result_env, resolution.result.v, &response_arity, @ptrCast(&response_items)) == 0 or response_arity != 2) {
        reject_async_entry(ctx, entry, "invalid async callback response");
        return;
    }

    const status_term = beam.term{ .v = response_items[0] };
    const payload_term = beam.term{ .v = response_items[1] };

    if (term_is_atom(result_env, status_term, "ok")) {
        const js_value = erl_to_js(result_env, ctx, payload_term, 0) catch {
            reject_async_entry(ctx, entry, "failed to encode async callback result");
            return;
        };
        defer js_value.deinit(ctx);

        const call_result = entry.resolve.call(ctx, Value.undefined, &.{js_value});
        defer call_result.deinit(ctx);
        return;
    }

    if (term_is_atom(result_env, status_term, "error")) {
        const message = beam.get([]const u8, payload_term, .{ .env = result_env }) catch "async callback failed";
        reject_async_entry(ctx, entry, message);
        return;
    }

    reject_async_entry(ctx, entry, "invalid async callback response");
}

fn wait_for_external_resolution(ctx_res: *JsContext, ctx: *Context) ExternalWaitResult {
    if (pop_async_resolution(ctx_res)) |resolution| {
        defer destroy_async_resolution(resolution);
        apply_async_resolution(ctx_res, ctx, resolution);
        return .progressed;
    }

    const wait_started = std.time.milliTimestamp();
    const caller_pid = active_command_caller(ctx_res) orelse std.mem.zeroes(beam.pid);

    ctx_res.callback_mutex.lock();
    while (ctx_res.async_resolution_head_ptr == 0 and
        ctx_res.async_entries_head_ptr != 0 and
        ctx_res.callback_abort_reason == .none and
        !context_is_shutting_down(ctx_res))
    {
        ctx_res.callback_condvar.timedWait(&ctx_res.callback_mutex, CALLBACK_OWNER_CHECK_NS) catch {
            ctx_res.callback_mutex.unlock();
            const owner_alive = process_is_alive(caller_pid);
            ctx_res.callback_mutex.lock();

            if (!owner_alive) {
                ctx_res.callback_mutex.unlock();
                request_context_shutdown(ctx_res, .owner_down);
                ctx_res.callback_mutex.lock();
                continue;
            }

            if (context_is_shutting_down(ctx_res)) {
                set_callback_abort_locked(ctx_res, .shutdown);
            }
        };
    }

    if (ctx_res.callback_abort_reason != .none or context_is_shutting_down(ctx_res)) {
        const abort_reason = ctx_res.callback_abort_reason;
        ctx_res.callback_mutex.unlock();

        _ = switch (abort_reason) {
            .owner_down => throw_type_error(ctx, "async callback caller unavailable"),
            .shutdown, .none => throw_type_error(ctx, "javascript context stopped"),
        };

        return .{ .aborted = ctx };
    }

    if (ctx_res.async_entries_head_ptr == 0 and ctx_res.async_resolution_head_ptr == 0) {
        ctx_res.callback_mutex.unlock();
        return .no_progress;
    }

    ctx_res.callback_mutex.unlock();

    const wait_finished = std.time.milliTimestamp();
    if (ctx_res.deadline_ms > 0 and wait_started > 0 and wait_finished > wait_started) {
        const waited_ms: u64 = @intCast(wait_finished - wait_started);
        ctx_res.deadline_ms +|= waited_ms;
    }

    if (pop_async_resolution(ctx_res)) |resolution| {
        defer destroy_async_resolution(resolution);
        apply_async_resolution(ctx_res, ctx, resolution);
        return .progressed;
    }

    return .no_progress;
}

fn drain_pending_jobs(ctx_res: *JsContext) PendingJobDrain {
    const rt = runtime_ptr(ctx_res);

    while (rt.isJobPending()) {
        var job_ctx_raw: ?*c.JSContext = null;
        const status = c.JS_ExecutePendingJob(rt.cval(), &job_ctx_raw);

        if (status < 0) {
            const job_ctx: *Context = if (job_ctx_raw) |raw|
                @ptrCast(raw)
            else
                context_ptr(ctx_res);

            return .{ .exception = job_ctx };
        }

        if (status == 0) return .drained;
    }

    return .drained;
}

fn settle_root_promise(ctx_res: *JsContext, ctx: *Context, root: Value) RootPromiseResult {
    while (true) {
        switch (drain_pending_jobs(ctx_res)) {
            .drained => {},
            .exception => |job_ctx| return .{ .job_exception = job_ctx },
        }

        switch (root.promiseState(ctx)) {
            .fulfilled => return .{ .fulfilled = root.promiseResult(ctx) },
            .rejected => return .{ .rejected = root.promiseResult(ctx) },
            .pending => {
                const jobs_pending = runtime_ptr(ctx_res).isJobPending();
                const externals_pending = outstanding_external_resolution_count(ctx_res) > 0;

                if (jobs_pending) continue;
                if (!externals_pending) return .unsettled;

                switch (wait_for_external_resolution(ctx_res, ctx)) {
                    .progressed => continue,
                    .no_progress => return .unsettled,
                    .aborted => |job_ctx| return .{ .job_exception = job_ctx },
                }
            },
            .not_a_promise => return .unsettled,
        }
    }
}

fn take_callback_error(ctx_res: *JsContext, reply_env: beam.env) ?beam.term {
    if (ctx_res.callback_error) |callback_error| {
        const copied_callback_error = beam.term{
            .v = e.enif_make_copy(reply_env, callback_error.v),
        };

        if (ctx_res.callback_error_env) |error_env| {
            e.enif_free_env(error_env);
            ctx_res.callback_error_env = null;
        }
        ctx_res.callback_error = null;

        return copied_callback_error;
    }

    return null;
}

fn send_eval_exception_reply(ctx_res: *JsContext, cmd: *Command, reply_env: beam.env, ctx: *Context, exc: Value) void {
    if (ctx_res.was_interrupted) {
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .timeout }, .{ .env = reply_env }));
        return;
    }

    if (take_callback_error(ctx_res, reply_env)) |callback_error| {
        send_reply(cmd, reply_env, callback_error);
        return;
    }

    if (ctx_res.module_load_error) {
        ctx_res.module_load_error = false;
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .module_load }, .{ .env = reply_env }));
        return;
    }

    if (exception_is_oom(ctx, exc)) {
        mark_context_poisoned(ctx_res);
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .oom }, .{ .env = reply_env }));
        return;
    }

    send_reply(cmd, reply_env, js_error_from_exception(ctx, exc));
}

fn send_pending_job_exception_reply(ctx_res: *JsContext, cmd: *Command, reply_env: beam.env, job_ctx: *Context) void {
    if (!job_ctx.hasException()) {
        send_reply(cmd, reply_env, poison_internal_error(ctx_res));
        return;
    }

    const exc = job_ctx.getException();
    defer exc.deinit(job_ctx);

    send_eval_exception_reply(ctx_res, cmd, reply_env, job_ctx, exc);
}

fn send_eval_value_reply(ctx_res: *JsContext, cmd: *Command, reply_env: beam.env, ctx: *Context, value: Value) void {
    if (value.isFunction(ctx)) {
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .{ .js, "value of type 'function' is not serializable" } }, .{ .env = reply_env }));
        return;
    }

    const erl_term = js_to_erl(reply_env, ctx, value, 0) catch |err| {
        const response = switch (err) {
            error.MaxDepth => beam.make(.{ .@"error", .{ .js, "maximum depth exceeded" } }, .{ .env = reply_env }),
            error.MaxResultSize => beam.make(.{ .@"error", .{ .js, "maximum result size exceeded" } }, .{ .env = reply_env }),
            error.FunctionNotSerializable => beam.make(.{ .@"error", .{ .js, "value of type 'function' is not serializable" } }, .{ .env = reply_env }),
            error.JSError => current_js_error_with_poison(ctx_res, ctx),
            error.OutOfMemory => poison_internal_error(ctx_res),
        };
        send_reply(cmd, reply_env, response);
        return;
    };

    send_reply(cmd, reply_env, beam.make(.{ .ok, erl_term }, .{ .env = reply_env }));
}

fn execute_eval(ctx_res: *JsContext, cmd: *Command) void {
    const reply_env = prepare_reply_env() orelse return;
    const ctx = context_ptr(ctx_res);
    defer {
        clear_async_entries(ctx_res, ctx);
        clear_async_resolutions(ctx_res);
    }
    const code = cmd.code orelse {
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .internal_error }, .{ .env = reply_env }));
        return;
    };

    ctx_res.was_interrupted = false;
    ctx_res.module_load_error = false;
    set_eval_deadline(ctx_res, cmd.timeout_ms);
    defer ctx_res.deadline_ms = 0;

    set_active_command(ctx_res, cmd);
    defer clear_active_command(ctx_res);

    const gas_start = ctx_res.gas_quanta_total;
    defer {
        const gas_delta = ctx_res.gas_quanta_total - gas_start;
        ctx_res.gas_quanta_last = if (gas_delta == 0) 1 else gas_delta;
    }

    const eval_code = code[0 .. code.len - 1];
    const eval_flags: EvalFlags = if (cmd.eval_as_module)
        .{ .type = .module }
    else
        .{};
    const result = ctx.eval(eval_code, "<eval>", eval_flags);
    defer result.deinit(ctx);

    if (result.isException()) {
        const exc = ctx.getException();
        defer exc.deinit(ctx);

        send_eval_exception_reply(ctx_res, cmd, reply_env, ctx, exc);
        return;
    }

    switch (drain_pending_jobs(ctx_res)) {
        .drained => {},
        .exception => |job_ctx| {
            send_pending_job_exception_reply(ctx_res, cmd, reply_env, job_ctx);
            return;
        },
    }

    if (result.isPromise()) {
        switch (settle_root_promise(ctx_res, ctx, result)) {
            .fulfilled => |value| {
                defer value.deinit(ctx);
                send_eval_value_reply(ctx_res, cmd, reply_env, ctx, value);
            },
            .rejected => |reason| {
                defer reason.deinit(ctx);
                send_eval_exception_reply(ctx_res, cmd, reply_env, ctx, reason);
            },
            .unsettled => send_reply(cmd, reply_env, beam.make(.{ .@"error", .unsettled }, .{ .env = reply_env })),
            .job_exception => |job_ctx| send_pending_job_exception_reply(ctx_res, cmd, reply_env, job_ctx),
        }
        return;
    }

    send_eval_value_reply(ctx_res, cmd, reply_env, ctx, result);
}

fn execute_get_gas(ctx_res: *JsContext, cmd: *Command) void {
    const reply_env = prepare_reply_env() orelse return;
    const gas = beam.make(.{
        .last = ctx_res.gas_quanta_last,
        .total = ctx_res.gas_quanta_total,
        .quantum = INTERRUPT_GAS_QUANTUM,
    }, .{ .env = reply_env });

    send_reply(cmd, reply_env, beam.make(.{ .ok, gas }, .{ .env = reply_env }));
}

fn execute_get(ctx_res: *JsContext, cmd: *Command) void {
    const reply_env = prepare_reply_env() orelse return;
    const name = cmd.name orelse {
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .internal_error }, .{ .env = reply_env }));
        return;
    };
    const ctx = context_ptr(ctx_res);

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const prop = global.getPropertyStr(ctx, name);
    defer prop.deinit(ctx);

    if (prop.isException()) {
        send_reply(cmd, reply_env, current_js_error_with_poison(ctx_res, ctx));
        return;
    }

    const erl_term = js_to_erl(reply_env, ctx, prop, 0) catch |err| {
        const response = switch (err) {
            error.MaxDepth => beam.make(.{ .@"error", .{ .js, "maximum depth exceeded" } }, .{ .env = reply_env }),
            error.MaxResultSize => beam.make(.{ .@"error", .{ .js, "maximum result size exceeded" } }, .{ .env = reply_env }),
            error.FunctionNotSerializable => beam.make(.{ .@"error", .{ .js, "value of type 'function' is not serializable" } }, .{ .env = reply_env }),
            error.JSError => current_js_error_with_poison(ctx_res, ctx),
            error.OutOfMemory => poison_internal_error(ctx_res),
        };
        send_reply(cmd, reply_env, response);
        return;
    };

    send_reply(cmd, reply_env, beam.make(.{ .ok, erl_term }, .{ .env = reply_env }));
}

fn execute_set_value(ctx_res: *JsContext, cmd: *Command) void {
    const reply_env = prepare_reply_env() orelse return;
    const name = cmd.name orelse {
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .internal_error }, .{ .env = reply_env }));
        return;
    };
    const value_env = cmd.term_env orelse {
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .internal_error }, .{ .env = reply_env }));
        return;
    };
    const ctx = context_ptr(ctx_res);

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const js_val = erl_to_js(value_env, ctx, cmd.value_term, 0) catch |err| {
        send_reply(cmd, reply_env, erl_to_js_error_term(ctx_res, ctx, err));
        return;
    };

    global.setPropertyStr(ctx, name, js_val) catch {
        send_reply(cmd, reply_env, property_set_error_term(ctx_res, ctx));
        return;
    };

    send_reply(cmd, reply_env, beam.make(.ok, .{ .env = reply_env }));
}

fn execute_set_path(ctx_res: *JsContext, cmd: *Command) void {
    const reply_env = prepare_reply_env() orelse return;
    const path = cmd.path orelse {
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .internal_error }, .{ .env = reply_env }));
        return;
    };
    const value_env = cmd.term_env orelse {
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .internal_error }, .{ .env = reply_env }));
        return;
    };

    if (path.len < 1) {
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .{ .js, "path must not be empty" } }, .{ .env = reply_env }));
        return;
    }

    const ctx = context_ptr(ctx_res);
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    var current = global.dup(ctx);
    defer current.deinit(ctx);

    for (path[0 .. path.len - 1]) |segment| {
        var child = current.getPropertyStr(ctx, segment);

        if (child.isException()) {
            child.deinit(ctx);
            send_reply(cmd, reply_env, current_js_error_with_poison(ctx_res, ctx));
            return;
        }

        if (child.isNull() or child.isUndefined()) {
            child.deinit(ctx);

            const new_obj = Value.initObject(ctx);
            if (new_obj.isException()) {
                send_reply(cmd, reply_env, current_js_error_with_poison(ctx_res, ctx));
                return;
            }

            current.setPropertyStr(ctx, segment, new_obj) catch {
                send_reply(cmd, reply_env, property_set_error_term(ctx_res, ctx));
                return;
            };

            child = current.getPropertyStr(ctx, segment);
            if (child.isException()) {
                child.deinit(ctx);
                send_reply(cmd, reply_env, current_js_error_with_poison(ctx_res, ctx));
                return;
            }
        } else if (!is_plain_object(ctx, child)) {
            child.deinit(ctx);
            send_reply(cmd, reply_env, beam.make(.{ .@"error", .{ .js, "cannot set nested path: intermediate is not an object" } }, .{ .env = reply_env }));
            return;
        }

        const prev = current;
        current = child;
        prev.deinit(ctx);
    }

    const js_val = erl_to_js(value_env, ctx, cmd.value_term, 0) catch |err| {
        send_reply(cmd, reply_env, erl_to_js_error_term(ctx_res, ctx, err));
        return;
    };

    current.setPropertyStr(ctx, path[path.len - 1], js_val) catch {
        send_reply(cmd, reply_env, property_set_error_term(ctx_res, ctx));
        return;
    };

    send_reply(cmd, reply_env, beam.make(.ok, .{ .env = reply_env }));
}

fn execute_gc(ctx_res: *JsContext, cmd: *Command) void {
    const reply_env = prepare_reply_env() orelse return;
    runtime_ptr(ctx_res).runGC();
    send_reply(cmd, reply_env, beam.make(.ok, .{ .env = reply_env }));
}

fn execute_register_callback(ctx_res: *JsContext, cmd: *Command) void {
    const reply_env = prepare_reply_env() orelse return;
    const callback_name = cmd.name orelse {
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .internal_error }, .{ .env = reply_env }));
        return;
    };

    const callback_entry = beam.allocator.create(CallbackEntry) catch {
        send_reply(cmd, reply_env, poison_internal_error(ctx_res));
        return;
    };

    const callback_name_copy = alloc_z_string(callback_name[0..callback_name.len]) catch {
        beam.allocator.destroy(callback_entry);
        send_reply(cmd, reply_env, poison_internal_error(ctx_res));
        return;
    };

    callback_entry.* = .{
        .name = callback_name_copy,
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
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .internal_error }, .{ .env = reply_env }));
        return;
    }

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    global.setPropertyStr(ctx, callback_entry.name, fn_value) catch {
        mark_context_poisoned(ctx_res);
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .internal_error }, .{ .env = reply_env }));
        return;
    };

    send_reply(cmd, reply_env, beam.make(.ok, .{ .env = reply_env }));
}

fn execute_register_async_callback(ctx_res: *JsContext, cmd: *Command) void {
    const reply_env = prepare_reply_env() orelse return;
    const callback_name = cmd.name orelse {
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .internal_error }, .{ .env = reply_env }));
        return;
    };

    const callback_entry = beam.allocator.create(CallbackEntry) catch {
        send_reply(cmd, reply_env, poison_internal_error(ctx_res));
        return;
    };

    const callback_name_copy = alloc_z_string(callback_name[0..callback_name.len]) catch {
        beam.allocator.destroy(callback_entry);
        send_reply(cmd, reply_env, poison_internal_error(ctx_res));
        return;
    };

    callback_entry.* = .{
        .name = callback_name_copy,
        .ctx_res = ctx_res,
    };

    const ctx = context_ptr(ctx_res);
    const fn_value = Value.initCClosure(
        ctx,
        CallbackEntry,
        async_dispatch_fn,
        callback_entry.name,
        callbackEntryFinalizer,
        0,
        0,
        callback_entry,
    );

    if (fn_value.isException()) {
        callbackEntryFinalizer(callback_entry);
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .internal_error }, .{ .env = reply_env }));
        return;
    }

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    global.setPropertyStr(ctx, callback_entry.name, fn_value) catch {
        mark_context_poisoned(ctx_res);
        send_reply(cmd, reply_env, beam.make(.{ .@"error", .internal_error }, .{ .env = reply_env }));
        return;
    };

    send_reply(cmd, reply_env, beam.make(.ok, .{ .env = reply_env }));
}

fn interrupt_handler(opaque_ptr: ?*JsContext, runtime: *Runtime) bool {
    _ = runtime;

    const ctx_res = opaque_ptr orelse return false;
    ctx_res.gas_quanta_total +|= 1;
    if (context_is_shutting_down(ctx_res)) return true;

    const now = std.time.milliTimestamp();
    if (now > 0 and now - ctx_res.owner_check_ms >= @as(i64, @intCast(CALLBACK_OWNER_CHECK_NS / std.time.ns_per_ms))) {
        ctx_res.owner_check_ms = now;
        if (!process_is_alive(ctx_res.owner_pid)) {
            request_context_shutdown(ctx_res, .owner_down);
            return true;
        }
    }

    if (ctx_res.deadline_ms == 0) return false;
    if (ctx_res.deadline_ms > @as(u64, @intCast(std.math.maxInt(i64)))) return false;
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

    const owner_pid = beam.self(.{}) catch {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };

    var resource = JsContextResource.create(.{
        .runtime_ptr = 0,
        .context_ptr = 0,
        .owner_pid = owner_pid,
        .memory_limit_bytes = memory_limit_bytes,
        .stack_limit_bytes = stack_limit_bytes,
        .thread = undefined,
        .thread_started = false,
        .thread_joined = false,
        .init_mutex = .{},
        .init_condvar = .{},
        .init_done = false,
        .init_ok = false,
        .queue_mutex = .{},
        .queue_condvar = .{},
        .queue_head_ptr = 0,
        .queue_tail_ptr = 0,
        .shutting_down = false,
        .busy = false,
        .deadline_ms = 0,
        .poisoned = false,
        .was_interrupted = false,
        .active_caller_pid = std.mem.zeroes(beam.pid),
        .active_ref_env = null,
        .active_ref_term = .{ .v = undefined },
        .has_active_command = false,
        .owner_check_ms = 0,
        .callback_mutex = .{},
        .callback_condvar = .{},
        .callback_req_id = 0,
        .callback_result_env = null,
        .callback_result = .{ .v = undefined },
        .callback_result_ready = false,
        .callback_abort_reason = .none,
        .callback_error_env = null,
        .callback_error = null,
        .async_entries_head_ptr = 0,
        .async_entries_count = 0,
        .async_resolution_head_ptr = 0,
        .async_resolution_tail_ptr = 0,
        .module_load_error = false,
        .gas_quanta_total = 0,
        .gas_quanta_last = 0,
    }, .{}) catch {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };

    const thread_opts = e.enif_thread_opts_create(@constCast("quickjs_ex_ctx_opts")) orelse {
        resource.release();
        return beam.make(.{ .@"error", .internal_error }, .{});
    };
    defer e.enif_thread_opts_destroy(thread_opts);
    thread_opts[0].suggested_stack_size = context_thread_stack_kilowords(stack_limit_bytes);

    if (e.enif_thread_create(@constCast("quickjs_ex_ctx"), &resource.__payload.thread, context_thread_main, resource.__payload, thread_opts) != 0) {
        resource.release();
        return beam.make(.{ .@"error", .internal_error }, .{});
    }

    resource.__payload.thread_started = true;

    resource.__payload.init_mutex.lock();
    while (!resource.__payload.init_done) {
        resource.__payload.init_condvar.wait(&resource.__payload.init_mutex);
    }
    const init_ok = resource.__payload.init_ok;
    resource.__payload.init_mutex.unlock();

    if (!init_ok) {
        shutdown_context_thread(resource.__payload);
        resource.release();
        return beam.make(.{ .@"error", .internal_error }, .{});
    }

    return beam.make(.{ .ok, resource }, .{});
}

fn create_command(env: beam.env, kind: CommandKind, request_ref: beam.term) ?*Command {
    const ref_env = e.enif_alloc_env() orelse return null;
    errdefer e.enif_free_env(ref_env);

    const caller_pid = beam.self(.{ .env = env }) catch return null;
    const cmd = beam.allocator.create(Command) catch return null;
    errdefer beam.allocator.destroy(cmd);

    cmd.* = .{
        .kind = kind,
        .caller_pid = caller_pid,
        .ref_env = ref_env,
        .ref_term = .{ .v = e.enif_make_copy(ref_env, request_ref.v) },
    };

    return cmd;
}

fn enqueue_checked(env: beam.env, ctx_res: *JsContext, cmd: *Command) beam.term {
    ctx_res.queue_mutex.lock();
    defer ctx_res.queue_mutex.unlock();

    if (context_is_poisoned(ctx_res)) {
        destroy_command(cmd);
        return beam.make(.{ .@"error", .poisoned }, .{ .env = env });
    }

    if (context_is_shutting_down(ctx_res)) {
        destroy_command(cmd);
        return beam.make(.{ .@"error", .poisoned }, .{ .env = env });
    }

    if (ctx_res.busy) {
        destroy_command(cmd);
        return beam.make(.{ .@"error", .context_busy }, .{ .env = env });
    }

    cmd.ctx_res_ptr = @intFromPtr(ctx_res);
    ctx_res.busy = true;

    if (command_ptr(ctx_res.queue_tail_ptr)) |tail| {
        tail.next = cmd;
    } else {
        ctx_res.queue_head_ptr = command_raw(cmd);
    }

    ctx_res.queue_tail_ptr = command_raw(cmd);
    ctx_res.queue_condvar.signal();
    return beam.make(.ok, .{ .env = env });
}

fn copy_binary_arg(env: beam.env, term: beam.term) ?[]u8 {
    var binary: e.ErlNifBinary = undefined;
    if (e.enif_inspect_binary(env, term.v, &binary) == 0) {
        return null;
    }

    const source = binary.data[0..binary.size];
    const copy = beam.allocator.alloc(u8, source.len + 1) catch return null;
    @memcpy(copy[0..source.len], source);
    copy[source.len] = 0;
    return copy;
}

fn copy_value_term(value: beam.term) ?struct { env: beam.env, term: beam.term } {
    const term_env = e.enif_alloc_env() orelse return null;
    const copied = e.enif_make_copy(term_env, value.v);
    return .{ .env = term_env, .term = .{ .v = copied } };
}

fn copy_path(path: [][]const u8) ?[][:0]u8 {
    const copied_path = beam.allocator.alloc([:0]u8, path.len) catch return null;
    errdefer beam.allocator.free(copied_path);

    for (path, 0..) |segment, index| {
        copied_path[index] = alloc_z_string(segment) catch {
            for (copied_path[0..index]) |copied_segment| {
                beam.allocator.free(copied_segment);
            }
            return null;
        };
    }

    return copied_path;
}

fn command_context_or_error(env: beam.env, resource_ref: beam.term) union(enum) { ok: JsContextResource, err: beam.term } {
    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return .{ .err = beam.make(.{ .@"error", .internal_error }, .{ .env = env }) };
    };
    const ctx_res = ctx_resource.__payload;

    if (context_is_poisoned(ctx_res)) {
        ctx_resource.release();
        return .{ .err = beam.make(.{ .@"error", .poisoned }, .{ .env = env }) };
    }

    if (context_is_shutting_down(ctx_res)) {
        ctx_resource.release();
        return .{ .err = beam.make(.{ .@"error", .poisoned }, .{ .env = env }) };
    }

    if (!is_owner(env, ctx_res.owner_pid)) {
        ctx_resource.release();
        return .{ .err = beam.make(.{ .@"error", .not_owner }, .{ .env = env }) };
    }

    return .{ .ok = ctx_resource };
}

pub fn nif_eval(resource_ref: beam.term, request_ref: beam.term, code_term: beam.term, timeout_ms: u64, eval_as_module: bool) beam.term {
    const env = beam.context.env;

    const ctx_resource = switch (command_context_or_error(env, resource_ref)) {
        .ok => |resource| resource,
        .err => |err| return err,
    };
    defer ctx_resource.release();

    const cmd = create_command(env, .eval, request_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{});
    };

    cmd.code = copy_binary_arg(env, code_term) orelse {
        destroy_command(cmd);
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };
    cmd.timeout_ms = timeout_ms;
    cmd.eval_as_module = eval_as_module;

    return enqueue_checked(env, ctx_resource.__payload, cmd);
}

pub fn nif_get_gas(resource_ref: beam.term, request_ref: beam.term) beam.term {
    const env = beam.context.env;

    const ctx_resource = switch (command_context_or_error(env, resource_ref)) {
        .ok => |resource| resource,
        .err => |err| return err,
    };
    defer ctx_resource.release();

    const cmd = create_command(env, .get_gas, request_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };

    return enqueue_checked(env, ctx_resource.__payload, cmd);
}

pub fn nif_get(resource_ref: beam.term, request_ref: beam.term, name: []const u8) beam.term {
    const env = beam.context.env;

    const ctx_resource = switch (command_context_or_error(env, resource_ref)) {
        .ok => |resource| resource,
        .err => |err| return err,
    };
    defer ctx_resource.release();

    const cmd = create_command(env, .get, request_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };
    cmd.name = alloc_z_string(name) catch {
        destroy_command(cmd);
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };

    return enqueue_checked(env, ctx_resource.__payload, cmd);
}

pub fn nif_set_value(resource_ref: beam.term, request_ref: beam.term, name: []const u8, value: beam.term) beam.term {
    const env = beam.context.env;

    const ctx_resource = switch (command_context_or_error(env, resource_ref)) {
        .ok => |resource| resource,
        .err => |err| return err,
    };
    defer ctx_resource.release();

    const cmd = create_command(env, .set_value, request_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };
    cmd.name = alloc_z_string(name) catch {
        destroy_command(cmd);
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };
    const copied_value = copy_value_term(value) orelse {
        destroy_command(cmd);
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };
    cmd.term_env = copied_value.env;
    cmd.value_term = copied_value.term;

    return enqueue_checked(env, ctx_resource.__payload, cmd);
}

pub fn nif_set_path(resource_ref: beam.term, request_ref: beam.term, path: [][]const u8, value: beam.term) beam.term {
    const env = beam.context.env;

    const ctx_resource = switch (command_context_or_error(env, resource_ref)) {
        .ok => |resource| resource,
        .err => |err| return err,
    };
    defer ctx_resource.release();

    const cmd = create_command(env, .set_path, request_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };
    cmd.path = copy_path(path) orelse {
        destroy_command(cmd);
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };
    const copied_value = copy_value_term(value) orelse {
        destroy_command(cmd);
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };
    cmd.term_env = copied_value.env;
    cmd.value_term = copied_value.term;

    return enqueue_checked(env, ctx_resource.__payload, cmd);
}

pub fn nif_gc(resource_ref: beam.term, request_ref: beam.term) beam.term {
    const env = beam.context.env;

    const ctx_resource = switch (command_context_or_error(env, resource_ref)) {
        .ok => |resource| resource,
        .err => |err| return err,
    };
    defer ctx_resource.release();

    const cmd = create_command(env, .gc, request_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };

    return enqueue_checked(env, ctx_resource.__payload, cmd);
}

pub fn nif_register_callback(resource_ref: beam.term, request_ref: beam.term, name: []const u8, _fun_term: beam.term) beam.term {
    _ = _fun_term;

    const env = beam.context.env;

    const ctx_resource = switch (command_context_or_error(env, resource_ref)) {
        .ok => |resource| resource,
        .err => |err| return err,
    };
    defer ctx_resource.release();

    const cmd = create_command(env, .register_callback, request_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };
    cmd.name = alloc_z_string(name) catch {
        destroy_command(cmd);
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };

    return enqueue_checked(env, ctx_resource.__payload, cmd);
}

pub fn nif_register_async_callback(resource_ref: beam.term, request_ref: beam.term, name: []const u8, _fun_term: beam.term) beam.term {
    _ = _fun_term;

    const env = beam.context.env;

    const ctx_resource = switch (command_context_or_error(env, resource_ref)) {
        .ok => |resource| resource,
        .err => |err| return err,
    };
    defer ctx_resource.release();

    const cmd = create_command(env, .register_async_callback, request_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };
    cmd.name = alloc_z_string(name) catch {
        destroy_command(cmd);
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };

    return enqueue_checked(env, ctx_resource.__payload, cmd);
}

pub fn nif_signal_callback_result(resource_ref: beam.term, request_ref: beam.term, req_id: u64, result: beam.term) beam.term {
    const env = beam.context.env;

    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };
    defer ctx_resource.release();
    const ctx_res = ctx_resource.__payload;

    if (!is_owner(env, ctx_res.owner_pid)) {
        return beam.make(.{ .@"error", .not_owner }, .{ .env = env });
    }

    const msg_env = e.enif_alloc_env();
    if (msg_env == null) {
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    }

    const copied_result = e.enif_make_copy(msg_env, result.v);

    ctx_res.callback_mutex.lock();
    defer ctx_res.callback_mutex.unlock();

    if (!active_request_matches_locked(ctx_res, env, request_ref)) {
        e.enif_free_env(msg_env);
        return beam.make(.{ .@"error", .stale }, .{ .env = env });
    }

    if (ctx_res.callback_abort_reason != .none or context_is_shutting_down(ctx_res)) {
        e.enif_free_env(msg_env);
        return beam.make(.{ .@"error", .stale }, .{ .env = env });
    }

    if (ctx_res.callback_req_id != req_id) {
        e.enif_free_env(msg_env);
        return beam.make(.{ .@"error", .stale }, .{ .env = env });
    }

    if (ctx_res.callback_result_env) |previous_env| {
        e.enif_free_env(previous_env);
    }

    ctx_res.callback_result_env = msg_env;
    ctx_res.callback_result = .{ .v = copied_result };
    ctx_res.callback_result_ready = true;
    ctx_res.callback_condvar.signal();

    return beam.make(.ok, .{ .env = env });
}

pub fn nif_signal_module_result(resource_ref: beam.term, request_ref: beam.term, req_id: u64, result: beam.term) beam.term {
    const env = beam.context.env;

    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };
    defer ctx_resource.release();
    const ctx_res = ctx_resource.__payload;

    if (!is_owner(env, ctx_res.owner_pid)) {
        return beam.make(.{ .@"error", .not_owner }, .{ .env = env });
    }

    const msg_env = e.enif_alloc_env();
    if (msg_env == null) {
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    }

    const copied_result = e.enif_make_copy(msg_env, result.v);

    ctx_res.callback_mutex.lock();
    defer ctx_res.callback_mutex.unlock();

    if (!active_request_matches_locked(ctx_res, env, request_ref)) {
        e.enif_free_env(msg_env);
        return beam.make(.{ .@"error", .stale }, .{ .env = env });
    }

    if (ctx_res.callback_abort_reason != .none or context_is_shutting_down(ctx_res)) {
        e.enif_free_env(msg_env);
        return beam.make(.{ .@"error", .stale }, .{ .env = env });
    }

    if (ctx_res.callback_req_id != req_id) {
        e.enif_free_env(msg_env);
        return beam.make(.{ .@"error", .stale }, .{ .env = env });
    }

    if (ctx_res.callback_result_env) |previous_env| {
        e.enif_free_env(previous_env);
    }

    ctx_res.callback_result_env = msg_env;
    ctx_res.callback_result = .{ .v = copied_result };
    ctx_res.callback_result_ready = true;
    ctx_res.callback_condvar.signal();

    return beam.make(.ok, .{ .env = env });
}

pub fn nif_resolve_async(resource_ref: beam.term, request_ref: beam.term, req_id: u64, result: beam.term) beam.term {
    const env = beam.context.env;

    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };
    defer ctx_resource.release();
    const ctx_res = ctx_resource.__payload;

    const msg_env = e.enif_alloc_env();
    if (msg_env == null) {
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    }

    const resolution = beam.allocator.create(AsyncResolution) catch {
        e.enif_free_env(msg_env);
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };

    resolution.* = .{
        .req_id = req_id,
        .result_env = msg_env,
        .result = .{ .v = e.enif_make_copy(msg_env, result.v) },
    };

    ctx_res.callback_mutex.lock();
    defer ctx_res.callback_mutex.unlock();

    if (!active_request_matches_locked(ctx_res, env, request_ref) or !async_entry_exists_locked(ctx_res, req_id)) {
        e.enif_free_env(msg_env);
        beam.allocator.destroy(resolution);
        return beam.make(.{ .@"error", .stale }, .{ .env = env });
    }

    if (ctx_res.callback_abort_reason != .none or context_is_shutting_down(ctx_res)) {
        e.enif_free_env(msg_env);
        beam.allocator.destroy(resolution);
        return beam.make(.{ .@"error", .stale }, .{ .env = env });
    }

    append_async_resolution_locked(ctx_res, resolution);

    return beam.make(.ok, .{ .env = env });
}

pub fn nif_transfer_owner(resource_ref: beam.term, new_owner: beam.pid) beam.term {
    const env = beam.context.env;

    const ctx_resource = fetch_js_context(env, resource_ref) orelse {
        return beam.make(.{ .@"error", .internal_error }, .{ .env = env });
    };
    defer ctx_resource.release();
    const ctx_res = ctx_resource.__payload;

    if (!is_owner(env, ctx_res.owner_pid)) {
        return beam.make(.{ .@"error", .not_owner }, .{ .env = env });
    }

    ctx_res.owner_pid = new_owner;
    return beam.make(.ok, .{ .env = env });
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
        mark_context_poisoned(ctx_res);
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
        mark_context_poisoned(ctx_res);
        return beam.make(.{ .@"error", .oom }, .{});
    }

    return beam.make(.{ .@"error", .{ .js, "property set failed" } }, .{});
}

fn poison_internal_error(ctx_res: *JsContext) beam.term {
    mark_context_poisoned(ctx_res);
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

fn consume_result_budget(budget: *usize, amount: usize) error{MaxResultSize}!void {
    if (amount > budget.*) return error.MaxResultSize;
    budget.* -= amount;
}

fn js_to_erl(env: beam.env, ctx: *Context, val: Value, depth: u32) error{ MaxDepth, MaxResultSize, FunctionNotSerializable, JSError, OutOfMemory }!beam.term {
    var budget: usize = MAX_RESULT_NODE_COUNT;
    return js_to_erl_limited(env, ctx, val, depth, &budget);
}

fn js_to_erl_limited(env: beam.env, ctx: *Context, val: Value, depth: u32, budget: *usize) error{ MaxDepth, MaxResultSize, FunctionNotSerializable, JSError, OutOfMemory }!beam.term {
    _ = Atom;

    if (depth >= MAX_MARSHAL_DEPTH) return error.MaxDepth;
    try consume_result_budget(budget, 1);

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
        if (length > MAX_RESULT_ARRAY_LENGTH or length > budget.*) return error.MaxResultSize;

        var list_items = try beam.allocator.alloc(beam.term, length);
        defer beam.allocator.free(list_items);

        for (0..length) |index| {
            const item = val.getPropertyUint32(ctx, @intCast(index));
            defer item.deinit(ctx);

            if (item.isException()) return error.JSError;

            list_items[index] = try js_to_erl_limited(env, ctx, item, depth + 1, budget);
        }

        return beam.make(list_items, .{ .env = env });
    }

    if (val.isPromise()) {
        return error.JSError;
    }

    if (val.isObject()) {
        const props = val.getOwnPropertyNames(ctx, .enum_strings) catch return error.JSError;
        defer Value.freePropertyEnum(ctx, props);
        if (props.len > MAX_RESULT_OBJECT_PROPERTIES or props.len > budget.*) return error.MaxResultSize;

        var map_term: beam.term = .{ .v = e.enif_make_new_map(env) };

        for (props) |prop| {
            const key = prop.atom.toZigSlice(ctx) orelse return error.JSError;
            defer ctx.freeCString(key.ptr);

            const key_term = beam.make(key[0..key.len], .{ .env = env });

            const item = val.getProperty(ctx, prop.atom);
            defer item.deinit(ctx);

            if (item.isException()) return error.JSError;

            const item_term = try js_to_erl_limited(env, ctx, item, depth + 1, budget);

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
                return Value.null;
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
