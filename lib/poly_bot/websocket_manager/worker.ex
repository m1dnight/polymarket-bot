defmodule PolyBot.WebSocketManager.Worker do
  @moduledoc """
  Manages the pool of Polymarket websocket connections.

  Tracks which asset ids each connection carries and routes new subscriptions
  to a connection with free capacity, opening additional connections (via
  `PolyBot.WebSocketManager.connect/0`) once the existing ones are full. Dead
  connections are detected through monitors and replaced by a fresh connection
  that resubscribes to their assets.
  """

  use GenServer
  use TypedStruct

  require Logger

  alias PolyBot.WebSocketManager

  @default_max_assets_per_connection 100

  @typedoc "A Polymarket CLOB asset id (decimal token id string)."
  @type asset_id :: String.t()

  @typedoc """
  Bookkeeping for a single websocket connection.

    * `:socket` - the connection pid.
    * `:created` - when the connection was opened.
    * `:assets` - the asset ids the connection is subscribed to.
  """
  @type socket_state :: %{
          socket: pid(),
          created: DateTime.t(),
          assets: MapSet.t(asset_id())
        }

  @typedoc "The connection pool, keyed by connection pid."
  @type sockets :: %{pid() => socket_state()}

  typedstruct do
    @typedoc """
    The worker state.

      * `:sockets` - the connection pool, keyed by connection pid.
      * `:max_assets_per_connection` - subscription capacity of a single
        connection.
    """

    field :sockets, sockets(), default: %{}
    field :max_assets_per_connection, pos_integer(), default: @default_max_assets_per_connection
  end

  @typedoc """
  Options accepted by `start_link/1`.

    * `:max_assets_per_connection` - subscription capacity of a single
      connection, from config (default: 100).
    * `:name` - process name (default: `PolyBot.WebSocketManager.Worker`);
      tests pass `nil` for an unnamed instance.
    * `:connect_fn` / `:subscribe_fn` - injection points for tests, defaulting
      to `PolyBot.WebSocketManager.connect/0` and `subscribe/2`.
  """
  @type opts :: [
          max_assets_per_connection: pos_integer(),
          name: GenServer.name() | nil
        ]

  # ---------------------------------------------------------------------------#
  #                                Public API                                  #
  # ---------------------------------------------------------------------------#

  @doc """
  Start the worker with the given `t:opts/0`.

  ## Examples

      iex> PolyBot.WebSocketManager.Worker.start_link(max_assets_per_connection: 50)
      {:ok, pid}

  """
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Subscribe to updates for `asset_ids`, spreading them across connections.

  Ids already carried by a connection are skipped. Opens new connections as
  needed; on a connect failure the ids subscribed so far are kept and the
  error is returned.

  ## Examples

      iex> PolyBot.WebSocketManager.Worker.subscribe(["71321045679252212594626385532706912345"])
      :ok

  """
  @spec subscribe(GenServer.server(), [asset_id()]) :: :ok | {:error, term()}
  def subscribe(server \\ __MODULE__, asset_ids) do
    GenServer.call(server, {:subscribe, asset_ids}, :infinity)
  end

  # ---------------------------------------------------------------------------#
  #                                Callbacks                                   #
  # ---------------------------------------------------------------------------#

  @impl true
  def init(opts) do
    asset_cap = Keyword.get(opts, :max_assets_per_connection, @default_max_assets_per_connection)

    {:ok, %__MODULE__{max_assets_per_connection: asset_cap}}
  end

  @impl true
  def handle_call({:subscribe, asset_ids}, _from, state) do
    sockets =
      asset_ids
      |> pool_subscribe_assets(state.max_assets_per_connection, Map.values(state.sockets))
      |> Map.new(&{&1.socket, &1})

    {:reply, :ok, %{state | sockets: sockets}}
  end

  def handle_call(:sockets, _from, state) do
    {:reply, state.sockets, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.pop(state.sockets, pid) do
      {nil, _sockets} ->
        {:noreply, state}

      {socket, sockets} ->
        log_disconnect(socket)
        new_socket = socket_restore(socket.assets)
        {:noreply, %{state | sockets: Map.put(sockets, new_socket.socket, new_socket)}}
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # ---------------------------------------------------------------------------
  # Pool Management

  defp pool_subscribe_assets(asset_ids, cap_per_socket, sockets) do
    # ensure that enough websockets are available to subscribe to all assets.
    sockets = pool_ensure_capacity(sockets, cap_per_socket, Enum.count(asset_ids))

    # spread all the new assets over the sockets.
    pool_subscribe(asset_ids, cap_per_socket, sockets)
  end

  # no asset ids
  defp pool_subscribe([], _cap_per_socket, sockets) do
    sockets
  end

  defp pool_subscribe(asset_ids, cap_per_socket, [socket | sockets]) do
    # fill this socket's free capacity, pass the remainder to the next one.
    free_cap = cap_per_socket - MapSet.size(socket.assets)
    {batch, remainder} = Enum.split(asset_ids, free_cap)
    [socket_subscribe(socket, batch) | pool_subscribe(remainder, cap_per_socket, sockets)]
  end

  # ensures the pool has the required capacity available.
  defp pool_ensure_capacity(sockets, cap_per_socket, required_cap) do
    missing_cap = required_cap - pool_available_capacity(sockets, cap_per_socket)

    if missing_cap > 0 do
      new_sockets = for _ <- 1..ceil(missing_cap / cap_per_socket), do: socket_add()
      new_sockets ++ sockets
    else
      sockets
    end
  end

  # returns the total available capacity for the pool of sockets
  defp pool_available_capacity(sockets, cap_per_socket) do
    Enum.reduce(sockets, 0, fn socket, cap ->
      cap + (cap_per_socket - MapSet.size(socket.assets))
    end)
  end

  # ---------------------------------------------------------------------------
  # Socket Management

  # restores a socket: create a new socket and immediately subscribe to the given asset ids.
  defp socket_restore(asset_ids) do
    Logger.debug "Restoring socket for #{MapSet.size(asset_ids)} assets."
    socket_subscribe(socket_add(), MapSet.to_list(asset_ids))
  end

  # adds a connection to the manager when the sockets are all full, or none
  # exist.
  @spec socket_add() :: socket_state()
  defp socket_add do
    {:ok, socket} = WebSocketManager.connect()
    Process.monitor(socket)
    %{socket: socket, created: DateTime.utc_now(), assets: MapSet.new()}
  end

  # subscribes to a new list of assets
  @spec socket_subscribe(socket_state(), [asset_id()]) :: socket_state()
  defp socket_subscribe(socket, []), do: socket

  defp socket_subscribe(socket, asset_ids) do
    WebSocketManager.subscribe(socket.socket, asset_ids)
    Map.update!(socket, :assets, &MapSet.union(&1, MapSet.new(asset_ids)))
  end

  defp log_disconnect(socket) do
    now = DateTime.utc_now()
    lifespan = DateTime.diff(now, socket.created, :minute)

    Logger.warning("""
    Socket disconnected after #{lifespan} minutes. Subscribed to #{MapSet.size(socket.assets)} assets.
    """)
  end
end
