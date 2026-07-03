defmodule PolyBot.WebSocketManager.Worker do
  @moduledoc """
  Manages the pool of Polymarket websocket connections.

  Tracks which asset ids each connection carries and routes new subscriptions
  to a connection with free capacity, opening additional connections (via
  `PolyBot.WebSocketManager.connect/0`) once the existing ones are full. Dead
  connections are detected through monitors; their assets are parked in
  `:pending_assets` and resubscribed on a fresh connection, retrying with
  exponential backoff while connecting fails.

  On startup the pool seeds itself with the asset ids returned by
  `:assets_fn` (wired to the tradable markets already in the database
  by `PolyBot.Parameters.websocket_worker_opts/0`), reusing the same parking
  and backoff when that first subscription fails.

  The worker also listens on the `"events:refreshed"` PubSub topic, where
  `PolyBot.EventFetch` announces every stored chunk of events. Each broadcast
  re-runs `:assets_fn` and subscribes the assets that are new, so
  markets discovered by later syncs get a live subscription without a
  restart.
  """

  use GenServer
  use TypedStruct

  require Logger

  alias Phoenix.PubSub
  alias PolyBot.WebSocketManager

  @default_conn_cap 2500
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

  @typedoc """
  Injected functions that operate on a single websocket connection, threaded
  through the socket helpers.

    * `:connect_fn` - opens a new connection.
    * `:subscribe_fn` - subscribes a connection to a list of asset ids.
  """
  @type socket_options :: %{
          connect_fn: (-> DynamicSupervisor.on_start_child()),
          subscribe_fn: (pid(), [asset_id()] -> :ok)
        }

  @typedoc """
  Everything the pool helpers need: the per-connection subscription capacity
  plus the `t:socket_options/0` used to open and subscribe connections.

    * `:conn_cap` - subscription capacity of a single connection.
    * `:socket_options` - the socket-level operations, forwarded to the socket
      helpers.
  """
  @type pool_options :: %{
          conn_cap: pos_integer(),
          socket_options: socket_options()
        }

  typedstruct do
    @typedoc """
    The worker state.

      * `:sockets` - the connection pool, keyed by connection pid.
      * `:subscribed_assets` - the union of all live connections' assets, used
        to skip ids that are already subscribed.
      * `:pool_options` - the `t:pool_options/0` threaded through the pool
        helpers (per-connection capacity plus the nested `:socket_options`).
      * `:socket_options` - the `t:socket_options/0` threaded through the
        socket helpers (the injected connect/subscribe functions).
      * `:pending_assets` - assets of dead connections awaiting resubscription.
      * `:retry_attempt` - consecutive failed restore attempts.
      * `:retry_ref` - timer of the scheduled restore, if any.
      * `:retry_base_ms` / `:retry_max_ms` - restore backoff bounds.
      * `:assets_fn` - see `t:opts/0`.
    """

    field :sockets, sockets(), default: %{}
    field :subscribed_assets, MapSet.t(asset_id()), default: MapSet.new()
    field :pool_options, pool_options()
    field :socket_options, socket_options()
    field :pending_assets, MapSet.t(asset_id()), default: MapSet.new()
    field :retry_attempt, non_neg_integer(), default: 0
    field :retry_ref, reference() | nil, default: nil
    field :retry_base_ms, pos_integer(), default: @default_retry_base_ms
    field :retry_max_ms, pos_integer(), default: @default_retry_max_ms
    field :assets_fn, (-> [asset_id()])
  end

  @typedoc """
  Options accepted by `start_link/1`.

    * `:conn_cap` - subscription capacity of a single
      connection, from config (default: 100).
    * `:retry_base_ms` - delay of the first backed-off restore retry, from
      config; doubles per consecutive failure (default: 1000).
    * `:retry_max_ms` - ceiling for the restore retry delay, from config
      (default: 30000).
    * `:name` - process name (default: `PolyBot.WebSocketManager.Worker`);
      tests pass `nil` for an unnamed instance.
    * `:connect_fn` / `:subscribe_fn` - injection points for tests, defaulting
      to `PolyBot.WebSocketManager.connect/0` and `subscribe/2`.
    * `:assets_fn` - returns the asset ids the pool should carry; run
      right after startup and again on every `"events:refreshed"` broadcast
      (default: a function returning `[]`, i.e. no initial subscription). The
      app wires in the database-backed query via
      `PolyBot.Parameters.websocket_worker_opts/0`.
  """
  @type opts :: [
          conn_cap: pos_integer(),
          retry_base_ms: pos_integer(),
          retry_max_ms: pos_integer(),
          name: GenServer.name() | nil,
          connect_fn: (-> DynamicSupervisor.on_start_child()),
          subscribe_fn: (pid(), [asset_id()] -> :ok),
          assets_fn: (-> [asset_id()])
        ]

  # ---------------------------------------------------------------------------#
  #                                Public API                                  #
  # ---------------------------------------------------------------------------#

  @doc """
  Start the worker with the given `t:opts/0`.

  ## Examples

      iex> PolyBot.WebSocketManager.Worker.start_link(conn_cap: 50)
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
  idempotent. Opens new connections as needed. Fire-and-forget: when opening a
  connection fails the ids are parked and resubscribed automatically with
  exponential backoff (the same path used when a live connection dies), so a
  successful call guarantees the assets eventually get a live subscription.
  Always returns `:ok`.

  ## Examples

      iex> PolyBot.WebSocketManager.Worker.subscribe(["71321045679252212594626385532706912345"])
      :ok

  """
  @spec subscribe(GenServer.server(), [asset_id()]) :: :ok
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
    # subscribe to events about events being refreshed
    PubSub.subscribe(PolyBot.PubSub, "events:refreshed")

    socket_options = %{
      connect_fn: Keyword.get(opts, :connect_fn, &WebSocketManager.connect/0),
      subscribe_fn: Keyword.get(opts, :subscribe_fn, &WebSocketManager.subscribe/2)
    }

    state = %__MODULE__{
      pool_options: %{
        conn_cap: Keyword.get(opts, :conn_cap, @default_conn_cap),
        socket_options: socket_options
      },
      socket_options: socket_options,
      retry_base_ms: Keyword.get(opts, :retry_base_ms, @default_retry_base_ms),
      retry_max_ms: Keyword.get(opts, :retry_max_ms, @default_retry_max_ms),
      assets_fn: Keyword.get(opts, :assets_fn, fn -> [] end)
    }

    # the initial subscription runs after init so it doesn't hold up the rest
    # of the supervision tree.
    {:ok, state, {:continue, :initial_subscribe}}
  end

  @impl true
  # Seed the pool with the initial asset ids. Runs before any other message;
  # when connecting fails the ids are parked and come back through the usual
  # backed-off restore.
  def handle_continue(:initial_subscribe, state) do
    {:noreply, resync_assets(state)}
  end

  @impl true
  # subscribe the pool to this set of assets. Fire-and-forget: a failed connect
  # parks the ids and schedules a backed-off restore, just like the
  # resync/restore paths, so the caller always gets `:ok` and never has to
  # retry itself.
  def handle_call({:subscribe, asset_ids}, _from, state) do
    {:reply, :ok, sync_new_assets(state, asset_ids)}
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
            subscribed_assets: MapSet.difference(state.subscribed_assets, socket.assets),
            pending_assets: MapSet.union(state.pending_assets, socket.assets)
        }

        {:noreply, schedule_restore(state)}
    end
  end

  # the event fetcher stored a chunk of events; subscribe any tradable assets
  # that are new. A sync broadcasts once per chunk in quick succession, so
  # queued refresh messages are drained and covered by this single resync.
  def handle_info({:events_refreshed, _count}, state) do
    flush_events_refreshed()
    {:noreply, resync_assets(state)}
  rescue
    # the pool carries live subscriptions; a failing resync (e.g. the assets
    # query hitting a DB hiccup) must not tear them down. The next refresh
    # simply retries.
    error ->
      Logger.warning("Websocket resync failed: #{Exception.message(error)}")
      {:noreply, state}
  end

  def handle_info(:restore_pending, state) do
    state = %{state | retry_ref: nil}
    {:noreply, sync_parked_assets(state)}
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # ---------------------------------------------------------------------------
  # Asset Management

  # fetches a list of assets from the database and subscribes to ones that are currently not subscribed to.
  defp resync_assets(state) do
    asset_ids =
      state.assets_fn.()
      |> new_assets_only(state)

    sync_new_assets(state, asset_ids)
  end

  # runs `sync_assets/2` and keeps the resulting state whether the subscribe
  # succeeded or the ids were parked for a backed-off retry. Used by the
  # fire-and-forget paths (initial seed, resync, `subscribe/2`) that don't
  # surface the connect error to a caller.
  defp sync_parked_assets(state) do
    asset_ids = MapSet.to_list(state.pending_assets)
    state = %{state | pending_assets: MapSet.new(), retry_attempt: state.retry_attempt + 1}

    state = sync_new_assets(state, asset_ids)

    if MapSet.size(state.pending_assets) > 0 do
      state
    else
      %{state | retry_attempt: 0}
    end
  end

  defp sync_new_assets(state, asset_ids) do
    asset_ids = new_assets_only(asset_ids, state)

    case sync_assets(state, asset_ids) do
      {:ok, state} ->
        state

      {:error, _reason, state} ->
        state
    end
  end

  # given a list of asset ids, subscribes to the ones that are currently not present in the pool.
  # expects the pending_assets to empty!
  defp sync_assets(state, asset_ids) do
    asset_ids = new_assets_only(asset_ids, state)

    case subscribe_assets(state, asset_ids) do
      {:ok, sockets} ->
        new_state = %{
          state
          | sockets: pool_index_sockets(sockets),
            subscribed_assets: MapSet.union(state.subscribed_assets, MapSet.new(asset_ids))
        }

        {:ok, new_state}

      {:error, reason, sockets} ->
        new_state =
          %{state | sockets: pool_index_sockets(sockets), pending_assets: MapSet.new(asset_ids)}
          |> schedule_restore()

        {:error, reason, new_state}
    end
  end

  # returns a list of assets that are not currently subscribed to, or that are pending resubscription.
  defp new_assets_only(asset_ids, state) do
    asset_ids
    |> Enum.reject(
      &(MapSet.member?(state.pending_assets, &1) or MapSet.member?(state.subscribed_assets, &1))
    )
  end

  @spec subscribe_assets(t(), [asset_id()]) ::
          {:ok, [socket_state()]} | {:error, term(), [socket_state()]}
  defp subscribe_assets(state, asset_ids) do
    # compute the total available capacity at this point
    available_cap = pool_available_capacity(state)

    pool_try_subscribe_assets(
      Map.values(state.sockets),
      available_cap,
      asset_ids,
      state.pool_options
    )
  end

  # drains queued refresh notifications; the resync about to run covers them.
  defp flush_events_refreshed do
    receive do
      {:events_refreshed, _count} -> flush_events_refreshed()
    after
      0 -> :ok
    end
  end

  # returns the total available capacity for the pool of sockets
  defp pool_available_capacity(state) do
    total_cap = Enum.count(state.sockets) * state.pool_options.conn_cap
    used_cap = MapSet.size(state.subscribed_assets)
    total_cap - used_cap
  end

  # ---------------------------------------------------------------------------
  # Pool Management

  # Tries to subscribe `asset_ids`: drops ids that are already subscribed,
  # ensures capacity for the rest, then spreads them over the sockets,
  # returning the updated state. When opening a connection fails no ids are
  # subscribed, but the connections opened before the failure are kept in the
  # pool so a later attempt reuses them.
  defp pool_try_subscribe_assets(sockets, available_cap, asset_ids, pool_options) do
    # total capacity required for this list of asset ids.
    required_cap = Enum.count(asset_ids)

    # calculate how many extra capacity is needed, or 0 if we can fit the assets
    # in the available cap.
    missing_cap = max(0, required_cap - available_cap)

    case pool_ensure_capacity(sockets, missing_cap, pool_options) do
      {:ok, sockets} ->
        sockets = pool_subscribe(asset_ids, sockets, pool_options)
        {:ok, sockets}

      {:error, reason, sockets} ->
        {:error, reason, sockets}
    end
  end

  # no asset ids
  defp pool_subscribe([], sockets, _pool_options) do
    sockets
  end

  defp pool_subscribe(asset_ids, [socket | sockets], pool_options) do
    # fill this socket's free capacity, pass the remainder to the next one.
    free_cap = pool_options.conn_cap - MapSet.size(socket.assets)
    {batch, remainder} = Enum.split(asset_ids, free_cap)

    [
      socket_subscribe(socket, batch, pool_options.socket_options)
      | pool_subscribe(remainder, sockets, pool_options)
    ]
  end

  # ensures the pool has the required capacity available.
  defp pool_ensure_capacity(sockets, required_cap, pool_options) when required_cap > 0 do
    pool_grow(ceil(required_cap / pool_options.conn_cap), sockets, pool_options.socket_options)
  end

  defp pool_ensure_capacity(sockets, _, _), do: {:ok, sockets}

  # opens `count` connections, stopping at the first failure but keeping the
  # ones opened so far.
  defp pool_grow(0, sockets, _socket_options), do: {:ok, sockets}

  defp pool_grow(count, sockets, socket_options) do
    case socket_create(socket_options) do
      {:ok, socket} ->
        pool_grow(count - 1, [socket | sockets], socket_options)

      {:error, reason} ->
        {:error, reason, sockets}
    end
  end

  # rebuild the map of sockets.
  defp pool_index_sockets(sockets), do: Map.new(sockets, &{&1.socket, &1})

  # ---------------------------------------------------------------------------
  # Socket Management

  # opens and monitors a connection when the sockets are all full, or none
  # exist.
  @spec socket_create(socket_options()) :: {:ok, socket_state()} | {:error, term()}
  defp socket_create(socket_options) do
    # fire an event to log that a websocket was created.
    :telemetry.execute([:poly_bot, :websocket, :connect], %{count: 1}, %{})

    case socket_options.connect_fn.() do
      {:ok, socket} ->
        Process.monitor(socket)
        {:ok, %{socket: socket, created: DateTime.utc_now(), assets: MapSet.new()}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # subscribes to a new list of assets
  @spec socket_subscribe(socket_state(), [asset_id()], socket_options()) :: socket_state()
  defp socket_subscribe(socket, [], _socket_options), do: socket

  defp socket_subscribe(socket, asset_ids, socket_options) do
    socket_options.subscribe_fn.(socket.socket, asset_ids)
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
  defp schedule_restore(state) do
    cond do
      # no assets to retry
      MapSet.size(state.pending_assets) == 0 ->
        state

      # there is already a retry pending.
      state.retry_ref != nil ->
        state

      # trigger a retry in an exponential backoff fashion
      true ->
        ref = Process.send_after(self(), :restore_pending, backoff(state))
        %{state | retry_ref: ref}
    end
  end

  # the first attempt is immediate; each consecutive failure doubles the delay
  # up to `:retry_max_ms`.
  defp backoff(%{retry_attempt: 0}), do: 0

  defp backoff(state) do
    min(state.retry_base_ms * Integer.pow(2, state.retry_attempt - 1), state.retry_max_ms)
  end
end
