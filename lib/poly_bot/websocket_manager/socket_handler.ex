defmodule PolyBot.WebSocketManager.Handler do
  @moduledoc """
  Websocket handler that records which assets have produced data.

  Inserts a `{{socket_pid, asset_id}}` row into the `:probe_seen_assets` ETS
  table for every event that names an asset, and does nothing else — it runs
  inside the socket process, so any heavier work here would skew the probe.
  """

  @behaviour Polymarket.WebSocket.Handler

  alias Polymarket.WebSocket
  alias Polymarket.WebSocket.Handler

  @impl Handler
  @spec handle_event(Handler.event(), WebSocket.t()) :: {:noreply, WebSocket.t()}
  def handle_event(_event, %WebSocket{} = state) do
    # IO.inspect(event, label: "event")
    {:noreply, state}
  end
end
