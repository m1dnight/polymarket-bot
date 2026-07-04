defmodule PolyBotWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  # also the window the websocket message rate is averaged over.
  @poller_period_ms 10_000

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children =
      [
        # Telemetry poller will execute the given period measurements
        # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
        {:telemetry_poller, measurements: periodic_measurements(), period: @poller_period_ms}
        # Add reporters as children of your supervision tree.
        # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
      ] ++ history_child()

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # how often disconnects happen
      counter("poly_bot.websocket.connect.count"),
      counter("poly_bot.websocket.disconnect.count"),
      # incoming messages per second, averaged over the poller period.
      last_value("poly_bot.websocket.messages.rate",
        description: "Websocket messages per second"
      ),
      sum("poly_bot.websocket.subscribe.count"),
      # assets parked after a disconnect vs. resubscribed; the difference is
      # how many are currently outstanding.
      sum("poly_bot.websocket.park.count"),
      sum("poly_bot.websocket.restore.count"),
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("poly_bot.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("poly_bot.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("poly_bot.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("poly_bot.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("poly_bot.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  # buffers chart history for LiveDashboard, which is only mounted in dev.
  defp history_child do
    if Application.get_env(:poly_bot, :dev_routes) do
      [{PolyBotWeb.TelemetryHistory, metrics()}]
    else
      []
    end
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      {__MODULE__, :measure_ws_messages, []}
    ]
  end

  @doc false
  # Emits the websocket messages received since the last poll and their
  # per-second rate. Runs only in the poller process: `Stats.delta/1` is
  # single-consumer.
  @spec measure_ws_messages() :: :ok
  def measure_ws_messages do
    delta = PolyBot.Stats.delta(:ws_messages)
    rate = delta * 1_000 / @poller_period_ms

    :telemetry.execute([:poly_bot, :websocket, :messages], %{count: delta, rate: rate}, %{})
  end
end
