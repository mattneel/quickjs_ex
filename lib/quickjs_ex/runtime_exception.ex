defmodule QuickjsEx.RuntimeException do
  @moduledoc """
  Exception raised when JavaScript execution fails or an API function encounters an error.

  ## Fields

  - `message` - human-readable error text.
  - `category` - error category atom. One of:
    - `:timeout`
    - `:oom`
    - `:context_poisoned`
    - `:not_owner`
    - `:sandbox_violation`
    - `:async_not_supported`
    - `:internal_error`
    - `:js_error`
    - `:callback_error`
    - `:invalid_api_module`
  - `detail` - optional map with extra context, or `nil`.

  ## When it is raised

  Raised by bang-style APIs such as `eval!/2`, `get!/2`, `set!/3`, `load_api!/3`,
  and `get_private!/2` when an operation fails.

  ## Pattern matching

      try do
        QuickjsEx.eval!(ctx, "throw new Error('boom')")
      rescue
        e in QuickjsEx.RuntimeException ->
          e.category
      end
  """

  defexception [:message, :category, :detail]

  @type t :: %__MODULE__{
          message: String.t(),
          category: atom(),
          detail: map() | nil
        }

  @impl true
  def exception(reason) do
    case reason do
      :timeout ->
        %__MODULE__{message: "JavaScript execution timed out", category: :timeout, detail: nil}

      :oom ->
        %__MODULE__{
          message: "JavaScript context ran out of memory",
          category: :oom,
          detail: nil
        }

      :context_poisoned ->
        %__MODULE__{
          message: "JavaScript context is poisoned and can no longer be used",
          category: :context_poisoned,
          detail: nil
        }

      :not_owner ->
        %__MODULE__{
          message: "Current process does not own this JavaScript context",
          category: :not_owner,
          detail: nil
        }

      :sandbox_violation ->
        %__MODULE__{
          message: "JavaScript sandbox violation",
          category: :sandbox_violation,
          detail: nil
        }

      :async_not_supported ->
        %__MODULE__{
          message: "Promise/async execution is not supported",
          category: :async_not_supported,
          detail: nil
        }

      :internal_error ->
        %__MODULE__{
          message: "Internal JavaScript engine error",
          category: :internal_error,
          detail: nil
        }

      {:js_error, msg} ->
        %__MODULE__{
          message: "JavaScript error: #{msg}",
          category: :js_error,
          detail: %{message: msg}
        }

      {:callback_error, name, msg} ->
        %__MODULE__{
          message: "Callback error in #{name}: #{msg}",
          category: :callback_error,
          detail: %{callback_name: name, message: msg}
        }

      {:invalid_api_module, msg} ->
        %__MODULE__{
          message: "Invalid API module: #{msg}",
          category: :invalid_api_module,
          detail: %{message: msg}
        }

      other ->
        %__MODULE__{message: "Unknown error: #{inspect(other)}", category: :unknown, detail: nil}
    end
  end

  @impl true
  def message(%__MODULE__{message: message}), do: message
end
