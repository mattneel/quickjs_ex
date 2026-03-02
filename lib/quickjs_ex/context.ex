defmodule QuickjsEx.Context do
  @moduledoc """
  A JavaScript execution context.

  This struct holds the reference to the underlying QuickJS context
  and tracks registered callbacks and loaded API modules.

  You typically don't interact with this module directly - use the
  functions in `QuickjsEx` instead. Treat this struct as an opaque value
  that is passed around; only `QuickjsEx.*` functions should mutate it.
  """

  @type callback_meta :: %{
          fun: function(),
          uses_state: boolean(),
          variadic: boolean()
        }

  @type callback_entry :: function() | callback_meta()

  defstruct [:ref, callbacks: %{}, loaded_apis: [], private: %{}, poisoned?: false]

  @type t :: %__MODULE__{
          ref: reference(),
          callbacks: %{String.t() => callback_entry()},
          loaded_apis: [module()],
          private: map(),
          poisoned?: boolean()
        }

  @doc """
  Creates a new Context struct wrapping the given NIF reference.

  Called internally by `QuickjsEx.new/1`.
  """
  @spec new(reference()) :: t()
  def new(ref) when is_reference(ref) do
    %__MODULE__{ref: ref}
  end

  @doc """
  Register a simple callback function (legacy format).
  """
  @spec put_callback(t(), atom() | String.t(), function()) :: t()
  def put_callback(%__MODULE__{} = ctx, name, fun) when is_function(fun) do
    %{ctx | callbacks: Map.put(ctx.callbacks, to_string(name), fun)}
  end

  @doc """
  Register a callback with metadata (from API module).
  """
  @spec put_callback_meta(t(), String.t(), function(), boolean(), boolean()) :: t()
  def put_callback_meta(%__MODULE__{} = ctx, name, fun, uses_state, variadic)
      when is_function(fun) and is_boolean(uses_state) and is_boolean(variadic) do
    meta = %{fun: fun, uses_state: uses_state, variadic: variadic}
    %{ctx | callbacks: Map.put(ctx.callbacks, name, meta)}
  end

  @doc """
  Track that an API module has been loaded.
  """
  @spec add_loaded_api(t(), module()) :: t()
  def add_loaded_api(%__MODULE__{loaded_apis: apis} = ctx, module) when is_atom(module) do
    %{ctx | loaded_apis: [module | apis]}
  end

  @doc """
  Returns `true` if any callbacks have been registered on this context.
  """
  @spec has_callbacks?(t()) :: boolean()
  def has_callbacks?(%__MODULE__{callbacks: callbacks}) do
    map_size(callbacks) > 0
  end

  @doc """
  Marks the context as poisoned (non-recoverable).

  Returns the updated struct.
  """
  @spec poison(t()) :: t()
  def poison(%__MODULE__{} = ctx) do
    %{ctx | poisoned?: true}
  end

  @doc """
  Returns `true` if the context has been marked as poisoned and can no
  longer be used.
  """
  @spec poisoned?(t()) :: boolean()
  def poisoned?(%__MODULE__{poisoned?: poisoned?}) do
    poisoned?
  end
end
