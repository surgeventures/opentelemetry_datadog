defmodule OpentelemetryDatadog.Exporter do
  @behaviour :otel_exporter

  require Record
  @deps_dir Mix.Project.deps_path()
  Record.defrecord(
    :span,
    Record.extract(:span, from: "#{@deps_dir}/opentelemetry/include/otel_span.hrl")
  )

  Record.defrecord(
    :attributes,
    Record.extract(:attributes, from: "#{@deps_dir}/opentelemetry_api/src/otel_attributes.erl")
  )

  defmodule State do
    @type t :: %State{}

    defstruct [
      :http,
      :host,
      :port,
      :service_name,
      :container_id
    ]
  end

  @headers [
    {"Content-Type", "application/msgpack"},
    {"Datadog-Meta-Lang", "elixir"},
    {"Datadog-Meta-Lang-Version", System.version()},
    {"Datadog-Meta-Tracer-Version", Application.spec(:opentelemetry_datadog)[:vsn]}
  ]

  alias OpentelemetryDatadog.Mapper
  @mappers [
    {Mapper.LiftError, []},
    {Mapper.AlwaysSample, []},
  ]

  @impl true
  def init(config) do
    state = %State{
      host: Keyword.fetch!(config, :host),
      port: Keyword.fetch!(config, :port),
      service_name: Keyword.fetch!(config, :service_name),
      # http: HTTPoison,
      container_id: get_container_id()
    }

    {:ok, state}
  end

  @impl true
  def export(:traces, tid, resource, %{container_id: container_id} = state) do
    IO.inspect({:traces_resource, resource})

    formatted =
      :ets.foldl(
        fn span, acc ->
          # IO.inspect(span(span))
          # IO.inspect(format_span(span, state))
          [format_span(span, state) | acc]
        end,
        [],
        tid
      )

    count = Enum.count(formatted)
    headers = @headers ++ [{"X-Datadog-Trace-Count", count}]
    headers = headers ++ List.wrap(if container_id, do: {"Datadog-Container-ID", container_id})

    response =
      formatted
      |> encode()
      |> push(headers, state)

    # IO.inspect({:trace_response, response})

    case response do
      {:ok, %{status: 200} = resp} ->
        # https://github.com/DataDog/datadog-agent/issues/3031
        %{"rate_by_service" => _rate_by_service} = resp.body
        nil

      _ ->
        IO.inspect({:trace_error_response, response})
    end

    :ok
  end

  def export(:metrics, _tid, _resource, _state) do
    :ok
  end

  @impl true
  def shutdown(_state) do
    :ok
  end

  defp encode(data) do
    data
    |> deep_remove_nils()
    |> Msgpax.pack!(data)
  end

  def push(body, headers, %State{host: host, port: port}) do
    Req.put(
      "#{host}:#{port}/v0.4/traces",
      body: body,
      headers: headers,
      retry: :transient,
      retry_delay: &retry_delay/1,
      retry_log_level: false
    )
  end

  defp retry_delay(attempt) do
    # 3 retries with 10% jitter, example delays: 484ms, 945ms, 1908ms
    trunc(Integer.pow(2, attempt) * 500 * (1 - 0.1 * :rand.uniform()))
  end

  def format_span(span_record, %{service_name: service_name}) do
    span = span(span_record)
    attributes = attributes(Keyword.fetch!(span, :attributes))

    events = :otel_events.list(Keyword.fetch!(span, :events))

    if events != [] do
      IO.inspect({:events, events})
    end

    dd_span_kind = Atom.to_string(Keyword.fetch!(span, :kind))

    start_time_nanos = :opentelemetry.timestamp_to_nano(Keyword.fetch!(span, :start_time))
    end_time_nanos = :opentelemetry.timestamp_to_nano(Keyword.fetch!(span, :end_time))

    {error_code, error_meta} =
      case Keyword.fetch!(span, :status) do
        :undefined ->
          {0, %{}}

        {:status, :unset, _} ->
          {0, %{}}

        {:status, :ok, _} ->
          {0, %{}}

        {:status, :error, msg} ->
          error_event =
            events
            |> Enum.reverse()
            |> Enum.find(fn
              {:event, _time, "exception", _attrs} -> true
              _ -> false
            end)

          case error_event do
            nil ->
              {1, %{"error.message" => msg}}

            {:event, _time, "exception", attrs} ->
              attrs = Keyword.fetch!(attributes(attrs), :map)
              {1, attrs}
          end
      end

    meta =
      Keyword.fetch!(attributes, :map)
      |> Map.put("span.kind", dd_span_kind)
      |> Map.merge(error_meta)
      |> Enum.map(fn
        {k, v} -> {k, term_to_string(v)}
      end)
      |> Enum.into(%{})
      |> fix_error_keys()
      |> Map.put("manual.keep", "1")
      |> Map.put("env", "hans-local-testing")

    {:instrumentation_scope, scope_name, _version, _opts} =
      Keyword.fetch!(span, :instrumentation_scope)

    name = Keyword.fetch!(span, :name)
    resource = get_resource(scope_name, meta) || name

    type = get_type(scope_name, meta)

    meta =
      meta
      |> Map.put("evaled.name", name)
      |> Map.put("evaled.resource", resource)
      |> Map.put("evaled.type", type)
      |> Map.put("evaled.service", get_service_name(service_name, meta))

    # Service, Operation, Resource

    IO.inspect(meta)

    # TODO group by trace_id
    [
      %{
        trace_id: id_to_datadog_id(Keyword.fetch!(span, :trace_id)),
        span_id: Keyword.fetch!(span, :span_id),
        name: name,
        start: start_time_nanos,
        duration: end_time_nanos - start_time_nanos,
        parent_id: nil_if_undefined(Keyword.fetch!(span, :parent_span_id)),
        # TODO set to 1 if error
        error: error_code,
        # TODO likely not right
        resource: resource,
        # TODO from traces_resource
        service: get_service_name(service_name, meta),
        # TODO map according to https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/712278378b0e3d04cd6881c020b266b9fea56113/receiver/datadogreceiver/translator.go#L113
        # (in reverse)
        type: type,
        # TODO https://github.com/spandex-project/spandex_datadog/blob/master/lib/spandex_datadog/api_server.ex#L215C15-L215C15
        meta: meta
        # metrics: %{}
      }
    ]
  end

  def nil_if_undefined(:undefined), do: nil
  def nil_if_undefined(value), do: value

  def fix_error_keys(map) do
    map
    |> Enum.map(fn
      {:"exception.message", v} -> {:"error.message", v}
      {:"exception.stacktrace", v} -> {:"error.stack", v}
      {:"exception.type", v} -> {:"error.type", v}
      kv -> kv
    end)
    |> Enum.into(%{})
  end

  @cgroup_uuid "[0-9a-f]{8}[-_][0-9a-f]{4}[-_][0-9a-f]{4}[-_][0-9a-f]{4}[-_][0-9a-f]{12}"
  @cgroup_ctnr "[0-9a-f]{64}"
  @cgroup_task "[0-9a-f]{32}-\\d+"
  @cgroup_regex Regex.compile!(
                  ".*(#{@cgroup_uuid}|#{@cgroup_ctnr}|#{@cgroup_task})(?:\\.scope)?$",
                  "m"
                )

  defp get_container_id() do
    with {:ok, file_binary} <- File.read("/proc/self/cgroup"),
         [_, container_id] <- Regex.run(@cgroup_regex, file_binary) do
      container_id
    else
      _ -> nil
    end
  end

  @spec deep_remove_nils(term) :: term
  defp deep_remove_nils(term) when is_map(term) do
    term
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {k, deep_remove_nils(v)} end)
    |> Enum.into(%{})
  end

  defp deep_remove_nils(term) when is_list(term) do
    if Keyword.keyword?(term) do
      term
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {k, deep_remove_nils(v)} end)
    else
      Enum.map(term, &deep_remove_nils/1)
    end
  end

  defp deep_remove_nils(term), do: term

  defp id_to_datadog_id(nil) do
    nil
  end

  defp id_to_datadog_id(trace_id) do
    <<_lower::integer-size(64), upper::integer-size(64)>> = <<trace_id::integer-size(128)>>
    upper
  end

  defp term_to_string(term) when is_boolean(term), do: inspect(term)
  defp term_to_string(term) when is_binary(term), do: term
  defp term_to_string(term) when is_atom(term), do: term
  defp term_to_string(term), do: inspect(term)

  def get_resource("opentelemetry_cowboy", %{:"http.target" => target}), do: target
  def get_resource("opentelemetry_ecto", %{:"db.statement" => statement}), do: statement
  def get_resource(_, _), do: nil

  def get_type("opentelemetry_ecto", _meta), do: "db"
  def get_type("opentelemetry_liveview", _meta), do: "web"
  def get_type("opentelemetry_phoenix", _meta), do: "web"
  def get_type(_, _), do: "custom"

  def get_service_name(_, %{"db.url": url, "db.instance": name}) do
    %URI{host: host} = URI.parse(url)
    "#{host}/#{name}"
  end
  def get_service_name(service_name, _), do: service_name

end
