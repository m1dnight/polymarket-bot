defmodule PolyBotWeb.DashboardLive do
  @moduledoc """
  Minimal operational dashboard for the bot: database counts (events, markets)
  and aggregate websocket pool stats, refreshed every
  `PolyBot.Parameters.dashboard_refresh_ms/0`.
  """

  use PolyBotWeb, :live_view

  alias PolyBot.Contexts.Events
  alias PolyBot.Contexts.Markets
  alias PolyBot.Parameters
  alias PolyBot.WebSocketManager.Worker

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(Parameters.dashboard_refresh_ms(), :refresh)
    end

    {:ok, socket |> assign(:page_title, "Dashboard") |> refresh()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, refresh(socket)}
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
    sockets = Map.values(Worker.sockets())

    assign(socket,
      event_count: Events.count_events(),
      market_count: Markets.count_markets(),
      connection_count: length(sockets),
      avg_lifespan: avg_lifespan(sockets),
      avg_assets: avg_assets(sockets)
    )
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
end
