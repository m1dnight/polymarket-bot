defmodule PolyBot.MarketData.Worker do
  @moduledoc """
  Owns the top-of-book ETS table and periodically sweeps it for staleness.

  This process only creates the table (in `init/1`, so the table dies — and is
  recreated empty — with the worker) and handles the sweep scheduling; the
  measurement logic lives in `PolyBot.MarketData.sweep_staleness/2`. Sweeping
  is disabled entirely when `sweep_interval_ms` is `0` or less (done in
  tests).

  On top of the per-sweep telemetry, the worker watches for a silently frozen
  feed — every row aging past the threshold at once — and logs the transitions
  into and out of that state.
  """

  use GenServer

  require Logger

  alias PolyBot.MarketData

  @default_sweep_interval_ms 5_000
  @default_staleness_threshold_ms 30_000

  @typedoc """
  Options accepted by `start_link/1`.

    * `:sweep_interval_ms` - delay between staleness sweeps, in milliseconds,
      from config; `0` (or less) disables sweeping entirely (default: 5000 —
      the sweep is a full-table scan, and its consumers, the 30s-threshold
      freeze log and last_value metrics, gain nothing from 1s resolution).
    * `:staleness_threshold_ms` - age above which a row counts as stale, in
      milliseconds, from config (default: 30000).
    * `:table` - name of the ETS table to create and sweep (default:
      `PolyBot.MarketData.table/0`); tests pass their own for a private table.
    * `:name` - process name (default: `PolyBot.MarketData.Worker`); tests
      pass `nil` for an unnamed instance.
  """
  @type opts :: [
          sweep_interval_ms: non_neg_integer(),
          staleness_threshold_ms: pos_integer(),
          table: atom(),
          name: GenServer.name() | nil
        ]

  # ---------------------------------------------------------------------------#
  #                                Public API                                  #
  # ---------------------------------------------------------------------------#

  @doc """
  Start the worker with the given `t:opts/0`.

  ## Examples

      iex> PolyBot.MarketData.Worker.start_link(sweep_interval_ms: 1_000)
      {:ok, pid}

  """
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ---------------------------------------------------------------------------#
  #                                Callbacks                                   #
  # ---------------------------------------------------------------------------#

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, MarketData.table())
    MarketData.create_table(table)

    state = %{
      table: table,
      sweep_interval_ms: Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms),
      staleness_threshold_ms:
        Keyword.get(opts, :staleness_threshold_ms, @default_staleness_threshold_ms),
      feed_stale?: false
    }

    if sweeping?(state), do: schedule(state.sweep_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    summary = MarketData.sweep_staleness(state.staleness_threshold_ms, state.table)
    schedule(state.sweep_interval_ms)
    {:noreply, note_feed_freeze(state, summary)}
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # A frozen feed shows up as `min_ms` crossing the threshold: `min_ms` is the
  # age of the youngest row, so nothing at all has been written for that long.
  # Logs only on transitions to keep the periodic sweep quiet.
  defp note_feed_freeze(state, summary) do
    frozen? = summary.total > 0 and summary.min_ms > state.staleness_threshold_ms

    cond do
      frozen? and not state.feed_stale? ->
        Logger.warning(
          "MarketData: no top-of-book update for #{summary.min_ms}ms " <>
            "across all #{summary.total} tracked assets"
        )

        %{state | feed_stale?: true}

      not frozen? and state.feed_stale? ->
        Logger.info("MarketData: top-of-book updates resumed")
        %{state | feed_stale?: false}

      true ->
        state
    end
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)

  defp sweeping?(%{sweep_interval_ms: interval_ms}), do: interval_ms > 0
end
