defmodule PolyBotWeb.TelemetryHistory do
  @moduledoc """
  Buffers recent telemetry datapoints per metric so LiveDashboard charts are
  pre-populated on mount instead of starting empty on every page refresh.

  Started by `PolyBotWeb.Telemetry` (dev only) with the list of metrics to
  track. The router hands `metrics_history: {__MODULE__, :metrics_history, []}`
  to `live_dashboard`, which calls back here on every chart mount.
  """

  use GenServer

  alias Phoenix.LiveDashboard.TelemetryListener

  # datapoints kept per metric; buffers are pruned once they reach twice this.
  @buffer_size 50

  # ---------------------------------------------------------------------------#
  #                              Public functions                              #
  # ---------------------------------------------------------------------------#

  @spec start_link([Telemetry.Metrics.t()]) :: GenServer.on_start()
  def start_link(metrics) do
    GenServer.start_link(__MODULE__, metrics, name: __MODULE__)
  end

  @doc """
  Return the buffered datapoints for `metric`, oldest first.

  ## Examples

      iex> metrics_history(metric)
      [%{label: nil, measurement: 1, time: 1751541000000000}]

  """
  @spec metrics_history(Telemetry.Metrics.t()) :: [map()]
  def metrics_history(metric) do
    GenServer.call(__MODULE__, {:history, metric.name})
  end

  @doc false
  # telemetry handler: runs in the emitting process, so extract the datapoint
  # there (exactly like LiveDashboard's own listener) and only cast a hit.
  def handle_event(_event_name, measurements, metadata, metric) do
    if datapoint = TelemetryListener.extract_datapoint_for_metric(metric, measurements, metadata) do
      GenServer.cast(__MODULE__, {:datapoint, metric.name, datapoint})
    end
  end

  # ---------------------------------------------------------------------------#
  #                                 Callbacks                                  #
  # ---------------------------------------------------------------------------#

  @impl true
  def init(metrics) do
    for metric <- metrics do
      :telemetry.attach(
        {__MODULE__, metric.name},
        metric.event_name,
        &__MODULE__.handle_event/4,
        metric
      )
    end

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:datapoint, name, datapoint}, buffers) do
    {:noreply, Map.update(buffers, name, {1, [datapoint]}, &push(&1, datapoint))}
  end

  @impl true
  def handle_call({:history, name}, _from, buffers) do
    entries =
      case buffers do
        %{^name => {_count, entries}} -> entries |> Enum.take(@buffer_size) |> Enum.reverse()
        %{} -> []
      end

    {:reply, entries, buffers}
  end

  # ---------------------------------------------------------------------------#
  #                                  Helpers                                   #
  # ---------------------------------------------------------------------------#

  # newest-first prepend; prune lazily at 2x size so inserts stay O(1) amortized.
  defp push({count, entries}, datapoint) when count >= @buffer_size * 2 do
    {@buffer_size + 1, [datapoint | Enum.take(entries, @buffer_size)]}
  end

  defp push({count, entries}, datapoint), do: {count + 1, [datapoint | entries]}
end
