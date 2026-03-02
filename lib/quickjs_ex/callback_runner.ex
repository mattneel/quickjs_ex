defmodule QuickjsEx.CallbackRunner do
  def start_link do
    pid = spawn_link(fn -> loop(%{callbacks: %{}}) end)
    {:ok, pid}
  end

  def register(runner_pid, name, fun) when is_function(fun) do
    send(runner_pid, {:register, name, fun})
    :ok
  end

  defp loop(state) do
    receive do
      {:register, name, fun} ->
        loop(register_callback(state, name, fun))

      {:callback_request, req_id, callback_name, args, ctx_ref} ->
        result =
          case Map.fetch(state.callbacks, callback_name) do
            {:ok, fun} ->
              case invoke_callback(fun, args) do
                {:ok, callback_result} ->
                  {:ok, callback_result}

                {:error, message} ->
                  {:error, {:cb, callback_name, message}}
              end

            :error ->
              {:error, {:cb, callback_name, "callback not registered"}}
          end

        _ = QuickjsEx.NIF.nif_signal_callback_result(ctx_ref, req_id, result)
        loop(state)

      :stop ->
        :ok
    end
  end

  defp register_callback(state, name, fun) do
    %{state | callbacks: Map.put(state.callbacks, name, fun)}
  end

  defp invoke_callback(fun, args) do
    case :erlang.fun_info(fun, :arity) do
      {:arity, 1} ->
        try do
          {:ok, fun.(args)}
        rescue
          exception ->
            {:error, Exception.message(exception)}
        catch
          kind, reason ->
            {:error, Exception.format(kind, reason, __STACKTRACE__)}
        end

      {:arity, _arity} ->
        {:error,
         "stateful callbacks must use defjs with state parameter — state access is not supported from runner process"}
    end
  end
end
