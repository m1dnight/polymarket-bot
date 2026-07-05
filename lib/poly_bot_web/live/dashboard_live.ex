defmodule PolyBotWeb.DashboardLive do
  @moduledoc """
  Minimal operational dashboard for the bot: database counts (events, markets),
  websocket message rate, and socket counts and average lifespans (from the
  event log), refreshed every `PolyBot.Parameters.dashboard_refresh_ms/0`.
  """

  use PolyBotWeb, :live_view

  alias PolyBot.Contexts.EventLog
  alias PolyBot.Contexts.Events
  alias PolyBot.Contexts.Markets
  alias PolyBot.Parameters
  alias PolyBot.Stats

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(Parameters.dashboard_refresh_ms(), :refresh)
    end

    socket =
      assign(socket,
        page_title: "Dashboard",
        msg_rate: nil,
        last_msg_total: nil,
        last_msg_at: nil
      )

    {:ok, refresh(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, refresh(socket)}
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  defp refresh(socket) do
    socket
    |> assign(
      event_count: Events.count_events(),
      market_count: Markets.count_markets(),
      asset_count: Markets.count_assets(),
      websocket_stats: EventLog.websocket_stats()
    )
    |> refresh_msg_rate()
  end

  # Messages/s over the last refresh interval, diffed from the monotonic
  # `PolyBot.Stats` total (`delta/1` is reserved for the telemetry poller).
  # The first tick only records the baseline, so the rate shows as "–".
  defp refresh_msg_rate(socket) do
    total = Stats.get(:ws_messages)
    now = System.monotonic_time(:millisecond)

    rate =
      case socket.assigns do
        %{last_msg_total: last_total, last_msg_at: last_at}
        when is_integer(last_at) and now > last_at ->
          Float.round((total - last_total) * 1_000 / (now - last_at), 1)

        _ ->
          nil
      end

    assign(socket, msg_rate: rate, last_msg_total: total, last_msg_at: now)
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
