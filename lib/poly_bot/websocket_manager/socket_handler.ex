defmodule PolyBot.WebSocketManager.Handler do
  @moduledoc """
  Websocket handler for the Polymarket market feed.

  Runs inside the socket process, so it stays deliberately thin: every event
  bumps the `:ws_messages` counter in `PolyBot.Stats`, and `price_change`
  events are additionally recorded into the top-of-book table via
  `PolyBot.MarketData.record_price_changes/1` (one batched ETS insert plus
  dirty notifications). All other event types are counted but otherwise
  ignored for now.
  """

  @behaviour Polymarket.WebSocket.Handler

  require PolyBot.Stats, as: Stats

  alias PolyBot.MarketData
  alias Polymarket.Schemas.PriceChangeEvent
  alias Polymarket.WebSocket
  alias Polymarket.WebSocket.Handler

  @impl Handler
  @spec handle_event(Handler.event(), WebSocket.t()) :: {:noreply, WebSocket.t()}
  def handle_event(%PriceChangeEvent{} = event, %WebSocket{} = state) do
    Stats.increase(:ws_messages)
    MarketData.record_price_changes(event)
    {:noreply, state}
  end

  def handle_event(_event, %WebSocket{} = state) do
    Stats.increase(:ws_messages)
    {:noreply, state}
  end
end
