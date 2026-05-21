defmodule QuickjsEx.ServerTest do
  use ExUnit.Case, async: false

  defmodule Harness do
    use QuickjsEx.Server,
      callbacks: [
        :add,
        :count,
        :increment,
        :later,
        :reject_later,
        :deferred_add
      ]

    @impl QuickjsEx.Server
    def init(opts) do
      {:ok,
       %{
         parent: Keyword.fetch!(opts, :parent),
         count: Keyword.get(opts, :count, 0)
       }}
    end

    @impl QuickjsEx.Server
    def handle_js_call("add", [a, b], state), do: {:reply, a + b, state}

    def handle_js_call("count", [], state), do: {:reply, state.count, state}

    def handle_js_call("increment", [by], state) do
      next = state.count + by
      {:reply, next, %{state | count: next}}
    end

    def handle_js_call("later", [value], state) do
      ref = QuickjsEx.Server.current_ref()
      parent = state.parent

      {:ok, _pid} =
        Task.start(fn ->
          send(parent, {:later_started, self(), value})

          receive do
            {:resolve, result} -> QuickjsEx.Server.resolve(ref, result)
            {:reject, reason} -> QuickjsEx.Server.reject(ref, reason)
          after
            5_000 -> :timeout
          end
        end)

      {:noreply, state}
    end

    def handle_js_call("reject_later", [reason], state) do
      ref = QuickjsEx.Server.current_ref()
      parent = state.parent

      {:ok, _pid} =
        Task.start(fn ->
          send(parent, {:reject_started, self(), reason})

          receive do
            :reject -> QuickjsEx.Server.reject(ref, reason)
          after
            5_000 -> :timeout
          end
        end)

      {:noreply, state}
    end

    def handle_js_call("deferred_add", [by], state) do
      ref = QuickjsEx.Server.current_ref()
      parent = state.parent

      {:ok, _pid} =
        Task.start(fn ->
          send(parent, {:deferred_add_started, self(), by})

          receive do
            :go ->
              QuickjsEx.Server.resolve(ref, by, fn live_state ->
                Map.update!(live_state, :count, &(&1 + by))
              end)
          after
            5_000 -> :timeout
          end
        end)

      {:noreply, state}
    end
  end

  defmodule ApiOne do
    use QuickjsEx.API, scope: "one"

    defjs(bump(), do: :unused)
    defjs(get(), do: :unused)

    def handle_js_call("bump", [], state) do
      next = state.count + 1
      {:reply, next, %{state | count: next}}
    end

    def handle_js_call("get", [], state), do: {:reply, state.count, state}
  end

  defmodule ApiTwo do
    use QuickjsEx.API, scope: "two"

    defjs(bump(), do: :unused)
    defjs(get(), do: :unused)

    def handle_js_call("bump", [], state) do
      next = state.count + 1
      {:reply, next, %{state | count: next}}
    end

    def handle_js_call("get", [], state), do: {:reply, state.count, state}
  end

  defp start_harness(opts \\ []) do
    {id, opts} = Keyword.pop(opts, :id, Harness)

    opts =
      opts
      |> Keyword.put_new(:parent, self())
      |> Keyword.put_new(:memory_limit, 4_000_000)

    start_supervised(%{id: id, start: {Harness, :start_link, [opts]}})
  end

  describe "eval" do
    test "eval_sync returns the JavaScript value" do
      {:ok, server} = start_harness()

      assert {:ok, 42} = QuickjsEx.Server.eval_sync(server, "40 + 2")
    end

    test "eval_async sends a tagged result to the requester" do
      {:ok, server} = start_harness()

      assert {:ok, ref} = QuickjsEx.Server.eval_async(server, "21 * 2")

      assert_receive {:quickjs_ex_server_result, ^ref, {:ok, 42}}, 1_000
    end

    test "typed errors propagate through sync and async eval" do
      {:ok, server} = start_harness()

      assert {:error, {:js_error, message}} =
               QuickjsEx.Server.eval_sync(server, "throw new Error('boom')")

      assert message =~ "boom"

      assert {:ok, ref} =
               QuickjsEx.Server.eval_async(server, "new Promise(() => {})")

      assert_receive {:quickjs_ex_server_result, ^ref, {:error, :unsettled_promise}}, 1_000
    end

    test "module_load_error propagates through eval" do
      {:ok, server_without_loader} = start_harness()

      assert {:error, :module_load_error} =
               QuickjsEx.Server.eval_sync(server_without_loader, """
               (async () => import("missing"))()
               """)
    end

    test "eval_sync callers queue while the active eval is parked on a callback" do
      {:ok, server} = start_harness()

      first =
        Task.async(fn ->
          QuickjsEx.Server.eval_sync(server, "(async () => await later(41))()")
        end)

      assert_receive {:later_started, worker, 41}, 1_000

      second = Task.async(fn -> QuickjsEx.Server.eval_sync(server, "40 + 2") end)

      assert :sys.get_state(server, 1_000)
      refute Task.yield(second, 25)

      send(worker, {:resolve, 42})

      assert {:ok, 42} = Task.await(first, 1_000)
      assert {:ok, 42} = Task.await(second, 1_000)
    end

    test "eval_async can reject instead of queueing while the context is busy" do
      {:ok, server} = start_harness()

      first =
        Task.async(fn ->
          QuickjsEx.Server.eval_sync(server, "(async () => await later(10))()")
        end)

      assert_receive {:later_started, worker, 10}, 1_000

      assert {:ok, ref} = QuickjsEx.Server.eval_async(server, "40 + 2", on_busy: :error)
      assert_receive {:quickjs_ex_server_result, ^ref, {:error, :context_busy}}, 1_000

      send(worker, {:resolve, 10})
      assert {:ok, 10} = Task.await(first, 1_000)
    end

    test "gas reports runtime accounting through the server queue" do
      {:ok, server} = start_harness()

      assert {:ok, 2} = QuickjsEx.Server.eval_sync(server, "1 + 1")
      assert {:ok, %{last: last, total: total, quantum: 10_000}} = QuickjsEx.Server.gas(server)
      assert last >= 1
      assert total >= last
    end

    test "server crash mid-eval exits the eval_sync caller instead of hanging" do
      {:ok, server} = start_harness()
      parent = self()

      caller =
        spawn(fn ->
          exit_reason =
            catch_exit(
              QuickjsEx.Server.eval_sync(server, "(async () => await later(1))()", :infinity)
            )

          send(parent, {:caller_exit, self(), exit_reason})
        end)

      assert_receive {:later_started, _worker, 1}, 1_000
      Process.exit(server, :kill)

      assert_receive {:caller_exit, ^caller, {:killed, {GenServer, :call, _args}}}, 1_000
    end
  end

  describe "callbacks" do
    test "{:reply, value, state} resolves immediately" do
      {:ok, server} = start_harness()

      assert {:ok, 7} = QuickjsEx.Server.eval_sync(server, "add(3, 4)")
    end

    test "{:noreply, state} resolves later through resolve/2" do
      {:ok, server} = start_harness()

      eval =
        Task.async(fn ->
          QuickjsEx.Server.eval_sync(server, "(async () => await later(1))()")
        end)

      assert_receive {:later_started, worker, 1}, 1_000
      send(worker, {:resolve, 99})

      assert {:ok, 99} = Task.await(eval, 1_000)
    end

    test "reject/2 rejects the JavaScript promise as js_error" do
      {:ok, server} = start_harness()

      eval =
        Task.async(fn ->
          QuickjsEx.Server.eval_sync(server, "(async () => await reject_later('nope'))()")
        end)

      assert_receive {:reject_started, worker, "nope"}, 1_000
      send(worker, :reject)

      assert {:error, {:js_error, message}} = Task.await(eval, 1_000)
      assert message =~ "nope"
    end

    test "Promise.all over deferred callbacks starts both tasks and resolves both" do
      {:ok, server} = start_harness()

      eval =
        Task.async(fn ->
          QuickjsEx.Server.eval_sync(server, "Promise.all([later(10), later(20)])")
        end)

      assert_receive {:later_started, worker_a, 10}, 1_000
      assert_receive {:later_started, worker_b, 20}, 1_000

      send(worker_b, {:resolve, 20})
      send(worker_a, {:resolve, 10})

      assert {:ok, [10, 20]} = Task.await(eval, 1_000)
    end
  end

  describe "state" do
    test "state accumulates across calls and evals" do
      {:ok, server} = start_harness(count: 0)

      assert {:ok, 2} = QuickjsEx.Server.eval_sync(server, "increment(2)")
      assert {:ok, 5} = QuickjsEx.Server.eval_sync(server, "increment(3)")
      assert {:ok, 5} = QuickjsEx.Server.eval_sync(server, "count()")
    end

    test "deferred state transitions apply against live state at resolve time" do
      {:ok, server} = start_harness(count: 0)

      eval =
        Task.async(fn ->
          QuickjsEx.Server.eval_sync(server, "Promise.all([deferred_add(1), deferred_add(10)])")
        end)

      assert_receive {:deferred_add_started, worker_a, 1}, 1_000
      assert_receive {:deferred_add_started, worker_b, 10}, 1_000

      send(worker_b, :go)
      send(worker_a, :go)

      assert {:ok, [1, 10]} = Task.await(eval, 1_000)
      assert {:ok, 11} = QuickjsEx.Server.eval_sync(server, "count()")
    end

    test "loaded API modules keep isolated state slices" do
      {:ok, server} =
        start_harness(
          apis: [
            {ApiOne, %{count: 0}},
            {ApiTwo, %{count: 100}}
          ]
        )

      assert {:ok, [1, 101]} =
               QuickjsEx.Server.eval_sync(server, """
               (async () => {
                 await one.bump();
                 await two.bump();
                 return [await one.get(), await two.get()];
               })()
               """)
    end
  end
end
