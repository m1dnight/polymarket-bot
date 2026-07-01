defmodule PolyBot.Parameters do
  @moduledoc """
  Exposes the configuration parameters for this bot.

  `event_fetch_worker_opts/0` builds the arguments for
  `PolyBot.EventFetch.Worker`; `event_fetch_opts/0` builds the Gamma query
  filters those fetches use.
  """

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

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  @spec interval_ms :: non_neg_integer()
  defp interval_ms, do: event_fetcher_env(:interval_ms)

  @spec minimum_liquidity :: integer()
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
