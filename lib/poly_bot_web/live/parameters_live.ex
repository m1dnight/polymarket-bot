defmodule PolyBotWeb.ParametersLive do
  @moduledoc """
  Dashboard tab showing the configuration parameters the bot is currently
  running with, as exposed by `PolyBot.Parameters`.

  The values are fixed at boot (runtime.exs reads them from the environment),
  so they are read once at mount and never refreshed.
  """

  use PolyBotWeb, :live_view

  alias PolyBot.Parameters

  @impl true
  def mount(_params, _session, socket) do
    event_fetch = Parameters.event_fetch_worker_opts()

    {:ok,
     assign(socket,
       page_title: "Parameters",
       event_fetch: event_fetch,
       fetch_opts: Keyword.fetch!(event_fetch, :fetch_opts),
       websocket: Parameters.websocket_worker_opts(),
       market_data: Parameters.market_data_worker_opts(),
       dashboard_refresh_ms: Parameters.dashboard_refresh_ms(),
       dashboard_blink_ms: Parameters.dashboard_blink_ms()
     )}
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # 300_000 -> "5m", 5_000 -> "5s", 300 -> "300ms"
  defp format_ms(ms) when ms >= 60_000 and rem(ms, 60_000) == 0, do: "#{div(ms, 60_000)}m"
  defp format_ms(ms) when ms >= 1_000 and rem(ms, 1_000) == 0, do: "#{div(ms, 1_000)}s"
  defp format_ms(ms), do: "#{ms}ms"

  # :liquidity_min is absent from the fetch opts when the minimum-liquidity
  # filter is configured off (:infinity).
  defp format_liquidity(nil), do: "off"
  defp format_liquidity(min), do: min
end
