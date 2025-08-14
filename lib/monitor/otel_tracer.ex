defmodule Monitor.OTelTracer do
  @moduledoc """
  OpenTelemetry-compatible tracing wrapper module.

  This module provides a convenient interface for creating spans and managing
  trace context using OpenTelemetry APIs in Elixir applications.

  ## Main Functions

  - `span/3` - Creates a new span and executes a function within it
  - `continue_trace_lazy/1` - Continues execution within existing trace context
  - `set_attribute/2` - Sets an attribute on the current span
  - `add_event/2` - Adds an event to the current span

  ## Additional Utilities

  - `set_attributes/1` - Sets multiple attributes at once
  - `record_exception/2` - Records an exception on the current span
  - `set_status/2` - Sets the span status
  - `current_span_ctx/0` - Gets the current span context
  """

  require Logger
  require OpenTelemetry.Tracer, as: Tracer
  alias OpenTelemetry.Span

  @doc """
  Creates a new span with the given name and executes the provided function within it.

  ## Parameters

  - `name`: The name of the span
  - `opts`: Options for the span (optional)
    - `:attributes` - Map of attributes to set on the span
    - `:kind` - Span kind (`:internal`, `:server`, `:client`, `:producer`, `:consumer`)
    - `:links` - List of span links
  - `fun`: Function to execute within the span context

  ## Examples

      iex> Monitor.OTelTracer.span("user.login", fn ->
      ...>   # Login logic here
      ...>   {:ok, "user_id"}
      ...> end)
      {:ok, "user_id"}
      
      iex> Monitor.OTelTracer.span("database.query", [attributes: %{table: "users"}], fn ->
      ...>   # Database query logic
      ...>   :ok
      ...> end)
      :ok
  """
  @spec span(String.t(), keyword() | function(), function() | nil) :: any()
  def span(name, opts \\ [], fun)

  def span(name, opts, nil) when is_function(opts) do
    span(name, [], opts)
  end

  def span(name, opts, fun) when is_binary(name) and is_list(opts) and is_function(fun) do
    attributes = Keyword.get(opts, :attributes, %{})
    kind = Keyword.get(opts, :kind, :internal)
    links = Keyword.get(opts, :links, [])

    Tracer.with_span name, %{
      kind: kind,
      attributes: attributes,
      links: links
    } do
      fun.()
    end
  end

  @doc """
  Continues an existing trace by lazily evaluating the provided function.

  This function allows you to continue tracing in a context where a trace
  may or may not already exist. It's useful for asynchronous operations
  or when working with external libraries.

  ## Parameters

  - `fun`: Function to execute, potentially within an existing trace context

  ## Examples

      iex> Monitor.OTelTracer.continue_trace_lazy(fn ->
      ...>   # This will run in the current trace context if one exists
      ...>   perform_background_task()
      ...> end)
      :ok
  """
  @spec continue_trace_lazy(function()) :: any()
  def continue_trace_lazy(fun) when is_function(fun) do
    case Tracer.current_span_ctx() do
      :undefined ->
        # No active span context, execute function normally
        fun.()

      _span_ctx ->
        # Active span context exists, execute within it
        fun.()
    end
  end

  @doc """
  Sets an attribute on the current active span.

  ## Parameters

  - `key`: The attribute key (string or atom)
  - `value`: The attribute value (string, number, boolean, or list of strings/numbers/booleans)

  ## Examples

      iex> Monitor.OTelTracer.set_attribute("user.id", "123")
      :ok
      
      iex> Monitor.OTelTracer.set_attribute(:http_status_code, 200)
      :ok
      
      iex> Monitor.OTelTracer.set_attribute("tags", ["important", "user-action"])
      :ok
  """
  @spec set_attribute(String.t() | atom(), any()) :: :ok
  def set_attribute(key, value) when is_binary(key) or is_atom(key) do
    case Tracer.current_span_ctx() do
      :undefined ->
        Logger.warning("Attempted to set attribute #{inspect(key)} but no active span exists")
        :ok

      span_ctx ->
        Span.set_attribute(span_ctx, key, value)
        :ok
    end
  end

  @doc """
  Adds an event to the current active span.

  ## Parameters

  - `name`: The event name
  - `attributes`: Map of attributes for the event (optional)

  ## Examples

      iex> Monitor.OTelTracer.add_event("cache.miss")
      :ok
      
      iex> Monitor.OTelTracer.add_event("user.action", %{action: "login", user_id: "123"})
      :ok
  """
  @spec add_event(String.t(), map()) :: :ok
  def add_event(name, attributes \\ %{})
      when is_binary(name) and is_map(attributes) do
    case Tracer.current_span_ctx() do
      :undefined ->
        Logger.warning("Attempted to add event #{inspect(name)} but no active span exists")
        :ok

      span_ctx ->
        Span.add_event(span_ctx, name, attributes)
        :ok
    end
  end

  @doc """
  Sets multiple attributes on the current active span.

  ## Parameters

  - `attributes`: Map of key-value pairs to set as attributes

  ## Examples

      iex> Monitor.OTelTracer.set_attributes(%{
      ...>   "user.id" => "123",
      ...>   "http.method" => "GET",
      ...>   "http.status_code" => 200
      ...> })
      :ok
  """
  @spec set_attributes(map()) :: :ok
  def set_attributes(attributes) when is_map(attributes) do
    case Tracer.current_span_ctx() do
      :undefined ->
        Logger.warning("Attempted to set attributes but no active span exists")
        :ok

      span_ctx ->
        Span.set_attributes(span_ctx, attributes)
        :ok
    end
  end

  @doc """
  Records an exception in the current span.

  ## Parameters

  - `exception`: The exception to record
  - `attributes`: Additional attributes for the exception (optional)

  ## Examples

      iex> try do
      ...>   raise "Something went wrong"
      ...> rescue
      ...>   e -> Monitor.OTelTracer.record_exception(e)
      ...> end
      :ok
  """
  @spec record_exception(Exception.t(), map()) :: :ok
  def record_exception(exception, attributes \\ %{}) do
    case Tracer.current_span_ctx() do
      :undefined ->
        Logger.warning("Attempted to record exception but no active span exists")
        :ok

      span_ctx ->
        if map_size(attributes) == 0 do
          Span.record_exception(span_ctx, exception)
        else
          # Convert attributes to list format for record_exception
          attr_list = Enum.to_list(attributes)

          stacktrace =
            Process.info(self(), :current_stacktrace)
            |> elem(1)
            |> Enum.drop(3)

          Span.record_exception(span_ctx, exception, stacktrace, attr_list)
        end

        :ok
    end
  end

  @doc """
  Sets the status of the current span.

  ## Parameters

  - `status`: The status to set (`:ok`, `:error`, or `:cancelled`)
  - `description`: Optional description of the status

  ## Examples

      iex> Monitor.OTelTracer.set_status(:ok)
      :ok
      
      iex> Monitor.OTelTracer.set_status(:error, "Database connection failed")
      :ok
  """
  @spec set_status(atom(), String.t()) :: :ok
  def set_status(status, description \\ "")
      when status in [:ok, :error, :cancelled] and is_binary(description) do
    case Tracer.current_span_ctx() do
      :undefined ->
        Logger.warning("Attempted to set span status but no active span exists")
        :ok

      span_ctx ->
        Span.set_status(span_ctx, status)
        :ok
    end
  end

  @doc """
  Returns the current span context, if any.

  ## Examples

      iex> Monitor.OTelTracer.current_span_ctx()
      :undefined
      
      # Within a span:
      iex> Monitor.OTelTracer.trace("test", fn ->
      ...>   Monitor.OTelTracer.current_span_ctx()
      ...> end)
      %OpenTelemetry.SpanCtx{...}
  """
  @spec current_span_ctx() :: any() | :undefined
  def current_span_ctx do
    Tracer.current_span_ctx()
  end
end
