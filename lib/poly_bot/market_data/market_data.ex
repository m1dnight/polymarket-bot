defmodule PolyBot.MarketData do
  @moduledoc """
  Top-of-book market state: one flat ETS row per asset id, latest write wins.

  The write path runs inside the websocket processes:
  `PolyBot.WebSocketManager.Handler` calls `record_price_changes/1` for every
  `price_change` event, which stamps the receive time once, batch-inserts the
  rows, and notifies subscribers. All other event types (`book`,
  `last_trade_price`, ...) are ignored for now, so after a (re)connect an
  asset's row stays absent or stale until its first `price_change` arrives —
  consumers must treat "no row or stale row" as "don't trade this market".

  Each recorded frame is also announced as one `{:asset_price_changes, asset_ids}`
  message on the `"market_data:asset_price_changes"` PubSub topic — a coarse,
  frame-level signal for low-stakes consumers like dashboards.

  Trading consumers should register through `subscribe/1` instead (backed by
  the `PolyBot.MarketData.Registry` started in `PolyBot.Application`) and
  receive a `{:dirty, asset_id}` message per update. Because updates can
  outpace the consumer, drain the duplicates, then read once and act:

      def handle_info({:dirty, id}, state) do
        flush_dirty(id)
        {:ok, {^id, bid, ask, _exchange_ts, _recv_ts}} = PolyBot.MarketData.get(id)
        # ... decide ...
        {:noreply, state}
      end

      defp flush_dirty(id) do
        receive do
          {:dirty, ^id} -> flush_dirty(id)
        after
          0 -> :ok
        end
      end

  The table itself is owned by `PolyBot.MarketData.Worker`, which also runs the
  periodic `sweep_staleness/2` guarding against a silently frozen feed.
  """

  alias PolyBot.Broadcast
  alias Polymarket.Schemas.PriceChange
  alias Polymarket.Schemas.PriceChangeEvent

  @table :market_state
  @registry PolyBot.MarketData.Registry

  @typedoc "A Polymarket CLOB asset id (decimal token id string)."
  @type asset_id :: String.t()

  @typedoc """
  One top-of-book row: `{asset_id, best_bid, best_ask, exchange_ts, recv_ts}`.

    * `exchange_ts` - the exchange's timestamp of the update, unix epoch ms.
    * `recv_ts` - local `System.monotonic_time(:millisecond)` stamped when the
      frame was received; staleness is measured against the same clock.
  """
  @type row :: {asset_id(), number(), number(), integer(), integer()}

  @typedoc """
  Result of one staleness sweep over the table.

    * `:total` - number of rows in the table.
    * `:stale` - rows whose age exceeds the sweep's threshold.
    * `:max_ms` - age of the oldest row (0 when the table is empty).
    * `:min_ms` - age of the youngest row (0 when the table is empty); the
      time since *any* asset last updated, so a value above the threshold
      means the whole feed is silent.
  """
  @type staleness_summary :: %{
          total: non_neg_integer(),
          stale: non_neg_integer(),
          max_ms: non_neg_integer(),
          min_ms: non_neg_integer()
        }

  # ---------------------------------------------------------------------------#
  #                                Public API                                  #
  # ---------------------------------------------------------------------------#

  @doc """
  The name of the top-of-book ETS table.

  ## Examples

      iex> PolyBot.MarketData.table()
      :market_state

  """
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Create the top-of-book ETS table, owned by the calling process.

  Called from `PolyBot.MarketData.Worker.init/1`; tests pass their own name to
  get a private table that dies with the test process.

  ## Examples

      iex> PolyBot.MarketData.create_table(:my_test_table)
      :my_test_table

  """
  @spec create_table(atom()) :: atom()
  def create_table(table \\ @table) do
    :ets.new(table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  @doc """
  Record the top of book carried by a `price_change` event and notify
  subscribers.

  Runs in the websocket process, so it does the minimum: stamp the receive
  time once for the whole event, batch-insert one `t:row/0` per change (a
  single ETS operation, latest write wins), send `{:dirty, asset_id}` to the
  processes subscribed to each asset, and announce the recorded asset ids as
  one `{:asset_price_changes, asset_ids}` broadcast on the
  `"market_data:asset_price_changes"` PubSub topic. Changes missing either side of
  the book are skipped so they never clobber a complete row — skipped changes
  are neither notified nor announced.

  ## Examples

      iex> record_price_changes(%Polymarket.Schemas.PriceChangeEvent{...})
      :ok

  """
  @spec record_price_changes(PriceChangeEvent.t(), atom()) :: :ok
  def record_price_changes(%PriceChangeEvent{} = event, table \\ @table) do
    recv_ts = System.monotonic_time(:millisecond)

    rows =
      for %PriceChange{asset_id: id, best_bid: bid, best_ask: ask} <- event.price_changes,
          is_number(bid) and is_number(ask) do
        {id, bid, ask, event.timestamp, recv_ts}
      end

    :ets.insert(table, rows)

    asset_ids = for {id, _bid, _ask, _exchange_ts, _recv_ts} <- rows, do: id
    Enum.each(asset_ids, &notify_dirty/1)

    if asset_ids != [] do
      Broadcast.broadcast_asset_price_changes(asset_ids)
    end

    :ok
  end

  @doc """
  Fetch the current top-of-book `t:row/0` for `asset_id`.

  Returns `:error` when no `price_change` has been recorded for the asset
  (yet) — e.g. right after a (re)connect.

  ## Examples

      iex> get("71321045679252212594626385532706912345")
      {:ok, {"71321045679252212594626385532706912345", 0.42, 0.44, 1779656681214, -576460748}}

      iex> get("unknown")
      :error

  """
  @spec get(asset_id(), atom()) :: {:ok, row()} | :error
  def get(asset_id, table \\ @table) do
    case :ets.lookup(table, asset_id) do
      [row] -> {:ok, row}
      [] -> :error
    end
  end

  @doc """
  Subscribe the calling process to `{:dirty, asset_id}` notifications for
  `asset_id`.

  The registration is removed automatically when the caller dies. See the
  module doc for the drain-then-read consumption pattern.

  ## Examples

      iex> subscribe("71321045679252212594626385532706912345")
      :ok

  """
  @spec subscribe(asset_id()) :: :ok
  def subscribe(asset_id) do
    {:ok, _owner} = Registry.register(@registry, asset_id, nil)
    :ok
  end

  @doc """
  Sweep the table once, emit the `[:poly_bot, :market_data, :staleness]`
  telemetry event, and return the `t:staleness_summary/0`.

  A row is stale when its `recv_ts` is more than `threshold_ms` old. Single
  pass over the table, copying only `recv_ts` out of ETS (a matchspec scan
  stays in C and is severalfold cheaper than folding whole rows); run
  periodically by `PolyBot.MarketData.Worker`.

  ## Examples

      iex> sweep_staleness(30_000)
      %{total: 250, stale: 3, max_ms: 45_012, min_ms: 12}

  """
  @spec sweep_staleness(pos_integer(), atom()) :: staleness_summary()
  def sweep_staleness(threshold_ms, table \\ @table) do
    now = System.monotonic_time(:millisecond)
    recv_timestamps = :ets.select(table, [{{:_, :_, :_, :_, :"$1"}, [], [:"$1"]}])

    {total, stale, max_ms, min_ms} =
      Enum.reduce(recv_timestamps, {0, 0, 0, nil}, fn recv_ts, {total, stale, max_ms, min_ms} ->
        age = now - recv_ts
        stale = if age > threshold_ms, do: stale + 1, else: stale
        {total + 1, stale, max(max_ms, age), min_age(min_ms, age)}
      end)

    summary = %{total: total, stale: stale, max_ms: max_ms, min_ms: min_ms || 0}

    :telemetry.execute([:poly_bot, :market_data, :staleness], summary, %{
      threshold_ms: threshold_ms
    })

    summary
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # Sends {:dirty, asset_id} to every subscriber of the asset. Runs in the
  # calling (websocket) process.
  defp notify_dirty(asset_id) do
    Registry.dispatch(@registry, asset_id, fn subscribers ->
      for {pid, _value} <- subscribers, do: send(pid, {:dirty, asset_id})
    end)
  end

  # `min/2` with an explicit seed for the first row.
  defp min_age(nil, age), do: age
  defp min_age(min_ms, age), do: min(min_ms, age)
end
