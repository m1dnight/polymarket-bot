defmodule PolyBotWeb.TelemetryTest do
  # the Stats counters and telemetry handlers are global.
  use ExUnit.Case, async: false

  require PolyBot.Stats, as: Stats

  @doc false
  # telemetry handler: forwards the measurements to the test process.
  @spec forward_event([atom()], map(), map(), %{pid: pid()}) :: {:messages, map()}
  def forward_event(_event, measurements, _metadata, %{pid: pid}) do
    send(pid, {:messages, measurements})
  end

  test "measure_ws_messages/0 emits the messages and rate since the last poll" do
    Stats.init()

    handler_id = {__MODULE__, self()}

    :telemetry.attach(
      handler_id,
      [:poly_bot, :websocket, :messages],
      &__MODULE__.forward_event/4,
      %{pid: self()}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Stats.increase(:ws_messages, 30)
    PolyBotWeb.Telemetry.measure_ws_messages()

    # 30 messages over the 10s poller period.
    assert_receive {:messages, %{count: 30, rate: 3.0}}

    # the next poll only covers increments since the previous one.
    PolyBotWeb.Telemetry.measure_ws_messages()
    assert_receive {:messages, %{count: 0, rate: 0.0}}
  end
end
