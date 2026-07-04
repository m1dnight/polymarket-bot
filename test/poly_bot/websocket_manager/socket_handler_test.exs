defmodule PolyBot.WebSocketManager.HandlerTest do
  @moduledoc """
  Exercises `PolyBot.WebSocketManager.Handler` through its public callback,
  against the app-owned shared `:market_state` table (unique asset ids keep
  async tests apart).
  """

  use ExUnit.Case, async: true

  alias PolyBot.MarketData
  alias PolyBot.Stats
  alias PolyBot.WebSocketManager.Handler
  alias Polymarket.Schemas.LastTradePriceEvent
  alias Polymarket.Schemas.PriceChange
  alias Polymarket.Schemas.PriceChangeEvent
  alias Polymarket.WebSocket

  test "records price_change events into the top-of-book table and notifies" do
    id = "asset-#{System.unique_integer([:positive])}"
    :ok = MarketData.subscribe(id)

    event = %PriceChangeEvent{
      market: "0xmarket",
      timestamp: 1_779_656_681_214,
      event_type: "price_change",
      price_changes: [%PriceChange{asset_id: id, best_bid: 0.12, best_ask: 0.15, side: "BUY"}]
    }

    before = Stats.get(:ws_messages)

    assert {:noreply, %WebSocket{}} = Handler.handle_event(event, %WebSocket{})

    assert {:ok, {^id, 0.12, 0.15, 1_779_656_681_214, _recv_ts}} = MarketData.get(id)
    assert_received {:dirty, ^id}
    # other async tests may bump the counter concurrently, so only assert >=.
    assert Stats.get(:ws_messages) >= before + 1
  end

  test "counts but otherwise ignores other event types" do
    before = Stats.get(:ws_messages)

    assert {:noreply, %WebSocket{}} = Handler.handle_event(%LastTradePriceEvent{}, %WebSocket{})

    assert Stats.get(:ws_messages) >= before + 1
  end
end
