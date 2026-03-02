defmodule QuickjsEx.CallbackRunner do
  alias QuickjsEx.Context

  def start_link do
    pid = spawn_link(fn -> loop(%{callbacks: %{}, contexts: %{}}) end)
    {:ok, pid}
  end

  def register(runner_pid, name, fun, ctx \\ nil)

  def register(runner_pid, name, fun, ctx)
      when is_function(fun) and (is_nil(ctx) or is_struct(ctx, Context)) do
    send(runner_pid, {:register, name, fun, ctx})
    :ok
  end

  defp loop(state) do
    receive do
      {:register, name, fun} ->
        loop(register_callback(state, name, fun, nil))

      {:register, name, fun, callback_ctx} ->
        loop(register_callback(state, name, fun, callback_ctx))

      {:callback_request, req_id, callback_name, args, ctx_ref} ->
        {result, next_state} =
          case Map.fetch(state.callbacks, callback_name) do
            {:ok, fun} ->
              callback_ctx = Map.get(state.contexts, ctx_ref, default_context(ctx_ref))

              try do
                case invoke_callback(fun, args, callback_ctx, callback_name) do
                  {:ok, callback_result, new_ctx} ->
                    ctx_updates = Map.put(state.contexts, ctx_ref, ensure_runner_context(new_ctx))
                    {{:ok, callback_result}, %{state | contexts: ctx_updates}}

                  {:error, message} ->
                    {{:error, {:cb, callback_name, message}}, state}
                end
              rescue
                exception ->
                  {{:error, {:cb, callback_name, Exception.message(exception)}}, state}
              catch
                kind, reason ->
                  {{:error, {:cb, callback_name, Exception.format(kind, reason, __STACKTRACE__)}},
                   state}
              end

            :error ->
              {{:error, {:cb, callback_name, "callback not registered"}}, state}
          end

        _ = QuickjsEx.NIF.nif_signal_callback_result(ctx_ref, req_id, result)
        loop(next_state)

      :stop ->
        :ok
    end
  end

  defp register_callback(state, name, fun, nil) do
    %{state | callbacks: Map.put(state.callbacks, name, fun)}
  end

  defp register_callback(state, name, fun, %Context{} = ctx) do
    runner_ctx = ensure_runner_context(ctx)

    %{
      state
      | callbacks: Map.put(state.callbacks, name, fun),
        contexts: Map.put(state.contexts, runner_ctx.ref, runner_ctx)
    }
  end

  defp invoke_callback(fun, args, callback_ctx, callback_name) do
    case callback_arity(fun) do
      1 ->
        {:ok, fun.(args), callback_ctx}

      2 ->
        case fun.(args, callback_ctx) do
          {result, %Context{} = new_ctx} ->
            if new_ctx.ref == callback_ctx.ref do
              {:ok, result, new_ctx}
            else
              {:error, "stateful callback returned context for a different reference"}
            end

          {_, _} ->
            {:error,
             "stateful callback #{callback_name} must return {result, %QuickjsEx.Context{}} or result"}

          result ->
            {:ok, result, callback_ctx}
        end

      arity ->
        {:error, "callback #{callback_name} must have arity 1 or 2, got #{arity}"}
    end
  end

  defp callback_arity(fun) do
    {:arity, arity} = :erlang.fun_info(fun, :arity)
    arity
  end

  defp default_context(ctx_ref) do
    ctx_ref
    |> Context.new()
    |> ensure_runner_context()
  end

  defp ensure_runner_context(%Context{} = ctx) do
    %{ctx | private: Map.put(ctx.private, :__runner_pid__, self())}
  end
end
