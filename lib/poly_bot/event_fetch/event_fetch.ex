defmodule PolyBot.EventFetch do
  @moduledoc """
  Fetches events from Polymarket's Gamma API and upserts them into the database.

  This is the plain, process-free logic — `PolyBot.EventFetch.Worker` wraps it in
  a periodic GenServer, but you can call `sync_events/1` directly to run a fetch
  on demand (e.g. from IEx).
  """

  require Logger

  alias PolyBot.Contexts.Events
  alias Polymarket.Schemas.Event, as: GammaEvent

  # ---------------------------------------------------------------------------#
  #                                Public API                                  #
  # ---------------------------------------------------------------------------#

  @doc """
  Fetch every Polymarket event (following keyset pagination) and upsert each one,
  returning the number stored. `opts` are forwarded to
  `Polymarket.Gamma.stream_events/1` (e.g. `closed: false` to skip resolved
  events).

  Only the structured event fields are stored; the markets nested on each event
  are not synced here.

  ## Examples

      iex> PolyBot.EventFetch.sync_events()
      1234

      iex> PolyBot.EventFetch.sync_events(closed: false)
      512

  """
  @spec sync_events(keyword()) :: non_neg_integer()
  def sync_events(opts \\ []) do
    opts
    |> Polymarket.Gamma.stream_events()
    |> Stream.map(&attrs/1)
    |> Stream.chunk_every(100)
    |> Stream.map(&Events.upsert_events/1)
    |> Enum.reduce(0, &(elem(&1, 0) + &2))
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # maps which fields we take from the polymarket event. we do not care about
  # all the data that comes from polymarket.
  @spec attrs(GammaEvent.t()) :: map()
  defp attrs(%GammaEvent{} = event) do
    %{
      external_id: event.id,
      neg_risk: event.enable_neg_risk,
      active: event.active,
      closed: event.closed,
      archived: event.archived
    }
  end
end
