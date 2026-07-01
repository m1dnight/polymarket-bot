defmodule PolyBot.EventFetch.Worker do
  @moduledoc """
  Periodically runs `PolyBot.EventFetch.sync_events/1` to refresh the stored
  Polymarket events.

  This process only handles scheduling; the fetch/store logic lives in
  `PolyBot.EventFetch`. The first fetch runs one `interval_ms` after start — call
  `PolyBot.EventFetch.sync_events/1` yourself for an immediate run. Polling is
  disabled entirely when `interval_ms` is `0` or less (done in tests).
  """

  use GenServer

  require Logger

  alias PolyBot.EventFetch

  @default_interval_ms :timer.minutes(5)

  @typedoc """
  Options accepted by `start_link/1`.

    * `:interval_ms` - delay between fetches, in milliseconds, from config; `0`
      (or less) disables polling entirely (default: 5 minutes).
    * `:fetch_opts` - keyword list forwarded to
      `PolyBot.EventFetch.sync_events/1` (e.g. `closed: false` to skip resolved
      events).
  """
  @type opts :: [
          interval_ms: non_neg_integer(),
          fetch_opts: keyword()
        ]

  # ---------------------------------------------------------------------------#
  #                                Public API                                  #
  # ---------------------------------------------------------------------------#

  @doc """
  Start the worker with the given `t:opts/0`.

  ## Examples

      iex> PolyBot.EventFetch.Worker.start_link(interval_ms: :timer.minutes(1))
      {:ok, pid}

  """
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------#
  #                                Callbacks                                   #
  # ---------------------------------------------------------------------------#

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      fetch_opts: Keyword.get(opts, :fetch_opts, [])
    }

    if polling?(state), do: schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:fetch, state) do
    run(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  defp run(state) do
    count = EventFetch.sync_events(state.fetch_opts)
    Logger.info("EventFetch: stored #{count} Polymarket events")
  rescue
    error ->
      Logger.error("EventFetch failed: #{Exception.message(error)}")
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :fetch, interval_ms)

  defp polling?(%{interval_ms: interval_ms}), do: interval_ms > 0
end
