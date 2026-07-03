defmodule PolyBot.EventHandler do
  alias PolyBot.Contexts.EventLog

  def attach do
    :telemetry.attach_many(
      "websocket-logger",
      [[:poly_bot, :websocket, :connect], [:poly_bot, :websocket, :disconnect]],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(name, measurements, metadata, _config) do
    EventLog.log_event(inspect(name), measurements, metadata)
  end
end
