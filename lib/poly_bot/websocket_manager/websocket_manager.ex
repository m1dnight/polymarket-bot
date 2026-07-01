defmodule PolyBot.WebSocketManager do
  @moduledoc """
  Manages the set of websocket connections to the Polymarket CLOB market feed.

  Each connection is a `Polymarket.WebSocket` process (from the `ex_polymarket`
  dep) supervised by that dep's `Polymarket.WebSocket.SocketSupervisor`, which is
  started as part of `Polymarket.Supervisor` in `PolyBot.Application`. A single
  connection can only hold so many asset ids, so subscriptions are spread across
  several connections — `connect/0` opens a new one on demand.

  This is a thin, process-free wrapper meant for driving from IEx: `connect/0` to
  open a connection, `subscribe/2` to point it at an asset id.
  """

  alias Polymarket.WebSocket
  alias Polymarket.WebSocket.SocketSupervisor

  # Constants for the CLOB market-channel `subscribe` operation. These mirror the
  # payload the dep itself sends when a new market appears, so subscriptions made
  # over a live connection behave identically.
  @custom_feature_enabled true
  @level 2
  @initial_dump true

  # ---------------------------------------------------------------------------#
  #                                Public API                                  #
  # ---------------------------------------------------------------------------#

  @doc """
  Open a new websocket connection to the Polymarket market feed.

  Returns the pid of the started `Polymarket.WebSocket` process, which you then
  hand to `subscribe/2`. A fresh connection has no asset subscriptions.

  ## Examples

      iex> PolyBot.WebSocketManager.connect()
      {:ok, #PID<0.123.0>}

  """
  @spec connect() :: DynamicSupervisor.on_start_child()
  def connect do
    SocketSupervisor.add_connection()
  end

  @doc """
  Subscribe an open `connection` to updates for a single `asset_id`.

  `connection` is a pid returned by `connect/0`. Sends a `subscribe` frame over
  the socket; the feed then streams book/price events for that asset id.

  ## Examples

      iex> {:ok, pid} = PolyBot.WebSocketManager.connect()
      iex> PolyBot.WebSocketManager.subscribe(pid, "7132104567925221259462638553270691275")
      :ok

  """
  @spec subscribe(pid(), String.t()) :: :ok
  def subscribe(connection, asset_id) do
    WebSocket.send_message(connection, subscribe_message(asset_id))
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # Builds the CLOB market-channel `subscribe` payload for a single asset id.
  @spec subscribe_message(String.t()) :: String.t()
  defp subscribe_message(asset_id) do
    %{
      operation: "subscribe",
      assets_ids: [asset_id],
      custom_feature_enabled: @custom_feature_enabled,
      level: @level,
      initial_dump: @initial_dump
    }
    |> Jason.encode!()
  end
end
