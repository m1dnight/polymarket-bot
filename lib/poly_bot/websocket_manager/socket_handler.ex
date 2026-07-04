defmodule PolyBot.WebSocketManager.Handler do
  @moduledoc """
  Websocket handler that counts incoming messages.

  Bumps the `:ws_messages` counter in `PolyBot.Stats` for every event and does
  nothing else — it runs inside the socket process, so any heavier work here
  would slow down every connection.
  """

  @behaviour Polymarket.WebSocket.Handler

  require PolyBot.Stats, as: Stats

  alias Polymarket.WebSocket
  alias Polymarket.WebSocket.Handler

  @impl Handler
  @spec handle_event(Handler.event(), WebSocket.t()) :: {:noreply, WebSocket.t()}
  def handle_event(_event, %WebSocket{} = state) do
    Stats.increase(:ws_messages)
    {:noreply, state}
  end
end
