defmodule PolyBotWeb.DashboardLive do
  @moduledoc """
  Minimal operational dashboard for the bot: database counts (events, markets),
  aggregate websocket pool stats and historical disconnect lifespans, refreshed
  every `PolyBot.Parameters.dashboard_refresh_ms/0`.

  The pool read can stall behind an in-flight subscribe on the worker, so it is
  fetched with `start_async/3` — the database tiles keep refreshing and the
  socket tiles hold their last values until the fetch returns.
  """

  use PolyBotWeb, :live_view

  require Logger

  alias PolyBot.Contexts.EventLog
  alias PolyBot.Contexts.Events
  alias PolyBot.Contexts.Markets
  alias PolyBot.Parameters
  alias PolyBot.WebSocketManager.Worker

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(Parameters.dashboard_refresh_ms(), :refresh)
    end

    socket =
      assign(socket,
        page_title: "Dashboard",
        connection_count: 0,
        avg_lifespan: nil,
        avg_assets: nil,
        pending_asset_count: 0,
        sockets_loading?: false
      )

    {:ok, refresh(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_async(:sockets, {:ok, snapshot}, socket) do
    {:noreply,
     assign(socket,
       sockets_loading?: false,
       connection_count: length(snapshot.sockets),
       avg_lifespan: avg_lifespan(snapshot.sockets),
       avg_assets: avg_assets(snapshot.sockets),
       pending_asset_count: snapshot.pending_asset_count
     )}
  end

  def handle_async(:sockets, {:exit, reason}, socket) do
    Logger.warning("Dashboard websocket pool fetch failed: #{inspect(reason)}")
    {:noreply, assign(socket, :sockets_loading?, false)}
  end

  # ---------------------------------------------------------------------------#
  #                                Components                                  #
  # ---------------------------------------------------------------------------#

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-base-300 p-4">
      <div class="text-xs text-base-content/60">{@label}</div>
      <div class="text-2xl font-semibold">{@value}</div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  defp refresh(socket) do
    socket
    |> assign(
      event_count: Events.count_events(),
      market_count: Markets.count_markets(),
      lifespan_stats: EventLog.websocket_lifespan_stats()
    )
    |> refresh_sockets()
  end

  # At most one pool fetch is in flight: a tick that lands mid-fetch skips it
  # rather than queueing another call on a busy worker.
  defp refresh_sockets(%{assigns: %{sockets_loading?: true}} = socket), do: socket

  defp refresh_sockets(socket) do
    socket
    |> assign(:sockets_loading?, true)
    |> start_async(:sockets, fn -> Worker.sockets() end)
  end

  # Average connection age in whole seconds, or nil when the pool is empty.
  defp avg_lifespan([]), do: nil

  defp avg_lifespan(sockets) do
    now = DateTime.utc_now()

    sockets
    |> Enum.map(&DateTime.diff(now, &1.created))
    |> Enum.sum()
    |> div(length(sockets))
  end

  # Average subscribed assets per connection, or nil when the pool is empty.
  defp avg_assets([]), do: nil

  defp avg_assets(sockets) do
    sockets
    |> Enum.map(&MapSet.size(&1.assets))
    |> Enum.sum()
    |> Kernel./(length(sockets))
    |> Float.round(1)
  end

  # 12345 -> "12,345"
  defp format_int(n) do
    n
    |> Integer.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  # 4530 -> "1h 15m"
  defp format_duration(nil), do: "–"
  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds), do: "#{div(seconds, 3600)}h #{seconds |> rem(3600) |> div(60)}m"

  # Historical lifespans are stored in whole minutes; reuse the seconds-based
  # duration formatter so the display units match the live pool tiles.
  defp format_minutes(nil), do: "–"
  defp format_minutes(minutes), do: format_duration(round(minutes * 60))
end
