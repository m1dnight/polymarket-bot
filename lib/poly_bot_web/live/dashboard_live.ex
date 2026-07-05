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
  #                                Components                                  #
  # ---------------------------------------------------------------------------#

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :class, :string, default: nil

  slot :meta, doc: "optional right-aligned header content, e.g. a loading indicator"
  slot :inner_block, required: true

  # A titled group of stat rows under a ruled column-header line.
  defp panel(assigns) do
    ~H"""
    <section id={@id} class={@class}>
      <div class="flex h-5 items-center justify-between border-b border-base-content/20 pb-1">
        <h2 class="text-[0.65rem] font-semibold uppercase tracking-widest text-base-content/50">
          {@title}
        </h2>
        {render_slot(@meta)}
      </div>
      <dl class="divide-y divide-base-300">
        {render_slot(@inner_block)}
      </dl>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :value_class, :string, default: nil, doc: "semantic color override for the value"

  # One label/value line; values right-align in a mono tabular column.
  defp stat_row(assigns) do
    ~H"""
    <div id={@id} class="flex items-baseline justify-between gap-4 py-1.5">
      <dt class="text-xs text-base-content/60">{@label}</dt>
      <dd class={["font-mono text-sm tabular-nums leading-tight", @value_class]}>{@value}</dd>
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
