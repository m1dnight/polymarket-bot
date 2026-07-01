defmodule PolyBot.EventFetch do
  @moduledoc """
  Fetches events from Polymarket's Gamma API and upserts them — together with
  the markets nested on each one — into the database.

  This is the plain, process-free logic — `PolyBot.EventFetch.Worker` wraps it in
  a periodic GenServer, but you can call `sync_events/1` directly to run a fetch
  on demand (e.g. from IEx).
  """

  require Logger

  alias PolyBot.Contexts.Events
  alias Polymarket.Schemas.Event, as: GammaEvent
  alias Polymarket.Schemas.Market, as: GammaMarket

  # How many events (with their nested markets) to upsert per query. Bounds how
  # much of the stream is held in memory at once.
  @chunk_size 100

  # ---------------------------------------------------------------------------#
  #                                Public API                                  #
  # ---------------------------------------------------------------------------#

  @doc """
  Fetch every Polymarket event (following keyset pagination) and upsert each one
  along with its markets, returning the number of events stored. `opts` are
  forwarded to `Polymarket.Gamma.stream_events/1` (e.g. `closed: false` to skip
  resolved events).

  For each synced event, markets it no longer reports are pruned (see
  `PolyBot.Contexts.Events.replace_markets/2`), so a filtered sync
  (e.g. `closed: false`) treats itself as authoritative over those events'
  markets. Only the structured event/market fields are stored; the full venue
  payload is not synced here.

  ## Examples

      iex> PolyBot.EventFetch.sync_events()
      1234

      iex> PolyBot.EventFetch.sync_events(closed: false)
      512

  """
  @spec sync_events(keyword()) :: non_neg_integer()
  def sync_events(opts \\ []) do
    opts
    |> gamma_client().stream_events()
    |> Stream.chunk_every(@chunk_size)
    |> Stream.map(&store_chunk/1)
    |> Enum.sum()
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # The Gamma client module. Defaults to `Polymarket.Gamma`; overridable via the
  # `:gamma_client` app env so tests can inject a stub instead of hitting the API.
  @spec gamma_client() :: module()
  defp gamma_client, do: Application.get_env(:poly_bot, :gamma_client, Polymarket.Gamma)

  # Upsert a chunk of gamma events and reconcile the markets nested on them,
  # returning the number of events stored. Markets are linked to their owning
  # event through the surrogate ids `Events.upsert_events/1` returns (cheaper
  # than re-querying); `Events.replace_markets/2` then prunes any markets these
  # events no longer report.
  @spec store_chunk([GammaEvent.t()]) :: non_neg_integer()
  defp store_chunk(events) do
    {count, stored} = Events.upsert_events(Enum.map(events, &event_attrs/1))

    id_by_external_id = Map.new(stored, &{&1.external_id, &1.id})

    market_rows =
      for event <- events,
          event_id = Map.get(id_by_external_id, event.id),
          market <- event.markets,
          do: market_attrs(market, event_id)

    Events.replace_markets(Map.values(id_by_external_id), market_rows)

    count
  end

  # Maps which fields we take from the polymarket event. We do not care about all
  # the data that comes from polymarket.
  @spec event_attrs(GammaEvent.t()) :: map()
  defp event_attrs(%GammaEvent{} = event) do
    %{
      external_id: event.id,
      neg_risk: event.enable_neg_risk,
      active: event.active,
      closed: event.closed,
      archived: event.archived
    }
  end

  # Maps which fields we take from a market nested on an event, tying it to its
  # owning event's surrogate `id`.
  @spec market_attrs(GammaMarket.t(), integer()) :: map()
  defp market_attrs(%GammaMarket{} = market, event_id) do
    %{
      external_id: market.id,
      event_id: event_id,
      enable_order_book: market.enable_order_book,
      active: market.active,
      closed: market.closed,
      accepting_orders: market.accepting_orders,
      uma_resolution_status: market.uma_resolution_status,
      clob_token_ids: market.clob_token_ids,
      outcomes: market.outcomes
    }
  end
end
