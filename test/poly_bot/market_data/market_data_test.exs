defmodule PolyBot.MarketDataTest do
  @moduledoc """
  Exercises `PolyBot.MarketData` against the shared `:market_state` table
  (write/read/notify paths, using unique asset ids so async tests never
  collide) and against private per-test tables (staleness sweeps, whose counts
  must not see other tests' rows).
  """

  use ExUnit.Case, async: true

  alias PolyBot.MarketData
  alias Polymarket.Schemas.PriceChange
  alias Polymarket.Schemas.PriceChangeEvent

  @exchange_ts 1_779_656_681_214

  # ---------------------------------------------------------------------------#
  #                          record_price_changes/2                            #
  # ---------------------------------------------------------------------------#

  describe "record_price_changes/2" do
    test "stores the top of book per asset, latest write wins" do
      id = unique_id()

      assert :ok = MarketData.record_price_changes(price_change_event([{id, 0.42, 0.44}]))
      assert {:ok, {^id, 0.42, 0.44, @exchange_ts, recv_ts}} = MarketData.get(id)
      assert is_integer(recv_ts)

      assert :ok = MarketData.record_price_changes(price_change_event([{id, 0.43, 0.45}]))
      assert {:ok, {^id, 0.43, 0.45, @exchange_ts, _recv_ts}} = MarketData.get(id)
    end

    test "records every change of a batched event" do
      {id_a, id_b} = {unique_id(), unique_id()}

      event = price_change_event([{id_a, 0.10, 0.12}, {id_b, 0.90, 0.92}])
      assert :ok = MarketData.record_price_changes(event)

      assert {:ok, {^id_a, 0.10, 0.12, _, _}} = MarketData.get(id_a)
      assert {:ok, {^id_b, 0.90, 0.92, _, _}} = MarketData.get(id_b)
    end

    test "notifies subscribers of each recorded asset" do
      id = unique_id()
      :ok = MarketData.subscribe(id)

      assert :ok = MarketData.record_price_changes(price_change_event([{id, 0.42, 0.44}]))

      # Registry.dispatch runs in the caller, so the message is already here.
      assert_received {:dirty, ^id}
    end

    test "does not notify subscribers of other assets" do
      :ok = MarketData.subscribe(unique_id())

      assert :ok = MarketData.record_price_changes(price_change_event([{unique_id(), 0.4, 0.6}]))

      refute_received {:dirty, _id}
    end

    test "skips changes missing a side of the book" do
      {id_a, id_b} = {unique_id(), unique_id()}
      :ok = MarketData.subscribe(id_a)

      event = price_change_event([{id_a, nil, 0.44}, {id_b, 0.42, nil}])
      assert :ok = MarketData.record_price_changes(event)

      assert MarketData.get(id_a) == :error
      assert MarketData.get(id_b) == :error
      refute_received {:dirty, _id}
    end

    test "a partial change does not clobber a complete row" do
      id = unique_id()

      assert :ok = MarketData.record_price_changes(price_change_event([{id, 0.42, 0.44}]))
      assert :ok = MarketData.record_price_changes(price_change_event([{id, nil, 0.50}]))

      assert {:ok, {^id, 0.42, 0.44, _, _}} = MarketData.get(id)
    end
  end

  # ---------------------------------------------------------------------------#
  #                                  get/2                                     #
  # ---------------------------------------------------------------------------#

  describe "get/2" do
    test "returns :error for an asset without any recorded price change" do
      assert MarketData.get(unique_id()) == :error
    end
  end

  # ---------------------------------------------------------------------------#
  #                            sweep_staleness/2                               #
  # ---------------------------------------------------------------------------#

  describe "sweep_staleness/2" do
    test "counts stale rows and emits the summary as telemetry" do
      table = MarketData.create_table(:market_data_test_sweep)
      ref = attach_staleness_handler()

      now = System.monotonic_time(:millisecond)
      :ets.insert(table, [{"fresh", 0.4, 0.6, 0, now}, {"stale", 0.4, 0.6, 0, now - 100_000}])

      summary = MarketData.sweep_staleness(30_000, table)

      assert summary.total == 2
      assert summary.stale == 1
      assert summary.max_ms >= 100_000
      assert summary.min_ms < 30_000

      assert_received {[:poly_bot, :market_data, :staleness], ^ref, measurements, metadata}
      assert measurements == summary
      assert metadata == %{threshold_ms: 30_000}
    end

    test "returns zeros for an empty table" do
      table = MarketData.create_table(:market_data_test_sweep_empty)

      assert MarketData.sweep_staleness(1_000, table) ==
               %{total: 0, stale: 0, max_ms: 0, min_ms: 0}
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  defp unique_id, do: "asset-#{System.unique_integer([:positive])}"

  defp attach_staleness_handler do
    :telemetry_test.attach_event_handlers(self(), [[:poly_bot, :market_data, :staleness]])
  end

  defp price_change_event(changes) do
    %PriceChangeEvent{
      market: "0xmarket",
      timestamp: @exchange_ts,
      event_type: "price_change",
      price_changes:
        Enum.map(changes, fn {id, bid, ask} ->
          %PriceChange{asset_id: id, best_bid: bid, best_ask: ask, side: "BUY"}
        end)
    }
  end
end
