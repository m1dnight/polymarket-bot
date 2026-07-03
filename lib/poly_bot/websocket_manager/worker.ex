defmodule PolyBot.WebSocketManager.Worker do
  @moduledoc """
  Manages the pool of Polymarket websocket connections.

  Tracks which asset ids each connection carries and routes new subscriptions
  to a connection with free capacity, opening additional connections (via
  `PolyBot.WebSocketManager.connect/0`) once the existing ones are full. Dead
  connections are detected through monitors; their assets are parked in
  `:pending_assets` and resubscribed on a fresh connection, retrying with
  exponential backoff while connecting fails.
  """

  use GenServer
  use TypedStruct

  require Logger

  alias PolyBot.WebSocketManager

  @default_max_assets_per_connection 100
  @default_retry_base_ms 1_000
  @default_retry_max_ms 30_000

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

  @typedoc """
  Snapshot of the pool returned by `sockets/1`.

    * `:sockets` - the current connection pool entries.
    * `:pending_asset_count` - number of assets parked for resubscription
      because their connection died and restoring is still retrying.
  """
  @type snapshot :: %{
          sockets: [socket_state()],
          pending_asset_count: non_neg_integer()
        }

  typedstruct do
    @typedoc """
    The worker state.

      * `:sockets` - the connection pool, keyed by connection pid.
      * `:subscribed_assets` - the union of all live connections' assets, used
        to skip ids that are already subscribed.
      * `:max_assets_per_connection` - subscription capacity of a single
        connection.
      * `:pending_assets` - assets of dead connections awaiting resubscription.
      * `:retry_attempt` - consecutive failed restore attempts.
      * `:retry_ref` - timer of the scheduled restore, if any.
      * `:retry_base_ms` / `:retry_max_ms` - restore backoff bounds.
      * `:connect_fn` / `:subscribe_fn` - see `t:opts/0`.
    """

    field :sockets, sockets(), default: %{}
    field :subscribed_assets, MapSet.t(asset_id()), default: MapSet.new()
    field :max_assets_per_connection, pos_integer(), default: @default_max_assets_per_connection
    field :pending_assets, MapSet.t(asset_id()), default: MapSet.new()
    field :retry_attempt, non_neg_integer(), default: 0
    field :retry_ref, reference() | nil, default: nil
    field :retry_base_ms, pos_integer(), default: @default_retry_base_ms
    field :retry_max_ms, pos_integer(), default: @default_retry_max_ms
    field :connect_fn, (-> DynamicSupervisor.on_start_child())
    field :subscribe_fn, (pid(), [asset_id()] -> :ok)
  end

  @typedoc """
  Options accepted by `start_link/1`.

    * `:max_assets_per_connection` - subscription capacity of a single
      connection, from config (default: 100).
    * `:retry_base_ms` - delay of the first backed-off restore retry, from
      config; doubles per consecutive failure (default: 1000).
    * `:retry_max_ms` - ceiling for the restore retry delay, from config
      (default: 30000).
    * `:name` - process name (default: `PolyBot.WebSocketManager.Worker`);
      tests pass `nil` for an unnamed instance.
    * `:connect_fn` / `:subscribe_fn` - injection points for tests, defaulting
      to `PolyBot.WebSocketManager.connect/0` and `subscribe/2`.
  """
  @type opts :: [
          max_assets_per_connection: pos_integer(),
          retry_base_ms: pos_integer(),
          retry_max_ms: pos_integer(),
          name: GenServer.name() | nil,
          connect_fn: (-> DynamicSupervisor.on_start_child()),
          subscribe_fn: (pid(), [asset_id()] -> :ok)
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

  Ids that are already subscribed on a live connection, or parked for
  automatic resubscription after theirs died, are skipped, so the call is
  idempotent. Opens new connections as needed. When opening a
  connection fails, none of the ids are subscribed: connections opened before
  the failure are kept for a later call and the error is returned. Assets
  lost when a live connection dies are resubscribed automatically, backing
  off while connecting fails.

  ## Examples

      iex> PolyBot.WebSocketManager.Worker.subscribe(["71321045679252212594626385532706912345"])
      :ok

  """
  @spec subscribe(GenServer.server(), [asset_id()]) :: :ok | {:error, term()}
  def subscribe(server \\ __MODULE__, asset_ids) do
    GenServer.call(server, {:subscribe, asset_ids}, :infinity)
  end

  @doc """
  Return a `t:snapshot/0` of the pool: the list of connections and the number
  of assets waiting to be resubscribed.

  The read itself is cheap but waits (without timeout) behind whatever the
  worker is busy with, e.g. an in-flight subscribe — call it from a process
  that can afford to block, like the dashboard's async fetch task.

  ## Examples

      iex> PolyBot.WebSocketManager.Worker.sockets()
      %{sockets: [%{socket: pid, created: ~U[2026-07-03 10:00:00Z], assets: MapSet.new()}],
        pending_asset_count: 0}

  """
  @spec sockets(GenServer.server()) :: snapshot()
  def sockets(server \\ __MODULE__) do
    GenServer.call(server, :sockets, :infinity)
  end

  # ---------------------------------------------------------------------------#
  #                                Callbacks                                   #
  # ---------------------------------------------------------------------------#

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       max_assets_per_connection:
         Keyword.get(opts, :max_assets_per_connection, @default_max_assets_per_connection),
       retry_base_ms: Keyword.get(opts, :retry_base_ms, @default_retry_base_ms),
       retry_max_ms: Keyword.get(opts, :retry_max_ms, @default_retry_max_ms),
       connect_fn: Keyword.get(opts, :connect_fn, &WebSocketManager.connect/0),
       subscribe_fn: Keyword.get(opts, :subscribe_fn, &WebSocketManager.subscribe/2)
     }}
  end

  @impl true
  # subscribe the pool to this set of assets.
  def handle_call({:subscribe, asset_ids}, _from, state) do
    # ids parked for restore are already on their way back; the reject cannot
    # live in `pool_try_subscribe_assets` or it would drop the restore's own
    # resubscriptions.
    asset_ids = Enum.reject(asset_ids, &MapSet.member?(state.pending_assets, &1))

    case pool_try_subscribe_assets(state, asset_ids) do
      {:ok, state} ->
        {:reply, :ok, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  # return the list of sockets currently in use.
  def handle_call(:sockets, _from, state) do
    snapshot = %{
      sockets: Map.values(state.sockets),
      pending_asset_count: MapSet.size(state.pending_assets)
    }

    {:reply, snapshot, state}
  end

  @impl true
  # handle a disconnected websocket
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.pop(state.sockets, pid) do
      {nil, _sockets} ->
        {:noreply, state}

      {socket, sockets} ->
        socket_log_disconnect(socket, reason)

        # the dead connection's assets are no longer subscribed; the restore
        # re-adds them to `:subscribed_assets` once they are back on a socket.
        state = %{
          state
          | sockets: sockets,
            subscribed_assets: MapSet.difference(state.subscribed_assets, socket.assets)
        }

        {:noreply, schedule_restore(state, socket.assets)}
    end
  end

  def handle_info(:restore_pending, state) do
    state = %{state | retry_ref: nil}

    case pool_try_subscribe_assets(state, MapSet.to_list(state.pending_assets)) do
      # all assets were sucessfully subscribed to.
      {:ok, state} ->
        {:noreply, %{state | pending_assets: MapSet.new(), retry_attempt: 0}}

      # failed to subscribe to all the assets.
      {:error, reason, state} ->
        state = %{state | retry_attempt: state.retry_attempt + 1}

        Logger.warning(
          "Restoring websocket subscriptions failed (attempt #{state.retry_attempt}): " <>
            "#{inspect(reason)}; retrying in #{backoff(state)}ms."
        )

        {:noreply, schedule_restore(state, MapSet.new())}
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # ---------------------------------------------------------------------------
  # Pool Management

  # Tries to subscribe `asset_ids`: drops ids that are already subscribed,
  # ensures capacity for the rest, then spreads them over the sockets,
  # returning the updated state. When opening a connection fails no ids are
  # subscribed, but the connections opened before the failure are kept in the
  # pool so a later attempt reuses them.
  @spec pool_try_subscribe_assets(t(), [asset_id()]) :: {:ok, t()} | {:error, term(), t()}
  defp pool_try_subscribe_assets(state, asset_ids) do
    new_ids =
      asset_ids
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(state.subscribed_assets, &1))

    sockets = Map.values(state.sockets)

    case pool_ensure_capacity(sockets, state, Enum.count(new_ids)) do
      {:ok, sockets} ->
        sockets = pool_subscribe(new_ids, state, sockets)

        {:ok,
         %{
           state
           | sockets: pool_index_sockets(sockets),
             subscribed_assets: MapSet.union(state.subscribed_assets, MapSet.new(new_ids))
         }}

      {:error, reason, sockets} ->
        {:error, reason, %{state | sockets: pool_index_sockets(sockets)}}
    end
  end

  # no asset ids
  defp pool_subscribe([], _state, sockets) do
    sockets
  end

  defp pool_subscribe(asset_ids, state, [socket | sockets]) do
    # fill this socket's free capacity, pass the remainder to the next one.
    free_cap = state.max_assets_per_connection - MapSet.size(socket.assets)
    {batch, remainder} = Enum.split(asset_ids, free_cap)
    [socket_subscribe(socket, batch, state) | pool_subscribe(remainder, state, sockets)]
  end

  # ensures the pool has the required capacity available.
  defp pool_ensure_capacity(sockets, state, required_cap) do
    missing_cap = required_cap - pool_available_capacity(sockets, state.max_assets_per_connection)

    if missing_cap > 0 do
      pool_grow(ceil(missing_cap / state.max_assets_per_connection), state, sockets)
    else
      {:ok, sockets}
    end
  end

  # opens `count` connections, stopping at the first failure but keeping the
  # ones opened so far.
  defp pool_grow(0, _state, sockets), do: {:ok, sockets}

  defp pool_grow(count, state, sockets) do
    case socket_add(state) do
      {:ok, socket} ->
        pool_grow(count - 1, state, [socket | sockets])

      {:error, reason} ->
        {:error, reason, sockets}
    end
  end

  # returns the total available capacity for the pool of sockets
  defp pool_available_capacity(sockets, cap_per_socket) do
    Enum.reduce(sockets, 0, fn socket, cap ->
      cap + (cap_per_socket - MapSet.size(socket.assets))
    end)
  end

  # rebuild the map of sockets.
  defp pool_index_sockets(sockets), do: Map.new(sockets, &{&1.socket, &1})

  # ---------------------------------------------------------------------------
  # Socket Management

  # opens and monitors a connection when the sockets are all full, or none
  # exist.
  @spec socket_add(t()) :: {:ok, socket_state()} | {:error, term()}
  defp socket_add(state) do
    # fire an event to log that a websocket was created.
    :telemetry.execute([:poly_bot, :websocket, :connect], %{count: 1}, %{})

    case state.connect_fn.() do
      {:ok, socket} ->
        Process.monitor(socket)
        {:ok, %{socket: socket, created: DateTime.utc_now(), assets: MapSet.new()}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # subscribes to a new list of assets
  @spec socket_subscribe(socket_state(), [asset_id()], t()) :: socket_state()
  defp socket_subscribe(socket, [], _state), do: socket

  defp socket_subscribe(socket, asset_ids, state) do
    state.subscribe_fn.(socket.socket, asset_ids)
    Map.update!(socket, :assets, &MapSet.union(&1, MapSet.new(asset_ids)))
  end

  defp socket_log_disconnect(socket, reason) do
    now = DateTime.utc_now()
    lifespan = DateTime.diff(now, socket.created, :minute)

    :telemetry.execute([:poly_bot, :websocket, :disconnect], %{count: 1}, %{
      lifespan: lifespan,
      reason: reason,
      asset_size: MapSet.size(socket.assets)
    })

    Logger.warning("""
    Socket disconnected after #{lifespan} minutes. Subscribed to #{MapSet.size(socket.assets)} assets.
    """)
  end

  # ---------------------------------------------------------------------------
  # Restore Scheduling

  # Parks `assets` for resubscription and schedules a `:restore_pending`
  # unless one is already on the way (it picks the new assets up too).
  defp schedule_restore(state, assets) do
    # list of all assets that are not subscribed to at this moment.
    pending = MapSet.union(state.pending_assets, assets)

    cond do
      # no assets to retry
      MapSet.size(pending) == 0 ->
        state

      # there is already a retry pending.
      state.retry_ref != nil ->
        %{state | pending_assets: pending}

      # trigger a retry in an exponential backoff fashion
      true ->
        ref = Process.send_after(self(), :restore_pending, backoff(state))
        %{state | pending_assets: pending, retry_ref: ref}
    end
  end

  # the first attempt is immediate; each consecutive failure doubles the delay
  # up to `:retry_max_ms`.
  defp backoff(%{retry_attempt: 0}), do: 0

  defp backoff(state) do
    min(state.retry_base_ms * Integer.pow(2, state.retry_attempt - 1), state.retry_max_ms)
  end
end
