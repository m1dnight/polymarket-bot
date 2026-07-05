defmodule PolyBotWeb.EventsLive do
  @moduledoc """
  Dashboard tab showing every stored event as a small grid cell that flashes
  on market activity.

  The database is read at mount to fill the grid (`Events.list_events/0`) and
  to map CLOB asset ids to their owning event (`Markets.asset_event_map/0`).
  After that the page is push-driven:

    * `PolyBot.Contexts.Events.store_events/1` broadcasts newly inserted
      events on `"events:new"` (conflict-updates stay silent); they are
      prepended straight into the stream. Their markets commit just after the
      broadcast, so the asset map refresh is deferred by one
      `PolyBot.Parameters.dashboard_refresh_ms/0` window.
    * `PolyBot.MarketData.record_price_changes/1` broadcasts `{:asset_price_changes,
      asset_ids}` per frame on `"market_data:asset_price_changes"`; hits are
      coalesced for `PolyBot.Parameters.dashboard_blink_ms/0` and flushed as
      one `"blink"` push to the client hook, which flashes the matching cells.
  """

  use PolyBotWeb, :live_view

  alias PolyBot.Broadcast
  alias PolyBot.Contexts.Events
  alias PolyBot.Contexts.Markets
  alias PolyBot.Parameters

  @impl true
  def mount(_params, _session, socket) do
    # the asset map only serves incoming broadcasts, so the static render
    # skips building it (~2 entries per stored market).
    asset_events =
      if connected?(socket) do
        Broadcast.subscribe_events_new()
        Broadcast.subscribe_asset_price_changes()
        Markets.asset_event_map()
      else
        %{}
      end

    {:ok,
     socket
     |> assign(
       page_title: "Events",
       asset_events: asset_events,
       pending_blinks: MapSet.new(),
       asset_refresh_queued?: false
     )
     |> stream(:events, Events.list_events())}
  end

  @impl true
  def handle_info({:events_new, events}, socket) do
    {:noreply,
     socket
     |> stream(:events, events, at: 0)
     |> queue_asset_refresh()}
  end

  def handle_info(:refresh_asset_map, socket) do
    {:noreply,
     assign(socket, asset_refresh_queued?: false, asset_events: Markets.asset_event_map())}
  end

  def handle_info({:asset_price_changes, asset_ids}, socket) do
    events =
      asset_ids
      |> Enum.map(&Map.get(socket.assigns.asset_events, &1))
      |> Enum.reject(&is_nil/1)

    {:noreply, queue_blinks(socket, events)}
  end

  def handle_info(:flush_blinks, socket) do
    pending = socket.assigns.pending_blinks
    socket = assign(socket, :pending_blinks, MapSet.new())

    case Enum.map(pending, &"events-#{&1}") do
      [] -> {:noreply, socket}
      dom_ids -> {:noreply, push_event(socket, "blink", %{ids: dom_ids})}
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # Collect blink hits and arm one flush timer per coalescing window.
  defp queue_blinks(socket, []), do: socket

  defp queue_blinks(socket, event_ids) do
    if MapSet.size(socket.assigns.pending_blinks) == 0 do
      Process.send_after(self(), :flush_blinks, Parameters.dashboard_blink_ms())
    end

    update(socket, :pending_blinks, &Enum.into(event_ids, &1))
  end

  # Start a cell's decay in the past by its age, so a mount only animates
  # (and repaints) recently updated cells instead of the whole grid, and the
  # fade reflects real recency across refreshes. Clamped just past the 10s
  # animation duration in app.css; anything older renders finished.
  defp decay_delay(event) do
    age = DateTime.diff(DateTime.utc_now(), event.updated_at)
    "animation-delay: -#{age |> min(11) |> max(0)}s"
  end

  # Arm at most one deferred asset-map rebuild, so a burst of events:new
  # broadcasts costs a single query.
  defp queue_asset_refresh(%{assigns: %{asset_refresh_queued?: true}} = socket), do: socket

  defp queue_asset_refresh(socket) do
    Process.send_after(self(), :refresh_asset_map, Parameters.dashboard_refresh_ms())
    assign(socket, :asset_refresh_queued?, true)
  end
end
