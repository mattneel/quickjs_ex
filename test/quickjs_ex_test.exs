defmodule QuickjsExTest do
  use ExUnit.Case

  @default_memory 256 * 1024

  defp await_raw_result(ctx_ref, request_ref, callbacks) do
    receive do
      {:quickjs_ex_result, ^request_ref, result} ->
        result

      {:quickjs_ex_callback, ^request_ref, req_id, callback_name, args} ->
        result =
          case Map.fetch(callbacks, callback_name) do
            {:ok, fun} ->
              try do
                {:ok, fun.(args)}
              rescue
                exception -> {:error, {:cb, callback_name, Exception.message(exception)}}
              catch
                kind, reason ->
                  {:error, {:cb, callback_name, Exception.format(kind, reason, __STACKTRACE__)}}
              end

            :error ->
              {:error, {:cb, callback_name, "callback not registered"}}
          end

        assert :ok =
                 QuickjsEx.NIF.nif_signal_callback_result(ctx_ref, request_ref, req_id, result)

        await_raw_result(ctx_ref, request_ref, callbacks)
    after
      2_000 -> flunk("raw NIF request did not reply")
    end
  end

  defp dispatch_raw(ctx_ref, fun, callbacks \\ %{}) do
    request_ref = make_ref()
    assert :ok = fun.(request_ref)
    await_raw_result(ctx_ref, request_ref, callbacks)
  end

  defp spawn_owner_with_parked_callback(parent, opts \\ []) do
    send_context? = Keyword.get(opts, :send_context?, false)

    owner =
      spawn(fn ->
        {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

        ctx =
          QuickjsEx.set!(ctx, :park, fn [] ->
            send(parent, {:entered, self()})

            receive do
              :release -> 41
            end
          end)

        if send_context? do
          send(parent, {:ctx, self(), ctx})
        else
          send(parent, {:ready, self()})
        end

        send(parent, {:eval_result, self(), QuickjsEx.eval(ctx, "park()")})
      end)

    {owner, Process.monitor(owner)}
  end

  defp assert_vm_responsive do
    task =
      Task.async(fn ->
        Enum.reduce(1..50_000, 0, &+/2)
      end)

    assert Task.await(task, 100) == div(50_000 * 50_001, 2)
  end

  defp assert_fresh_context_eval_with_callback do
    {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
    ctx = QuickjsEx.set!(ctx, :add_one, fn [x] -> x + 1 end)
    assert {:ok, 42} = QuickjsEx.eval(ctx, "add_one(41)")
  end

  defp assert_context_eventually_stopped(ctx) do
    result =
      Enum.reduce_while(1..20, nil, fn _, _ ->
        case QuickjsEx.eval(ctx, "1") do
          {:error, :context_poisoned} = stopped ->
            {:halt, stopped}

          other ->
            Process.sleep(50)
            {:cont, other}
        end
      end)

    assert {:error, :context_poisoned} = result
  end

  describe "NIF smoke tests" do
    test "ping responds from the NIF" do
      assert :ok = QuickjsEx.NIF.ping()
    end

    test "raw NIF context supports eval/get/set/gc" do
      assert {:ok, ref} = QuickjsEx.NIF.nif_new(@default_memory, 0, 0)

      assert :ok = dispatch_raw(ref, &QuickjsEx.NIF.nif_set_value(ref, &1, "x", 41))
      assert {:ok, 41} = dispatch_raw(ref, &QuickjsEx.NIF.nif_get(ref, &1, "x"))
      assert {:ok, 42} = dispatch_raw(ref, &QuickjsEx.NIF.nif_eval(ref, &1, "x + 1", 0, false))

      assert {:ok, %{last: 1, total: 1, quantum: 10_000}} =
               dispatch_raw(ref, &QuickjsEx.NIF.nif_get_gas(ref, &1))

      assert :ok = dispatch_raw(ref, &QuickjsEx.NIF.nif_gc(ref, &1))
    end

    test "raw NIF gas tracks heavier evaluations" do
      assert {:ok, ref} = QuickjsEx.NIF.nif_new(@default_memory, 0, 0)

      assert {:ok, 2} = dispatch_raw(ref, &QuickjsEx.NIF.nif_eval(ref, &1, "1 + 1", 0, false))

      assert {:ok, %{last: 1, total: 1, quantum: 10_000}} =
               dispatch_raw(ref, &QuickjsEx.NIF.nif_get_gas(ref, &1))

      assert {:ok, _} =
               dispatch_raw(
                 ref,
                 &QuickjsEx.NIF.nif_eval(
                   ref,
                   &1,
                   "let s = 0; for (let i = 0; i < 500000; i++) { s += i; } s",
                   0,
                   false
                 )
               )

      assert {:ok, %{last: last, total: total, quantum: 10_000}} =
               dispatch_raw(ref, &QuickjsEx.NIF.nif_get_gas(ref, &1))

      assert last > 1
      assert total >= last
    end
  end

  describe "callback bridge" do
    setup do
      {:ok, ref} = QuickjsEx.NIF.nif_new(@default_memory, 0, 0)
      %{ref: ref}
    end

    test "routes JS callback invocation through the caller receive loop", %{ref: ref} do
      assert :ok = dispatch_raw(ref, &QuickjsEx.NIF.nif_register_callback(ref, &1, "double", nil))

      assert {:ok, 42} =
               dispatch_raw(
                 ref,
                 &QuickjsEx.NIF.nif_eval(ref, &1, "double(21)", 0, false),
                 %{"double" => fn [x] -> x * 2 end}
               )
    end

    test "propagates callback failures over the bridge", %{ref: ref} do
      assert :ok = dispatch_raw(ref, &QuickjsEx.NIF.nif_register_callback(ref, &1, "fail", nil))

      assert {:error, {:cb, "fail", _}} =
               dispatch_raw(
                 ref,
                 &QuickjsEx.NIF.nif_eval(ref, &1, "fail()", 0, false),
                 %{"fail" => fn [] -> raise "intentional error" end}
               )
    end

    test "rejects callback results tagged with the wrong request ref", %{ref: ref} do
      assert :ok = dispatch_raw(ref, &QuickjsEx.NIF.nif_register_callback(ref, &1, "double", nil))

      request_ref = make_ref()
      assert :ok = QuickjsEx.NIF.nif_eval(ref, request_ref, "double(21)", 0, false)

      assert_receive {:quickjs_ex_callback, ^request_ref, req_id, "double", [21]}, 1_000

      assert {:error, :stale} =
               QuickjsEx.NIF.nif_signal_callback_result(ref, make_ref(), req_id, {:ok, 42})

      assert :ok = QuickjsEx.NIF.nif_signal_callback_result(ref, request_ref, req_id, {:ok, 42})
      assert_receive {:quickjs_ex_result, ^request_ref, {:ok, 42}}, 1_000
    end
  end

  describe "Phase 1 validation" do
    test "can create context" do
      assert {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert is_struct(ctx, QuickjsEx.Context)
    end

    test "can create context with custom memory size" do
      assert {:ok, ctx} = QuickjsEx.new(memory_limit: 131_072)
      assert is_struct(ctx, QuickjsEx.Context)
    end

    test "can eval simple code" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      # var statements return undefined (nil)
      assert {:ok, nil} = QuickjsEx.eval(ctx, "var x = 1 + 2;")
    end

    test "can eval multiple statements" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, nil} = QuickjsEx.eval(ctx, "var x = 1; var y = 2; var z = x + y;")
    end

    test "can use JS built-ins" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      # push returns new length
      assert {:ok, 4} = QuickjsEx.eval(ctx, "var arr = [1, 2, 3]; arr.push(4);")
    end

    test "can use Math object" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, nil} = QuickjsEx.eval(ctx, "var x = Math.sqrt(16);")
    end

    test "can use JSON" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, nil} = QuickjsEx.eval(ctx, ~s|var obj = JSON.parse('{"a": 1}');|)
    end

    test "eval returns error on syntax error" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      result = QuickjsEx.eval(ctx, "var x = ")
      assert match?({:error, _}, result)
    end

    test "context cleanup works (no crash on GC)" do
      for _ <- 1..100 do
        {:ok, _ctx} = QuickjsEx.new(memory_limit: @default_memory)
      end

      :erlang.garbage_collect()
      assert true
    end

    test "gas reports coarse evaluation cost" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      assert {:ok, 2} = QuickjsEx.eval(ctx, "1 + 1")
      assert {:ok, %{last: 1, total: 1, quantum: 10_000}} = QuickjsEx.gas(ctx)

      assert {:ok, _} =
               QuickjsEx.eval(
                 ctx,
                 "let s = 0; for (let i = 0; i < 500000; i++) { s += i; } s"
               )

      assert {:ok, %{last: last, total: total, quantum: 10_000}} = QuickjsEx.gas(ctx)
      assert last > 1
      assert total >= last
    end
  end

  describe "Phase 2: JS → Elixir primitives" do
    test "eval returns integers" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, 42} = QuickjsEx.eval(ctx, "42")
      assert {:ok, -17} = QuickjsEx.eval(ctx, "-17")
      assert {:ok, 0} = QuickjsEx.eval(ctx, "0")
    end

    test "eval returns floats" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, 3.14} = QuickjsEx.eval(ctx, "3.14")
      assert {:ok, -0.5} = QuickjsEx.eval(ctx, "-0.5")
    end

    test "eval returns whole floats as integers" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      # 4.0 should be returned as 4
      assert {:ok, 4} = QuickjsEx.eval(ctx, "4.0")
    end

    test "eval returns strings" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, "hello"} = QuickjsEx.eval(ctx, ~s|"hello"|)
      assert {:ok, ""} = QuickjsEx.eval(ctx, ~s|""|)
      assert {:ok, "hello world"} = QuickjsEx.eval(ctx, ~s|"hello" + " " + "world"|)
    end

    test "eval returns booleans" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, true} = QuickjsEx.eval(ctx, "true")
      assert {:ok, false} = QuickjsEx.eval(ctx, "false")
      assert {:ok, true} = QuickjsEx.eval(ctx, "1 === 1")
      assert {:ok, false} = QuickjsEx.eval(ctx, "1 === 2")
    end

    test "eval returns nil for null and undefined" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, nil} = QuickjsEx.eval(ctx, "null")
      assert {:ok, nil} = QuickjsEx.eval(ctx, "undefined")
    end
  end

  describe "Phase 2: JS → Elixir arrays" do
    test "eval returns empty array" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, []} = QuickjsEx.eval(ctx, "[]")
    end

    test "eval returns array of integers" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, [1, 2, 3]} = QuickjsEx.eval(ctx, "[1, 2, 3]")
    end

    test "eval returns array of mixed types" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, [1, "two", true, nil]} = QuickjsEx.eval(ctx, ~s|[1, "two", true, null]|)
    end

    test "eval returns nested arrays" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, [[1, 2], [3, 4]]} = QuickjsEx.eval(ctx, "[[1, 2], [3, 4]]")
    end
  end

  describe "Phase 2: JS → Elixir objects" do
    test "eval returns empty object" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, %{}} = QuickjsEx.eval(ctx, "({})")
    end

    test "eval returns object with properties" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, %{"a" => 1, "b" => 2}} = QuickjsEx.eval(ctx, "({a: 1, b: 2})")
    end

    test "eval returns nested objects" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      assert {:ok, %{"outer" => %{"inner" => 42}}} =
               QuickjsEx.eval(ctx, "({outer: {inner: 42}})")
    end

    test "eval returns object with array values" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, %{"items" => [1, 2, 3]}} = QuickjsEx.eval(ctx, "({items: [1, 2, 3]})")
    end

    test "functions are not serializable" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      assert {:error, {:js_error, _}} =
               QuickjsEx.eval(ctx, "(function() {})")
    end
  end

  describe "Phase 2: Elixir → JS (via set/get)" do
    test "set and get integer" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, ctx} = QuickjsEx.set(ctx, :x, 42)
      assert {:ok, 42} = QuickjsEx.get(ctx, :x)
    end

    test "set and get float" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, ctx} = QuickjsEx.set(ctx, :pi, 3.14159)
      assert {:ok, pi} = QuickjsEx.get(ctx, :pi)
      assert_in_delta pi, 3.14159, 0.00001
    end

    test "set and get string" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, ctx} = QuickjsEx.set(ctx, :message, "Hello from Elixir")
      assert {:ok, "Hello from Elixir"} = QuickjsEx.get(ctx, :message)
    end

    test "set and get boolean" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, ctx} = QuickjsEx.set(ctx, :flag, true)
      assert {:ok, true} = QuickjsEx.get(ctx, :flag)
      assert {:ok, ctx} = QuickjsEx.set(ctx, :flag, false)
      assert {:ok, false} = QuickjsEx.get(ctx, :flag)
    end

    test "set and get nil" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, ctx} = QuickjsEx.set(ctx, :nothing, nil)
      assert {:ok, nil} = QuickjsEx.get(ctx, :nothing)
    end

    test "set and get list" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, ctx} = QuickjsEx.set(ctx, :items, [1, 2, 3])
      assert {:ok, [1, 2, 3]} = QuickjsEx.get(ctx, :items)
    end

    test "set and get map" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, ctx} = QuickjsEx.set(ctx, :config, %{"debug" => true, "timeout" => 5000})
      assert {:ok, %{"debug" => true, "timeout" => 5000}} = QuickjsEx.get(ctx, :config)
    end

    test "set and get nested structure" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      data = %{
        "users" => [
          %{"name" => "Alice", "age" => 30},
          %{"name" => "Bob", "age" => 25}
        ],
        "count" => 2
      }

      assert {:ok, ctx} = QuickjsEx.set(ctx, :data, data)
      assert {:ok, ^data} = QuickjsEx.get(ctx, :data)
    end

    test "atom values become strings" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      # atoms (other than true/false/nil) become JS strings
      assert {:ok, ctx} = QuickjsEx.set(ctx, :status, :active)
      assert {:ok, "active"} = QuickjsEx.get(ctx, :status)
    end

    test "maps with atom keys work" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, ctx} = QuickjsEx.set(ctx, :config, %{debug: true, timeout: 5000})
      # Keys come back as strings
      assert {:ok, %{"debug" => true, "timeout" => 5000}} = QuickjsEx.get(ctx, :config)
    end
  end

  describe "Phase 2: round-trip through JS" do
    test "set value, use in JS, get result" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      {:ok, ctx} = QuickjsEx.set(ctx, :x, 10)
      {:ok, result} = QuickjsEx.eval(ctx, "x * 2")
      assert result == 20
    end

    test "pass array, modify in JS" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      {:ok, ctx} = QuickjsEx.set(ctx, :arr, [1, 2, 3])
      {:ok, _} = QuickjsEx.eval(ctx, "arr.push(4); arr.push(5);")
      {:ok, result} = QuickjsEx.get(ctx, :arr)
      assert result == [1, 2, 3, 4, 5]
    end

    test "pass object, modify in JS" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      {:ok, ctx} = QuickjsEx.set(ctx, :obj, %{"a" => 1})
      {:ok, _} = QuickjsEx.eval(ctx, "obj.b = 2; obj.c = 3;")
      {:ok, result} = QuickjsEx.get(ctx, :obj)
      assert result == %{"a" => 1, "b" => 2, "c" => 3}
    end
  end

  describe "state persistence" do
    test "variables persist across eval calls" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      {:ok, _} = QuickjsEx.eval(ctx, "var counter = 0;")
      {:ok, _} = QuickjsEx.eval(ctx, "counter++;")
      {:ok, _} = QuickjsEx.eval(ctx, "counter++;")
      {:ok, result} = QuickjsEx.eval(ctx, "counter")
      assert result == 2
    end

    test "functions persist across eval calls" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      {:ok, _} = QuickjsEx.eval(ctx, "function double(x) { return x * 2; }")
      {:ok, result} = QuickjsEx.eval(ctx, "double(21)")
      assert result == 42
    end
  end

  describe "garbage collection" do
    test "gc can be triggered without error" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      {:ok, _} = QuickjsEx.eval(ctx, "var arr = [1, 2, 3]; arr = null;")
      assert :ok = QuickjsEx.gc(ctx)
    end
  end

  describe "bang functions" do
    test "eval! returns {result, ctx}" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      {result, _ctx} = QuickjsEx.eval!(ctx, "1 + 2")
      assert result == 3
    end

    test "eval! raises on error" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      assert_raise QuickjsEx.RuntimeException, fn ->
        QuickjsEx.eval!(ctx, "undefined_var")
      end
    end

    test "get! returns value directly" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      {_, ctx} = QuickjsEx.eval!(ctx, "var x = 42;")
      assert 42 = QuickjsEx.get!(ctx, :x)
    end

    test "set! returns ctx for chaining" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :a, 1)
      ctx = QuickjsEx.set!(ctx, :b, 2)
      assert is_struct(ctx, QuickjsEx.Context)
      assert {:ok, 1} = QuickjsEx.get(ctx, :a)
      assert {:ok, 2} = QuickjsEx.get(ctx, :b)
    end
  end

  # ============================================================================
  # Callback Tests (using set + eval)
  # ============================================================================

  describe "basic callback invocation" do
    test "single callback" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :double, fn [x] -> x * 2 end)
      {:ok, result} = QuickjsEx.eval(ctx, "double(21)")
      assert result == 42
    end

    test "callback returning string" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :greet, fn [name] -> "Hello, #{name}!" end)
      {:ok, result} = QuickjsEx.eval(ctx, ~s|greet("World")|)
      assert result == "Hello, World!"
    end

    test "callback returning list" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :get_items, fn [] -> [1, 2, 3] end)
      {:ok, result} = QuickjsEx.eval(ctx, "get_items()")
      assert result == [1, 2, 3]
    end

    test "callback returning map" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :get_user, fn [id] -> %{"id" => id, "name" => "Alice"} end)
      {:ok, result} = QuickjsEx.eval(ctx, "get_user(1)")
      assert result == %{"id" => 1, "name" => "Alice"}
    end

    test "callback with multiple arguments" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :add, fn [a, b] -> a + b end)
      {:ok, result} = QuickjsEx.eval(ctx, "add(10, 32)")
      assert result == 42
    end

    test "callback with no arguments" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :get_answer, fn [] -> 42 end)
      {:ok, result} = QuickjsEx.eval(ctx, "get_answer()")
      assert result == 42
    end
  end

  describe "multiple sequential callbacks" do
    test "two callbacks in sequence" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :fetch_a, fn [] -> 10 end)
      ctx = QuickjsEx.set!(ctx, :fetch_b, fn [] -> 20 end)

      code = """
      var a = fetch_a();
      var b = fetch_b();
      a + b
      """

      {:ok, result} = QuickjsEx.eval(ctx, code)
      assert result == 30
    end

    test "three callbacks in sequence" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :step1, fn [] -> 1 end)
      ctx = QuickjsEx.set!(ctx, :step2, fn [x] -> x * 2 end)
      ctx = QuickjsEx.set!(ctx, :step3, fn [x] -> x + 10 end)

      code = """
      var a = step1();
      var b = step2(a);
      var c = step3(b);
      c
      """

      {:ok, result} = QuickjsEx.eval(ctx, code)
      # step1() -> 1, step2(1) -> 2, step3(2) -> 12
      assert result == 12
    end

    test "same callback called multiple times" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      counter = :counters.new(1, [])

      ctx =
        QuickjsEx.set!(ctx, :next, fn [] ->
          :counters.add(counter, 1, 1)
          :counters.get(counter, 1)
        end)

      code = """
      var a = next();
      var b = next();
      var c = next();
      [a, b, c]
      """

      {:ok, result} = QuickjsEx.eval(ctx, code)
      assert result == [1, 2, 3]
    end
  end

  describe "callback result used in computations" do
    test "callback result used in arithmetic" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :get_base, fn [] -> 100 end)
      {:ok, result} = QuickjsEx.eval(ctx, "get_base() * 2 + 5")
      assert result == 205
    end

    test "callback result used in string concatenation" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :get_name, fn [] -> "World" end)
      {:ok, result} = QuickjsEx.eval(ctx, ~s|"Hello, " + get_name() + "!"|)
      assert result == "Hello, World!"
    end

    test "callback result used in array operations" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :get_items, fn [] -> [1, 2, 3] end)

      code = """
      var items = get_items();
      items.push(4);
      items
      """

      {:ok, result} = QuickjsEx.eval(ctx, code)
      assert result == [1, 2, 3, 4]
    end

    test "callback result used in object operations" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :get_config, fn [] -> %{"debug" => false} end)

      code = """
      var config = get_config();
      config.debug = true;
      config.timeout = 5000;
      config
      """

      {:ok, result} = QuickjsEx.eval(ctx, code)
      assert result == %{"debug" => true, "timeout" => 5000}
    end
  end

  describe "nested callbacks" do
    test "callback in conditional branch" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :should_proceed, fn [] -> true end)
      ctx = QuickjsEx.set!(ctx, :get_value, fn [] -> 42 end)

      code = """
      if (should_proceed()) {
        get_value()
      } else {
        0
      }
      """

      {:ok, result} = QuickjsEx.eval(ctx, code)
      assert result == 42
    end

    test "callback in loop" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :get_item, fn [i] -> i * 10 end)

      code = """
      var sum = 0;
      for (var i = 0; i < 3; i++) {
        sum = sum + get_item(i);
      }
      sum
      """

      {:ok, result} = QuickjsEx.eval(ctx, code)
      # 0*10 + 1*10 + 2*10 = 30
      assert result == 30
    end

    test "callback result passed to another callback" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :fetch_id, fn [] -> 42 end)
      ctx = QuickjsEx.set!(ctx, :fetch_user, fn [id] -> %{"id" => id, "name" => "User#{id}"} end)

      code = """
      var id = fetch_id();
      var user = fetch_user(id);
      user.name
      """

      {:ok, result} = QuickjsEx.eval(ctx, code)
      assert result == "User42"
    end
  end

  describe "callback error handling" do
    test "unknown callback returns error" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      {:error, {:js_error, _}} = QuickjsEx.eval(ctx, "unknown_func()")
    end

    test "callback exception is caught" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :fail, fn [] -> raise "intentional error" end)
      assert {:error, {:callback_error, "fail", _}} = QuickjsEx.eval(ctx, "fail()")
    end
  end

  describe "complex callback scenarios" do
    test "simulated HTTP fetch pattern" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      ctx =
        QuickjsEx.set!(ctx, :fetch_data, fn [url] ->
          %{"url" => url, "status" => 200, "body" => "response from #{url}"}
        end)

      code = """
      var response = fetch_data("https://api.example.com/data");
      response.body
      """

      {:ok, result} = QuickjsEx.eval(ctx, code)
      assert result == "response from https://api.example.com/data"
    end

    test "multiple fetch with aggregation" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :fetch_user, fn [id] -> %{"id" => id, "name" => "User#{id}"} end)

      code = """
      var user1 = fetch_user(1);
      var user2 = fetch_user(2);
      var user3 = fetch_user(3);
      [user1.name, user2.name, user3.name]
      """

      {:ok, result} = QuickjsEx.eval(ctx, code)
      assert result == ["User1", "User2", "User3"]
    end

    test "JSON parsing pattern" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      ctx =
        QuickjsEx.set!(ctx, :fetch_json, fn [_url] ->
          ~s|{"items": [1, 2, 3], "count": 3}|
        end)

      code = """
      var json_str = fetch_json("http://example.com");
      var data = JSON.parse(json_str);
      data.count
      """

      {:ok, result} = QuickjsEx.eval(ctx, code)
      assert result == 3
    end
  end

  # ============================================================================
  # Persistent Elixir Functions (set with functions)
  # ============================================================================

  describe "setting functions via set/3" do
    test "set function and call from eval" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      {:ok, ctx} = QuickjsEx.set(ctx, :double, fn [x] -> x * 2 end)
      {:ok, result} = QuickjsEx.eval(ctx, "double(21)")
      assert result == 42
    end

    test "set! function and call from eval!" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :add, fn [a, b] -> a + b end)
      {result, _ctx} = QuickjsEx.eval!(ctx, "add(10, 32)")
      assert result == 42
    end

    test "multiple functions set via set!" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :add, fn [a, b] -> a + b end)
      ctx = QuickjsEx.set!(ctx, :multiply, fn [a, b] -> a * b end)
      ctx = QuickjsEx.set!(ctx, :greet, fn [name] -> "Hello, #{name}!" end)

      {result, ctx} = QuickjsEx.eval!(ctx, "add(2, 3)")
      assert result == 5

      {result, ctx} = QuickjsEx.eval!(ctx, "multiply(4, 5)")
      assert result == 20

      {result, _ctx} = QuickjsEx.eval!(ctx, ~s|greet("World")|)
      assert result == "Hello, World!"
    end

    test "mix of values and functions" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :multiplier, 10)
      ctx = QuickjsEx.set!(ctx, :scale, fn [x] -> x * 10 end)

      {result, _ctx} = QuickjsEx.eval!(ctx, "scale(multiplier)")
      assert result == 100
    end

    test "function persists across multiple eval calls" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :increment, fn [x] -> x + 1 end)

      {result1, ctx} = QuickjsEx.eval!(ctx, "increment(1)")
      {result2, ctx} = QuickjsEx.eval!(ctx, "increment(10)")
      {result3, _ctx} = QuickjsEx.eval!(ctx, "increment(100)")

      assert result1 == 2
      assert result2 == 11
      assert result3 == 101
    end

    test "function with complex return value" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      ctx =
        QuickjsEx.set!(ctx, :get_user, fn [id] ->
          %{"id" => id, "name" => "User#{id}", "active" => true}
        end)

      {result, _ctx} = QuickjsEx.eval!(ctx, "get_user(42).name")
      assert result == "User42"
    end
  end

  describe "private storage" do
    test "put_private and get_private" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.put_private(ctx, :user_id, 123)
      assert {:ok, 123} = QuickjsEx.get_private(ctx, :user_id)
    end

    test "get_private returns :error for missing key" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert :error = QuickjsEx.get_private(ctx, :nonexistent)
    end

    test "get_private! raises for missing key" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      assert_raise RuntimeError, ~r/private key.*does not exist/, fn ->
        QuickjsEx.get_private!(ctx, :nonexistent)
      end
    end

    test "get_private! returns value for existing key" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.put_private(ctx, :data, %{foo: "bar"})
      assert %{foo: "bar"} = QuickjsEx.get_private!(ctx, :data)
    end

    test "delete_private removes key" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.put_private(ctx, :temp, "value")
      assert {:ok, "value"} = QuickjsEx.get_private(ctx, :temp)
      ctx = QuickjsEx.delete_private(ctx, :temp)
      assert :error = QuickjsEx.get_private(ctx, :temp)
    end

    test "private storage is independent from JS context" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.put_private(ctx, :secret, "hidden")
      # JS can't see private storage
      {:error, _} = QuickjsEx.eval(ctx, "secret")
      # But Elixir can
      assert {:ok, "hidden"} = QuickjsEx.get_private(ctx, :secret)
    end
  end

  describe "timeout" do
    test "new timeout becomes the default eval timeout" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory, timeout: 10)

      assert {:error, :timeout} = QuickjsEx.eval(ctx, "while(true) {}")
      assert {:ok, 42} = QuickjsEx.eval(ctx, "42")
    end

    test "per-call timeout overrides the context default" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory, timeout: 10)

      assert {:ok, 4} = QuickjsEx.eval(ctx, "2 + 2", timeout: 0)
    end

    test "interrupts infinite loop and context remains usable" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:error, :timeout} = QuickjsEx.eval(ctx, "while(true) {}", timeout: 100)
      assert {:ok, 42} = QuickjsEx.eval(ctx, "42")
    end

    test "timeout 0 means no limit" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:ok, 4} = QuickjsEx.eval(ctx, "2 + 2", timeout: 0)
    end

    test "timeout measures JavaScript execution and excludes callback wait time" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      ctx =
        QuickjsEx.set!(ctx, :blocking_host_io, fn [] ->
          Process.sleep(200)
          41
        end)

      assert {:ok, 42} =
               QuickjsEx.eval(ctx, "blocking_host_io() + 1", timeout: 50)
    end
  end

  describe "new option validation" do
    test "invalid memory, stack, and timeout options return error tuples" do
      for option <- [:memory_limit, :stack_limit, :timeout] do
        assert {:error, {:invalid_option, ^option, message}} = QuickjsEx.new([{option, -1}])
        assert message =~ "non-negative integer"
      end
    end
  end

  describe "runtime bootstrap" do
    test "new returns an error when bootstrap fails" do
      assert {:error, _reason} = QuickjsEx.new(memory_limit: 110_000)
    end

    test "bootstrap installs console.log on normal contexts" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      assert {:ok, "function"} = QuickjsEx.eval(ctx, "typeof console.log")
    end
  end

  describe "result marshalling limits" do
    test "huge sparse arrays are rejected without poisoning the context" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      assert {:error, {:js_error, message}} =
               QuickjsEx.eval(ctx, "let a = []; a.length = 0xffffffff; a")

      assert message =~ "maximum result size exceeded"
      assert {:ok, 42} = QuickjsEx.eval(ctx, "42")
    end

    test "normal arrays still marshal successfully" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      assert {:ok, [1, 2, 3]} = QuickjsEx.eval(ctx, "[1, 2, 3]")
    end

    test "objects with too many properties are rejected" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: 4_000_000)

      assert {:error, {:js_error, message}} =
               QuickjsEx.eval(ctx, """
               let o = {};
               for (let i = 0; i < 11000; i++) {
                 o["k" + i] = i;
               }
               o;
               """)

      assert message =~ "maximum result size exceeded"
      assert {:ok, "usable"} = QuickjsEx.eval(ctx, "'usable'")
    end
  end

  describe "async callback fan-out limits" do
    test "too many pending async host callbacks reject and leave the context usable" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: 4_000_000)
      {:ok, ctx} = QuickjsEx.set_async(ctx, :host_async, fn [value] -> value end)

      assert {:ok, message} =
               QuickjsEx.eval(ctx, """
               (async () => {
                 let promises = [];
                 for (let i = 0; i < 128; i++) {
                   promises.push(host_async(i));
                 }

                 try {
                   await Promise.all(promises);
                   return "all resolved";
                 } catch (e) {
                   return "rejected: " + String(e && e.message ? e.message : e);
                 }
               })()
               """)

      assert message =~ "maximum pending async callbacks exceeded"
      assert {:ok, 42} = QuickjsEx.eval(ctx, "42")
    end

    test "small async host callback fan-out still succeeds" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      {:ok, ctx} = QuickjsEx.set_async(ctx, :host_async, fn [value] -> value + 1 end)

      assert {:ok, [2, 3, 4]} =
               QuickjsEx.eval(ctx, """
               (async () => Promise.all([host_async(1), host_async(2), host_async(3)]))()
               """)
    end

    test "stale async host resolutions after eval completion are ignored" do
      parent = self()
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      {:ok, ctx} =
        QuickjsEx.set_async(ctx, :late_async, fn [value] ->
          send(parent, {:late_async_started, self()})

          receive do
            :resolve -> value
          after
            1_000 -> value
          end
        end)

      assert {:ok, 42} = QuickjsEx.eval(ctx, "late_async(41); 42")
      assert_receive {:late_async_started, worker}, 1_000

      send(worker, :resolve)
      Process.sleep(25)

      assert {:ok, 43} = QuickjsEx.eval(ctx, "43")
    end
  end

  describe "scheduler-safe blocking callbacks" do
    test "callbacks run in the caller process" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      Process.put(:quickjs_ex_callback_state, "caller-state")

      ctx =
        QuickjsEx.set!(ctx, :read_process_state, fn [] ->
          Process.get(:quickjs_ex_callback_state)
        end)

      assert {:ok, "caller-state"} = QuickjsEx.eval(ctx, "read_process_state()")
    after
      Process.delete(:quickjs_ex_callback_state)
    end

    test "blocking callbacks do not consume dirty CPU schedulers" do
      dirty_schedulers = :erlang.system_info(:dirty_cpu_schedulers_online)
      context_count = dirty_schedulers + 2
      parent = self()

      tasks =
        for index <- 1..context_count do
          Task.async(fn ->
            {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

            ctx =
              QuickjsEx.set!(ctx, :blocking_host_io, fn [] ->
                Process.sleep(500)
                index
              end)

            send(parent, {:ready, self()})

            receive do
              :go -> :ok
            after
              1_000 -> flunk("context #{index} did not receive start signal")
            end

            QuickjsEx.eval(ctx, "blocking_host_io()")
          end)
        end

      ready_pids =
        for _ <- 1..context_count do
          assert_receive {:ready, pid}, 5_000
          pid
        end

      responsiveness_task =
        Task.async(fn ->
          Enum.reduce(1..50_000, 0, &+/2)
        end)

      start = System.monotonic_time(:millisecond)
      Enum.each(ready_pids, &send(&1, :go))

      assert Task.await(responsiveness_task, 100) == div(50_000 * 50_001, 2)
      assert Enum.map(tasks, &Task.await(&1, 2_000)) |> Enum.all?(&match?({:ok, _}, &1))

      elapsed_ms = System.monotonic_time(:millisecond) - start
      assert elapsed_ms < 850
    end

    test "callback returning error tuple throws a catchable JavaScript exception" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      ctx = QuickjsEx.set!(ctx, :fail_softly, fn [] -> {:error, "host rejected"} end)

      assert {:ok, "caught: host rejected"} =
               QuickjsEx.eval(ctx, """
               try {
                 fail_softly();
                 "not caught";
               } catch (e) {
                 "caught: " + e.message;
               }
               """)
    end

    test "callback reentrant eval returns typed error instead of deadlocking" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      ctx =
        QuickjsEx.set!(ctx, :reenter, fn [] ->
          QuickjsEx.eval(ctx, "1 + 1")
        end)

      assert {:error, {:callback_error, "reenter", message}} =
               QuickjsEx.eval(ctx, "reenter()")

      assert message =~ "context_busy"
      assert {:ok, 42} = QuickjsEx.eval(ctx, "42")
    end
  end

  describe "new behaviors" do
    test "not_owner enforcement" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      task =
        Task.async(fn ->
          QuickjsEx.eval(ctx, "1")
        end)

      assert {:error, :not_owner} = Task.await(task)
    end

    test "owner death interrupts active eval and stops retained context handles" do
      parent = self()

      owner =
        spawn(fn ->
          {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
          send(parent, {:ctx, ctx})
          QuickjsEx.eval(ctx, "while (true) {}", timeout: 0)
        end)

      monitor_ref = Process.monitor(owner)
      assert_receive {:ctx, ctx}, 1_000

      Process.sleep(50)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor_ref, :process, ^owner, :killed}, 1_000

      result =
        Enum.reduce_while(1..20, nil, fn _, _ ->
          case QuickjsEx.eval(ctx, "1") do
            {:error, :context_poisoned} = stopped ->
              {:halt, stopped}

            other ->
              Process.sleep(50)
              {:cont, other}
          end
        end)

      assert {:error, :context_poisoned} = result
    end

    test "owner death while parked in callback tears down retained context" do
      parent = self()
      {owner, monitor_ref} = spawn_owner_with_parked_callback(parent, send_context?: true)

      assert_receive {:ctx, ^owner, ctx}, 1_000
      assert_receive {:entered, ^owner}, 1_000

      responsiveness_task =
        Task.async(fn ->
          Enum.reduce(1..50_000, 0, &+/2)
        end)

      Process.exit(owner, :kill)

      assert Task.await(responsiveness_task, 100) == div(50_000 * 50_001, 2)
      assert_receive {:DOWN, ^monitor_ref, :process, ^owner, :killed}, 1_000
      assert_context_eventually_stopped(ctx)
      assert_fresh_context_eval_with_callback()
    end

    test "resource GC teardown while parked in callback joins context thread" do
      parent = self()
      {owner, monitor_ref} = spawn_owner_with_parked_callback(parent)

      assert_receive {:ready, ^owner}, 1_000
      assert_receive {:entered, ^owner}, 1_000

      assert_vm_responsive()
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor_ref, :process, ^owner, :killed}, 1_000

      :erlang.garbage_collect()
      assert_vm_responsive()
      assert_fresh_context_eval_with_callback()
    end

    test "context_poisoned after OOM" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: 1_000_000)
      assert {:error, :oom} = QuickjsEx.eval(ctx, "new ArrayBuffer(32 * 1024 * 1024)")
      assert {:error, :context_poisoned} = QuickjsEx.set(ctx, :x, 1)
    end

    test "internal async promises settle through the QuickJS job queue" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      assert {:ok, 42} =
               QuickjsEx.eval(ctx, """
               (async () => await Promise.resolve(41) + 1)()
               """)
    end

    test "unresolvable internal promises return unsettled_promise" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      assert {:error, :unsettled_promise} =
               QuickjsEx.eval(ctx, """
               (async () => await new Promise(() => {}))()
               """)
    end

    test "async rejections return js_error like synchronous throws" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      assert {:error, {:js_error, message}} =
               QuickjsEx.eval(ctx, """
               (async () => { throw new Error("async boom"); })()
               """)

      assert message =~ "async boom"
    end

    test "microtasks drain even when the root result is synchronous" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      assert {:ok, "queued"} =
               QuickjsEx.eval(ctx, """
               globalThis.afterMicrotask = 0;
               Promise.resolve().then(() => { globalThis.afterMicrotask = 2; });
               "queued";
               """)

      assert {:ok, 2} = QuickjsEx.get(ctx, :afterMicrotask)
    end

    test "async host capability resolves an awaited promise" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      {:ok, ctx} = QuickjsEx.set_async(ctx, :host_async, fn [value] -> value + 1 end)

      assert {:ok, 42} =
               QuickjsEx.eval(ctx, """
               (async () => await host_async(41))()
               """)
    end

    test "async host capabilities run concurrently and resolve out of order" do
      parent = self()

      owner =
        spawn_link(fn ->
          {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

          {:ok, ctx} =
            QuickjsEx.set_async(ctx, :host_async, fn [value] ->
              send(parent, {:entered, value, self()})

              receive do
                {:release, ^value, result} -> result
              end
            end)

          send(parent, {:ready, self()})

          result =
            QuickjsEx.eval(ctx, """
            (async () => Promise.all([host_async(1), host_async(2)]))()
            """)

          send(parent, {:result, result})
        end)

      assert_receive {:ready, ^owner}, 1_000
      assert_receive {:entered, 1, first_task}, 1_000
      assert_receive {:entered, 2, second_task}, 1_000
      assert first_task != second_task

      send(second_task, {:release, 2, 20})
      send(first_task, {:release, 1, 10})

      assert_receive {:result, {:ok, [10, 20]}}, 1_000
    end

    test "async host callback errors reject as js_error" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      {:ok, ctx} = QuickjsEx.set_async(ctx, :fail_async, fn [] -> {:error, "async rejected"} end)

      assert {:error, {:js_error, message}} =
               QuickjsEx.eval(ctx, """
               (async () => await fail_async())()
               """)

      assert message =~ "async rejected"
    end

    test "eval timeout pauses while waiting for async host resolution" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      {:ok, ctx} =
        QuickjsEx.set_async(ctx, :slow_async, fn [] ->
          Process.sleep(100)
          42
        end)

      assert {:ok, 42} =
               QuickjsEx.eval(
                 ctx,
                 """
                 (async () => await slow_async())()
                 """,
                 timeout: 10
               )
    end

    test "pending async host promises do not consume dirty CPU schedulers" do
      dirty_schedulers = :erlang.system_info(:dirty_cpu_schedulers_online)
      context_count = dirty_schedulers + 2
      parent = self()

      tasks =
        for index <- 1..context_count do
          Task.async(fn ->
            {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

            {:ok, ctx} =
              QuickjsEx.set_async(ctx, :slow_async, fn [] ->
                send(parent, {:entered_async, self()})
                Process.sleep(500)
                index
              end)

            send(parent, {:ready_async, self()})

            receive do
              :go -> :ok
            after
              1_000 -> flunk("context #{index} did not receive start signal")
            end

            QuickjsEx.eval(ctx, "(async () => await slow_async())()")
          end)
        end

      ready_pids =
        for _ <- 1..context_count do
          assert_receive {:ready_async, pid}, 5_000
          pid
        end

      responsiveness_task =
        Task.async(fn ->
          Enum.reduce(1..50_000, 0, &+/2)
        end)

      start = System.monotonic_time(:millisecond)
      Enum.each(ready_pids, &send(&1, :go))

      for _ <- 1..context_count do
        assert_receive {:entered_async, _pid}, 5_000
      end

      assert Task.await(responsiveness_task, 100) == div(50_000 * 50_001, 2)
      assert Enum.map(tasks, &Task.await(&1, 2_000)) |> Enum.all?(&match?({:ok, _}, &1))

      elapsed_ms = System.monotonic_time(:millisecond) - start
      assert elapsed_ms < 850
    end

    test "owner death while waiting on async host promise tears down retained context" do
      parent = self()

      owner =
        spawn(fn ->
          {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

          {:ok, ctx} =
            QuickjsEx.set_async(ctx, :park_async, fn [] ->
              send(parent, {:entered_async_teardown, self()})

              receive do
                :release -> 41
              end
            end)

          send(parent, {:ctx_async_teardown, self(), ctx})

          send(
            parent,
            {:eval_result, self(), QuickjsEx.eval(ctx, "(async () => await park_async())()")}
          )
        end)

      monitor_ref = Process.monitor(owner)
      assert_receive {:ctx_async_teardown, ^owner, ctx}, 1_000
      assert_receive {:entered_async_teardown, async_task}, 1_000

      assert_vm_responsive()
      Process.exit(owner, :kill)

      assert_receive {:DOWN, ^monitor_ref, :process, ^owner, :killed}, 1_000
      assert_context_eventually_stopped(ctx)
      Process.exit(async_task, :kill)
      assert_fresh_context_eval_with_callback()
    end

    test "module eval imports source from Elixir loader" do
      {:ok, ctx} = QuickjsEx.new()

      {:ok, ctx} =
        QuickjsEx.set_module_loader(ctx, fn
          "math" -> {:ok, "export let value = 41;"}
        end)

      assert {:ok, nil} =
               QuickjsEx.eval(
                 ctx,
                 """
                 import { value } from "math";
                 globalThis.moduleValue = value + 1;
                 """,
                 type: :module
               )

      assert {:ok, 42} = QuickjsEx.get(ctx, :moduleValue)
    end

    test "module import without loader returns module_load_error" do
      {:ok, ctx} = QuickjsEx.new()

      assert {:error, :module_load_error} =
               QuickjsEx.eval(
                 ctx,
                 """
                 import "missing";
                 """,
                 type: :module
               )
    end

    test "module loader errors return module_load_error" do
      {:ok, ctx} = QuickjsEx.new()
      {:ok, ctx} = QuickjsEx.set_module_loader(ctx, fn "missing" -> {:error, "not found"} end)

      assert {:error, :module_load_error} =
               QuickjsEx.eval(
                 ctx,
                 """
                 import "missing";
                 """,
                 type: :module
               )
    end

    test "module top-level await settles through the event loop" do
      {:ok, ctx} = QuickjsEx.new()

      {:ok, ctx} =
        QuickjsEx.set_module_loader(ctx, fn
          "async_value" -> {:ok, "export let value = await Promise.resolve(41) + 1;"}
        end)

      assert {:ok, nil} =
               QuickjsEx.eval(
                 ctx,
                 """
                 import { value } from "async_value";
                 globalThis.moduleAsyncValue = value;
                 """,
                 type: :module
               )

      assert {:ok, 42} = QuickjsEx.get(ctx, :moduleAsyncValue)
    end

    test "dynamic import uses the Elixir module loader" do
      {:ok, ctx} = QuickjsEx.new()

      {:ok, ctx} =
        QuickjsEx.set_module_loader(ctx, fn
          "dynamic_value" -> {:ok, "export let value = 42;"}
        end)

      assert {:ok, 42} =
               QuickjsEx.eval(ctx, """
               (async () => {
                 const module = await import("dynamic_value");
                 return module.value;
               })()
               """)
    end

    test "function serialization returns js_error" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)
      assert {:error, {:js_error, _}} = QuickjsEx.eval(ctx, "(function(){})")
    end

    test "default stack limit handles recursion without VM crash" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: @default_memory)

      result =
        QuickjsEx.eval(ctx, """
          function recurse(n) {
            if (n <= 0) return 0;
            return 1 + recurse(n - 1);
          }
          try {
            recurse(100);
          } catch(e) {
            "stack overflow";
          }
        """)

      assert {:ok, value} = result
      assert value in [100, "stack overflow"]
    end
  end
end
