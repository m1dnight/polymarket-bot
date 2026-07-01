defmodule PolyBot.Parameters do
  @moduledoc """
  Exposes the configuration parameters for this bot.

  Each parameter has its own accessor (e.g. `venue/0`); `event_fetch_opts/0`
  and `event_poller_opts/0` are keyword-list bundles of those accessors.
  """

  alias PolyBot.Venues.Fake
  alias PolyBot.Venues.Polymarket

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

  @typedoc """
  Arguments for the event poller process.

    * `:interval_ms` - delay between polls, in milliseconds, from config; `0`
      (or less) disables polling entirely
  """
  @type event_poller_opts :: [
          interval_ms: non_neg_integer(),
          venue: Fake | Polymarket
        ]

  @typedoc """
  Arguments for the websocket shard manager.

    * `:cap` - max asset subscriptions per socket, from config
    * `:handler` - `Polymarket.WebSocket.Handler` module each socket uses
  """
  @type shard_opts :: [
          cap: pos_integer(),
          handler: module()
        ]

  @doc """
  Builds the keyword-list of options for fetching a list of events.

  Bundles the static Gamma query filters (`:limit`, `:closed`, `:active`) with
  the config-driven `:liquidity_min` accessor, ready to hand to a venue's
  `stream_events/1`.
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

  @spec minimum_liquidity :: integer()
  defp minimum_liquidity do
    Application.fetch_env!(:poly_bot, :event_fetcher)
    |> Keyword.fetch!(:minimum_liquidity)
  end

  @spec add_if_not_infinity(Keyword.t(), atom(), term()) :: Keyword.t()
  defp add_if_not_infinity(opts, _, :infinity) do
    opts
  end

  defp add_if_not_infinity(opts, key, value) do
    Keyword.put(opts, key, value)
  end
end
