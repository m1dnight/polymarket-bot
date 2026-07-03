defmodule PolyBot.Parameters do
  @moduledoc """
  Exposes the configuration parameters for this bot.

  `event_fetch_worker_opts/0` builds the arguments for
  `PolyBot.EventFetch.Worker`; `event_fetch_opts/0` builds the Gamma query
  filters those fetches use. `websocket_worker_opts/0` builds the arguments
  for `PolyBot.WebSocketManager.Worker`. `dashboard_refresh_ms/0` is the
  refresh interval of `PolyBotWeb.DashboardLive`.
  """

  alias PolyBot.Contexts.Markets

  @typedoc """
  The full bundle of options used to fetch a list of events from the Gamma
  endpoint.

    * `:limit` - max events requested per Gamma keyset page (1..500)
    * `:closed` - status filter; `false` excludes resolved/closed events
    * `:active` - status filter; `true` restricts to active events
    * `:liquidity_min` - smallest acceptable event liquidity, from config
  """
  @type event_fetch_opts :: [
          limit: pos_integer(),
          closed: boolean(),
          active: boolean(),
          liquidity_min: integer()
        ]

  @doc """
  Builds the argument keyword-list for `PolyBot.EventFetch.Worker`.

  Bundles the config-driven poll `:interval_ms` with the `:fetch_opts` the
  worker forwards to `PolyBot.EventFetch.sync_events/1`.

  ## Examples

      iex> event_fetch_worker_opts()
      [interval_ms: 300_000, fetch_opts: [liquidity_min: 10_000, limit: 100, closed: false, active: true]]

  """
  @spec event_fetch_worker_opts :: PolyBot.EventFetch.Worker.opts()
  def event_fetch_worker_opts do
    [
      interval_ms: interval_ms(),
      fetch_opts: event_fetch_opts()
    ]
  end

  @doc """
  Builds the keyword-list of options for fetching a list of events.

  Bundles the static Gamma query filters (`:limit`, `:closed`, `:active`) with
  the config-driven `:liquidity_min` accessor, ready to hand to
  `Polymarket.Gamma.stream_events/1`.

  ## Examples

      iex> event_fetch_opts()
      [liquidity_min: 10_000, limit: 100, closed: false, active: true]

  """
  @spec event_fetch_opts :: event_fetch_opts()
  def event_fetch_opts do
    [
      limit: 100,
      closed: false,
      active: true
    ]
    |> add_if_not_infinity(:liquidity_min, minimum_liquidity())
  end

  @doc """
  Builds the argument keyword-list for `PolyBot.WebSocketManager.Worker`.

  Bundles the config-driven `:max_assets_per_connection`, the subscription
  capacity of a single websocket connection, with the `:retry_base_ms` /
  `:retry_max_ms` backoff bounds used when restoring dead connections, and
  wires `:assets_fn` to the database query that seeds the startup
  subscriptions with the tradable markets already stored. When the
  config-driven `:resync_from_db` is off, `:assets_fn` returns `[]`
  instead — tests use this to keep the app singleton away from the sandboxed
  database.

  ## Examples

      iex> websocket_worker_opts()
      [max_assets_per_connection: 100, retry_base_ms: 1000, retry_max_ms: 30000,
       assets_fn: &PolyBot.Contexts.Markets.list_subscribable_asset_ids/0]

  """
  @spec websocket_worker_opts :: PolyBot.WebSocketManager.Worker.opts()
  def websocket_worker_opts do
    [
      max_assets_per_connection: websocket_manager_env(:max_assets_per_connection),
      retry_base_ms: websocket_manager_env(:retry_base_ms),
      retry_max_ms: websocket_manager_env(:retry_max_ms),
      assets_fn: assets_fn()
    ]
  end

  @doc """
  The config-driven interval between dashboard stat refreshes, in milliseconds.

  ## Examples

      iex> dashboard_refresh_ms()
      5000

  """
  @spec dashboard_refresh_ms :: pos_integer()
  def dashboard_refresh_ms do
    Application.fetch_env!(:poly_bot, :dashboard)
    |> Keyword.fetch!(:refresh_ms)
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  @spec interval_ms :: non_neg_integer()
  defp interval_ms, do: event_fetcher_env(:interval_ms)

  # the DB-backed resync source, or a no-op source when `:resync_from_db` is
  # disabled (the test env, where the singleton must not touch the sandbox).
  @spec assets_fn :: (-> [PolyBot.WebSocketManager.Worker.asset_id()])
  defp assets_fn do
    if websocket_manager_env(:resync_from_db) do
      &Markets.list_subscribable_asset_ids/0
    else
      fn -> [] end
    end
  end

  @spec websocket_manager_env(atom()) :: term()
  defp websocket_manager_env(key) do
    Application.fetch_env!(:poly_bot, :websocket_manager)
    |> Keyword.fetch!(key)
  end

  @spec minimum_liquidity :: integer() | :infinity
  defp minimum_liquidity, do: event_fetcher_env(:minimum_liquidity)

  @spec event_fetcher_env(atom()) :: term()
  defp event_fetcher_env(key) do
    Application.fetch_env!(:poly_bot, :event_fetcher)
    |> Keyword.fetch!(key)
  end

  @spec add_if_not_infinity(Keyword.t(), atom(), term()) :: Keyword.t()
  defp add_if_not_infinity(opts, _, :infinity) do
    opts
  end

  defp add_if_not_infinity(opts, key, value) do
    Keyword.put(opts, key, value)
  end
end
