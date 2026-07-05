defmodule PolyBot.Broadcast do
  @moduledoc """
  The single home for PolyBot's PubSub channels: every topic name and message
  shape lives here as a broadcast/subscribe pair, so one look at this module
  shows everything that can fire across the app.

  Channels:

    * `"events:refreshed"` — `{:events_refreshed, count}`, fired by
      `PolyBot.EventFetch` once a stored chunk's markets are committed.
    * `"events:new"` — `{:events_new, events}`, fired by
      `PolyBot.Contexts.Events.store_events/1` for events inserted for the
      first time (conflict-updates stay silent).
    * `"market_data:asset_price_changes"` — `{:asset_price_changes, asset_ids}`,
      fired by `PolyBot.MarketData.record_price_changes/2` per recorded frame.
  """

  alias Phoenix.PubSub
  alias PolyBot.Contexts.Schemas.Event

  @pubsub PolyBot.PubSub

  @doc """
  Announce that a chunk of `count` synced events — markets included — has
  been committed.

  ## Examples

      iex> broadcast_events_refreshed(100)
      :ok

  """
  @spec broadcast_events_refreshed(non_neg_integer()) :: :ok | {:error, term()}
  def broadcast_events_refreshed(count) do
    PubSub.broadcast(@pubsub, "events:refreshed", {:events_refreshed, count})
  end

  @doc """
  Receive `{:events_refreshed, count}` messages in the calling process.

  ## Examples

      iex> subscribe_events_refreshed()
      :ok

  """
  @spec subscribe_events_refreshed() :: :ok | {:error, term()}
  def subscribe_events_refreshed do
    PubSub.subscribe(@pubsub, "events:refreshed")
  end

  @doc """
  Announce events stored for the first time.

  ## Examples

      iex> broadcast_events_new([%Event{external_id: "12345"}])
      :ok

  """
  @spec broadcast_events_new([Event.t()]) :: :ok | {:error, term()}
  def broadcast_events_new(events) do
    PubSub.broadcast(@pubsub, "events:new", {:events_new, events})
  end

  @doc """
  Receive `{:events_new, events}` messages in the calling process.

  ## Examples

      iex> subscribe_events_new()
      :ok

  """
  @spec subscribe_events_new() :: :ok | {:error, term()}
  def subscribe_events_new do
    PubSub.subscribe(@pubsub, "events:new")
  end

  @doc """
  Announce the CLOB asset ids whose top of book a recorded price-change frame
  moved.

  ## Examples

      iex> broadcast_asset_price_changes(["71321045679"])
      :ok

  """
  @spec broadcast_asset_price_changes([String.t()]) :: :ok | {:error, term()}
  def broadcast_asset_price_changes(asset_ids) do
    PubSub.broadcast(
      @pubsub,
      "market_data:asset_price_changes",
      {:asset_price_changes, asset_ids}
    )
  end

  @doc """
  Receive `{:asset_price_changes, asset_ids}` messages in the calling process.

  ## Examples

      iex> subscribe_asset_price_changes()
      :ok

  """
  @spec subscribe_asset_price_changes() :: :ok | {:error, term()}
  def subscribe_asset_price_changes do
    PubSub.subscribe(@pubsub, "market_data:asset_price_changes")
  end
end
