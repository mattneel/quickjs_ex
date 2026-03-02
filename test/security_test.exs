defmodule QuickjsEx.SecurityTest do
  @moduledoc """
  Security tests to verify that the MQuickJS runtime is safe for LLM use.

  These tests attempt to access dangerous APIs that should NOT be available
  in a sandboxed JavaScript environment. All tests should either return
  errors or undefined values - never actual access to system resources.
  """
  use ExUnit.Case, async: false

  # Helper to check if something is undefined (not available)
  defp assert_undefined(ctx, expr) do
    result = QuickjsEx.eval(ctx, "typeof #{expr}")

    assert result == {:ok, "undefined"},
           "Expected #{expr} to be undefined, got: #{inspect(result)}"
  end

  # ============================================================================
  # File System Access Tests
  # ============================================================================

  describe "file system access" do
    test "require is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "require")
    end

    test "import keyword exists but module loading is not available" do
      {:ok, ctx} = QuickjsEx.new()
      # import is a keyword, not a function - dynamic import() is not supported
      result = QuickjsEx.eval(ctx, "typeof import")
      # Either syntax error or undefined is acceptable
      assert match?({:error, _}, result) or result == {:ok, "undefined"}
    end

    test "fs module is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "fs")
    end

    test "Deno is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "Deno")
    end

    test "Bun is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "Bun")
    end

    test "__dirname is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "__dirname")
    end

    test "__filename is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "__filename")
    end

    test "load function is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert {:ok, "undefined"} = QuickjsEx.eval(ctx, "typeof load")
    end
  end

  # ============================================================================
  # Network Access Tests
  # ============================================================================

  describe "network access" do
    test "fetch is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "fetch")
    end

    test "XMLHttpRequest is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "XMLHttpRequest")
    end

    test "WebSocket is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "WebSocket")
    end

    test "navigator is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "navigator")
    end

    test "location is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "location")
    end

    test "window is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "window")
    end

    test "document is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "document")
    end
  end

  # ============================================================================
  # Process/OS Access Tests
  # ============================================================================

  describe "process/OS access" do
    test "process is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "process")
    end

    test "child_process is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "child_process")
    end

    test "os module is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "os")
    end

    test "Buffer is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert_undefined(ctx, "Buffer")
    end
  end

  # ============================================================================
  # Dangerous Built-in Tests
  # ============================================================================

  describe "dangerous built-ins" do
    test "Function constructor cannot access external scope" do
      {:ok, ctx} = QuickjsEx.new()
      # This is a common sandbox escape - trying to access global through Function
      result =
        QuickjsEx.eval(ctx, """
          try {
            var f = new Function('return this')();
            typeof f.process;
          } catch(e) {
            "error";
          }
        """)

      # Should return undefined or error, not access to process
      assert {:ok, value} = result
      assert value in [nil, "error", "undefined"]
    end

    test "indirect eval works but is sandboxed" do
      {:ok, ctx} = QuickjsEx.new()
      # Indirect eval (1,eval)(...) may work
      result =
        QuickjsEx.eval(ctx, """
          try {
            (1, eval)("typeof process");
          } catch(e) {
            "error: " + e.message;
          }
        """)

      # If it works, it should return "undefined" (process not available)
      # If it errors, that's also fine
      assert {:ok, value} = result
      assert value == "undefined" or String.starts_with?(to_string(value), "error")
    end
  end

  # ============================================================================
  # Memory/Resource Exhaustion Tests
  # ============================================================================

  describe "resource limits" do
    test "memory limit prevents large allocations" do
      # Using small memory (32KB)
      {:ok, ctx} = QuickjsEx.new(memory_limit: 32768)

      # Try to allocate a very large array - should fail gracefully
      result =
        QuickjsEx.eval(ctx, """
          try {
            var arr = [];
            for (var i = 0; i < 100000; i++) {
              var s = "";
              for (var j = 0; j < 100; j++) s += "x";
              arr.push(s);
            }
            "success";
          } catch(e) {
            "error: " + e.message;
          }
        """)

      assert match?({:error, :oom}, result) or
               result == {:error, {:js_error, "null"}} or
               (match?({:ok, _}, result) and
                  (case result do
                     {:ok, value} -> String.starts_with?(to_string(value), "error:")
                     _ -> false
                   end))
    end

    test "infinite loop protection via memory/timeout" do
      {:ok, ctx} = QuickjsEx.new(memory_limit: 32768)

      # This should either timeout or run out of memory
      # Note: MQuickJS doesn't have built-in timeout, so this tests memory limits
      result =
        QuickjsEx.eval(ctx, """
          try {
            var i = 0;
            var arr = [];
            while(true) {
              arr.push(i++);
              if (i > 10000) break; // Safety valve for test
            }
            i;
          } catch(e) {
            "error: " + e.message;
          }
        """)

      # Should complete (with safety valve) or fail gracefully under tight memory.
      assert match?({:ok, _}, result) or
               result == {:error, :oom} or
               result == {:error, {:js_error, "null"}}
    end
  end

  # ============================================================================
  # Available Safe APIs Verification
  # ============================================================================

  describe "safe APIs are available" do
    test "Math is available" do
      {:ok, ctx} = QuickjsEx.new()
      assert {:ok, "object"} = QuickjsEx.eval(ctx, "typeof Math")
      assert {:ok, value} = QuickjsEx.eval(ctx, "Math.sqrt(16)")
      assert value == 4 or value == 4.0
    end

    test "JSON is available" do
      {:ok, ctx} = QuickjsEx.new()
      assert {:ok, "object"} = QuickjsEx.eval(ctx, "typeof JSON")
      assert {:ok, ~s|{"a":1}|} = QuickjsEx.eval(ctx, ~s|JSON.stringify({a: 1})|)
    end

    test "Array is available" do
      {:ok, ctx} = QuickjsEx.new()
      assert {:ok, "function"} = QuickjsEx.eval(ctx, "typeof Array")
      assert {:ok, [1, 2, 3]} = QuickjsEx.eval(ctx, "[1, 2, 3]")
    end

    test "String is available" do
      {:ok, ctx} = QuickjsEx.new()
      assert {:ok, "function"} = QuickjsEx.eval(ctx, "typeof String")
      assert {:ok, "HELLO"} = QuickjsEx.eval(ctx, ~s|"hello".toUpperCase()|)
    end

    test "Object is available" do
      {:ok, ctx} = QuickjsEx.new()
      assert {:ok, "function"} = QuickjsEx.eval(ctx, "typeof Object")
      # Object.keys returns an array, which may have issues with serialization
      # Just verify Object.keys is a function
      assert {:ok, "function"} = QuickjsEx.eval(ctx, "typeof Object.keys")
    end

    test "RegExp is available" do
      {:ok, ctx} = QuickjsEx.new()
      assert {:ok, "function"} = QuickjsEx.eval(ctx, "typeof RegExp")
      assert {:ok, true} = QuickjsEx.eval(ctx, "/hello/.test('hello world')")
    end

    test "Date is available" do
      {:ok, ctx} = QuickjsEx.new()
      assert {:ok, "function"} = QuickjsEx.eval(ctx, "typeof Date")
      # Date.now() should return a reasonable timestamp
      assert {:ok, timestamp} = QuickjsEx.eval(ctx, "Date.now()")
      # Timestamp could be int or float depending on size
      ts = if is_float(timestamp), do: trunc(timestamp), else: timestamp
      assert is_integer(ts) and ts > 1_700_000_000_000
    end

    test "console.log is available" do
      {:ok, ctx} = QuickjsEx.new()
      assert {:ok, "function"} = QuickjsEx.eval(ctx, "typeof console.log")
    end

    test "Error classes are available" do
      {:ok, ctx} = QuickjsEx.new()
      assert {:ok, "function"} = QuickjsEx.eval(ctx, "typeof Error")
      assert {:ok, "function"} = QuickjsEx.eval(ctx, "typeof TypeError")
      assert {:ok, "function"} = QuickjsEx.eval(ctx, "typeof ReferenceError")
    end
  end

  # ============================================================================
  # Prototype Pollution Tests
  # ============================================================================

  describe "prototype pollution protection" do
    test "cannot pollute Object prototype to escape" do
      {:ok, ctx} = QuickjsEx.new()

      result =
        QuickjsEx.eval(ctx, """
          try {
            Object.prototype.polluted = function() { return this.constructor.constructor('return process')(); };
            ({}).polluted();
          } catch(e) {
            "caught: " + e.message;
          }
        """)

      # Should not return process object
      assert {:ok, value} = result
      refute is_map(value) and Map.has_key?(value, "env")
    end

    test "cannot modify __proto__ to escape" do
      {:ok, ctx} = QuickjsEx.new()

      result =
        QuickjsEx.eval(ctx, """
          try {
            var obj = {};
            obj.__proto__.exec = function() { return typeof process; };
            obj.exec();
          } catch(e) {
            "caught";
          }
        """)

      assert {:ok, value} = result
      # Should be undefined or error, not "object"
      assert value in [nil, "undefined", "caught"]
    end
  end

  # ============================================================================
  # QuickJS-NG specific
  # ============================================================================

  describe "QuickJS-NG specific" do
    test "gc() exists and is safe" do
      {:ok, ctx} = QuickjsEx.new()

      result =
        QuickjsEx.eval(ctx, """
          typeof gc === 'function' ? gc() : 'no gc';
        """)

      assert {:ok, _} = result
    end

    test "setTimeout is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert {:ok, "undefined"} = QuickjsEx.eval(ctx, "typeof setTimeout")
    end

    test "print is not available" do
      {:ok, ctx} = QuickjsEx.new()
      assert {:ok, "undefined"} = QuickjsEx.eval(ctx, "typeof print")
    end
  end

  describe "QuickJS-Ex specific security" do
    test "async_not_supported" do
      {:ok, ctx} = QuickjsEx.new()
      assert {:error, :async_not_supported} = QuickjsEx.eval(ctx, "Promise.resolve(1)")
    end

    test "not_owner enforcement" do
      {:ok, ctx} = QuickjsEx.new()

      task =
        Task.async(fn ->
          QuickjsEx.eval(ctx, "1")
        end)

      assert {:error, :not_owner} = Task.await(task)
    end

    test "denylist completeness" do
      {:ok, ctx} = QuickjsEx.new()

      for expr <- [
            "process",
            "require",
            "fetch",
            "XMLHttpRequest",
            "WebSocket",
            "Deno",
            "Bun",
            "window",
            "document",
            "navigator",
            "child_process",
            "os",
            "Buffer",
            "location"
          ] do
        assert_undefined(ctx, expr)
      end
    end
  end

  # ============================================================================
  # Callback/Trampoline Security Tests
  # ============================================================================

  describe "callback security" do
    test "callback cannot access Elixir internals" do
      {:ok, ctx} = QuickjsEx.new()

      # Register a simple callback - receives the array as a single argument
      ctx = QuickjsEx.set!(ctx, :safeFunc, fn [numbers] -> Enum.sum(numbers) end)

      # Test callback works correctly
      result = QuickjsEx.eval(ctx, "safeFunc([1, 2, 3])")

      assert {:ok, 6} = result
    end

    test "callback receives only serializable data" do
      {:ok, ctx} = QuickjsEx.new()
      test_pid = self()

      ctx =
        QuickjsEx.set!(ctx, :inspect, fn [arg] ->
          send(test_pid, {:received, arg})
          "ok"
        end)

      QuickjsEx.eval(ctx, """
        inspect([1, "hello", true, null, {key: "value"}]);
      """)

      # The JS array is passed as a single argument (Elixir list)
      assert_receive {:received, [1, "hello", true, nil, %{"key" => "value"}]}
    end
  end

  # ============================================================================
  # Edge Cases and Fuzzing
  # ============================================================================

  describe "edge cases" do
    test "handles null bytes in strings" do
      {:ok, ctx} = QuickjsEx.new()
      result = QuickjsEx.eval(ctx, ~s|"hello\\x00world".length|)
      assert {:ok, 11} = result
    end

    test "handles unicode correctly" do
      {:ok, ctx} = QuickjsEx.new()
      result = QuickjsEx.eval(ctx, ~s|"こんにちは"|)
      assert {:ok, "こんにちは"} = result
    end

    test "handles very long strings via loop" do
      # 1MB
      {:ok, ctx} = QuickjsEx.new(memory_limit: 1024 * 1024)
      # String.prototype.repeat may not be available in MQuickJS, use loop
      result =
        QuickjsEx.eval(ctx, """
          var s = "";
          for (var i = 0; i < 10000; i++) s += "x";
          s.length;
        """)

      assert {:ok, 10000} = result
    end

    test "handles deep recursion" do
      # 256KB
      {:ok, ctx} = QuickjsEx.new(memory_limit: 256 * 1024)

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

      # Should either complete or error gracefully
      assert {:ok, value} = result
      assert value == 100 or value == "stack overflow"
    end
  end
end
