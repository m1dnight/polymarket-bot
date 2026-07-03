defmodule PolyBot.WebSocketManager.WorkerTest do
  @moduledoc """
  Exercises `PolyBot.WebSocketManager.Worker` against fake connections.

  Each test starts an unnamed worker (the app already runs the named
  singleton) with `connect_fn`/`subscribe_fn` that message the test process,
  so no network is touched. Connect results are scripted through an Agent to
  drive the failure and retry paths.
  """

  use ExUnit.Case, async: true

  alias Phoenix.PubSub
  alias PolyBot.WebSocketManager.Worker

  @moduletag :capture_log

  # ---------------------------------------------------------------------------#
  #                            initial subscription                            #
  # ---------------------------------------------------------------------------#

  describe "initial subscription" do
    test "subscribes the assets returned by assets_fn on startup" do
      worker = start_worker(assets_fn: fn -> ["a", "b"] end)

      assert_receive {:connected, pid}
      assert_receive {:subscribed, ^pid, ["a", "b"]}

      # the seeded ids count as already subscribed for later calls.
      assert Worker.subscribe(worker, ["a", "b"]) == :ok
      refute_receive {:subscribed, _, _}
    end

    test "opens no connection when there are no initial assets" do
      worker = start_worker([])

      # synchronize on the worker having processed the initial subscribe.
      _ = Worker.sockets(worker)
      refute_receive {:connected, _}
    end

    test "parks the initial assets for restore when connecting fails" do
      worker =
        start_worker(
          [assets_fn: fn -> ["a"] end, retry_base_ms: 10, retry_max_ms: 40],
          [{:error, :econnrefused}]
        )

      # the seed attempt fails; the immediate restore retry succeeds once the
      # script is exhausted.
      assert_receive :connect_failed
      assert_receive {:connected, pid}, 500
      assert_receive {:subscribed, ^pid, ["a"]}, 500
      assert Worker.sockets(worker).pending_asset_count == 0
    end
  end

  # ---------------------------------------------------------------------------#
  #                                subscribe/2                                 #
  # ---------------------------------------------------------------------------#

  describe "subscribe/2" do
    test "spreads asset ids over connections, respecting the capacity" do
      worker = start_worker(conn_cap: 2)

      assert Worker.subscribe(worker, ["a", "b", "c"]) == :ok

      assert_receive {:connected, _pid1}
      assert_receive {:connected, _pid2}
      assert_receive {:subscribed, _, batch1}
      assert_receive {:subscribed, _, batch2}
      assert Enum.sort(batch1 ++ batch2) == ["a", "b", "c"]
      assert length(Worker.sockets(worker).sockets) == 2
    end

    test "fills free capacity before opening a new connection" do
      worker = start_worker(conn_cap: 2)

      assert Worker.subscribe(worker, ["a"]) == :ok
      assert_receive {:connected, _pid}
      assert_receive {:subscribed, _, ["a"]}

      assert Worker.subscribe(worker, ["b"]) == :ok
      assert_receive {:subscribed, _, ["b"]}
      refute_receive {:connected, _}
      assert length(Worker.sockets(worker).sockets) == 1
    end

    test "skips assets that are already subscribed" do
      worker = start_worker(conn_cap: 2)

      assert Worker.subscribe(worker, ["a", "b"]) == :ok
      assert_receive {:connected, _pid}
      assert_receive {:subscribed, _, ["a", "b"]}

      # "a" and "b" are already subscribed: only "c" goes out.
      assert Worker.subscribe(worker, ["a", "b", "c"]) == :ok
      assert_receive {:subscribed, _, ["c"]}
      refute_receive {:subscribed, _, _}
    end

    test "is a no-op when all assets are already subscribed" do
      worker = start_worker(conn_cap: 2)

      assert Worker.subscribe(worker, ["a"]) == :ok
      assert_receive {:connected, _pid}
      assert_receive {:subscribed, _, ["a"]}

      assert Worker.subscribe(worker, ["a", "a"]) == :ok
      refute_receive {:connected, _}
      refute_receive {:subscribed, _, _}
    end

    test "skips assets that are parked for resubscription" do
      worker =
        start_worker(
          [retry_base_ms: 60_000, retry_max_ms: 60_000],
          [:ok, {:error, :econnrefused}]
        )

      assert Worker.subscribe(worker, ["a"]) == :ok
      assert_receive {:connected, pid}
      assert_receive {:subscribed, ^pid, ["a"]}

      # the immediate restore attempt fails, parking "a" until the far-off
      # retry; subscribing it again must not double it up.
      Process.exit(pid, :kill)
      assert_receive :connect_failed, 500

      assert Worker.subscribe(worker, ["a", "b"]) == :ok
      assert_receive {:subscribed, _, ["b"]}
      refute_receive {:subscribed, _, _}
      assert Worker.sockets(worker).pending_asset_count == 1
    end

    test "returns :ok and eventually subscribes even when the first connect fails" do
      worker = start_worker([], [{:error, :econnrefused}])

      # fire-and-forget: the caller gets :ok despite the failed connect.
      assert Worker.subscribe(worker, ["a"]) == :ok
      assert_receive :connect_failed

      # the immediate restore retries (the script is exhausted, so it now
      # succeeds) and the asset lands on a fresh connection.
      assert_receive {:connected, pid}, 500
      assert_receive {:subscribed, ^pid, ["a"]}, 500
      assert Worker.sockets(worker).pending_asset_count == 0
    end

    test "keeps connections opened before the failure and reuses them on retry" do
      worker = start_worker([conn_cap: 1], [:ok, {:error, :timeout}])

      # conn_cap 1 needs two connections for two assets: the first opens, the
      # second fails, so nothing is subscribed on the initial attempt.
      assert Worker.subscribe(worker, ["a", "b"]) == :ok
      assert_receive {:connected, first}
      assert_receive :connect_failed

      # the immediate restore reuses the kept connection and opens just one
      # more (the script is exhausted, so it succeeds), covering both assets
      # across two connections instead of reopening from scratch.
      assert_receive {:connected, second}, 500
      assert first != second
      assert_receive {:subscribed, _, _}, 500
      assert_receive {:subscribed, _, _}, 500

      snapshot = Worker.sockets(worker)
      assert length(snapshot.sockets) == 2
      assert snapshot.pending_asset_count == 0
    end
  end

  # ---------------------------------------------------------------------------#
  #                               events refresh                               #
  # ---------------------------------------------------------------------------#

  describe "events refresh" do
    test "subscribes assets that appeared since the last event sync" do
      assets = start_supervised!({Agent, fn -> ["a"] end}, id: :assets)
      start_worker(assets_fn: fn -> Agent.get(assets, & &1) end)

      assert_receive {:connected, _pid}
      assert_receive {:subscribed, _, ["a"]}

      # a sync stored a new market and announces it.
      Agent.update(assets, fn _ -> ["a", "b"] end)
      PubSub.broadcast(PolyBot.PubSub, "events:refreshed", {:events_refreshed, 1})

      assert_receive {:subscribed, _, ["b"]}
    end

    test "is a no-op when the refresh brings no new assets" do
      worker = start_worker(assets_fn: fn -> ["a"] end)

      assert_receive {:connected, _pid}
      assert_receive {:subscribed, _, ["a"]}

      send(worker, {:events_refreshed, 1})

      # synchronize on the worker having processed the refresh.
      _ = Worker.sockets(worker)
      refute_receive {:connected, _}
      refute_receive {:subscribed, _, _}
    end

    test "stays up when the assets query fails" do
      calls = start_supervised!({Agent, fn -> 0 end}, id: :calls)

      assets_fn = fn ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> []
          _ -> raise "db down"
        end
      end

      worker = start_worker(assets_fn: assets_fn)
      _ = Worker.sockets(worker)

      send(worker, {:events_refreshed, 1})

      # the raise is rescued: the worker still answers and holds no pool.
      assert Worker.sockets(worker) == %{sockets: [], pending_asset_count: 0}
    end
  end

  # ---------------------------------------------------------------------------#
  #                             connection restore                             #
  # ---------------------------------------------------------------------------#

  describe "connection restore" do
    test "resubscribes the assets of a dead connection on a fresh one" do
      worker = start_worker(conn_cap: 2)

      assert Worker.subscribe(worker, ["a", "b"]) == :ok
      assert_receive {:connected, pid}
      assert_receive {:subscribed, ^pid, ["a", "b"]}

      Process.exit(pid, :kill)

      assert_receive {:connected, new_pid}
      assert_receive {:subscribed, ^new_pid, assets}
      assert Enum.sort(assets) == ["a", "b"]
      assert Enum.map(Worker.sockets(worker).sockets, & &1.socket) == [new_pid]
    end

    test "restores the assets of several dead connections" do
      worker = start_worker(conn_cap: 1)

      assert Worker.subscribe(worker, ["a", "b"]) == :ok
      assert_receive {:connected, pid1}
      assert_receive {:connected, pid2}
      assert_receive {:subscribed, _, _}
      assert_receive {:subscribed, _, _}

      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)

      # both assets come back, whatever the restore batching.
      assert_receive {:subscribed, _, batch1}, 500
      assert_receive {:subscribed, _, batch2}, 500
      assert Enum.sort(batch1 ++ batch2) == ["a", "b"]
    end

    test "retries with backoff until connecting succeeds" do
      worker =
        start_worker(
          [retry_base_ms: 10, retry_max_ms: 40],
          [:ok, {:error, :econnrefused}, {:error, :econnrefused}]
        )

      assert Worker.subscribe(worker, ["a"]) == :ok
      assert_receive {:connected, pid}
      assert_receive {:subscribed, ^pid, ["a"]}

      Process.exit(pid, :kill)

      # the first restore attempt is immediate, backed-off retries follow
      # until the script is exhausted and connecting succeeds again.
      assert_receive :connect_failed, 500
      assert_receive :connect_failed, 500
      assert_receive {:connected, new_pid}, 500
      assert_receive {:subscribed, ^new_pid, ["a"]}

      snapshot = Worker.sockets(worker)
      assert Enum.map(snapshot.sockets, & &1.socket) == [new_pid]
      assert snapshot.pending_asset_count == 0
    end

    test "counts assets waiting to be resubscribed while restoring fails" do
      worker =
        start_worker(
          [retry_base_ms: 60_000, retry_max_ms: 60_000],
          [:ok, {:error, :econnrefused}]
        )

      assert Worker.subscribe(worker, ["a"]) == :ok
      assert_receive {:connected, pid}
      assert_receive {:subscribed, ^pid, ["a"]}

      Process.exit(pid, :kill)

      # the immediate restore attempt fails and the backed-off retry is far
      # in the future, so the asset stays parked.
      assert_receive :connect_failed, 500
      assert Worker.sockets(worker).pending_asset_count == 1
    end

    test "does not replace a dead connection that carried no assets" do
      worker =
        start_worker(
          [conn_cap: 1, retry_base_ms: 60_000, retry_max_ms: 60_000],
          [:ok, {:error, :timeout}, {:error, :timeout}]
        )

      # the subscribe opens one (empty) connection and fails on the second; the
      # immediate restore fails too, so the empty connection lingers with both
      # assets parked behind the far-off retry.
      assert Worker.subscribe(worker, ["a", "b"]) == :ok
      assert_receive {:connected, pid}
      assert_receive :connect_failed
      assert_receive :connect_failed, 500

      Process.exit(pid, :kill)

      # the dead connection carried no assets, so nothing new is parked and no
      # replacement is opened; the two assets stay parked for the retry.
      refute_receive {:connected, _}
      assert Worker.sockets(worker) == %{sockets: [], pending_asset_count: 2}
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # Starts an unnamed worker whose connections are bare processes that live
  # until killed (or until the test ends). Connect results follow `script`
  # (`:ok` spawns a connection, `{:error, _}` fails); an exhausted script
  # keeps succeeding. Every connect and subscribe is reported to the test
  # process as `{:connected, pid}` / `:connect_failed` / `{:subscribed, pid,
  # asset_ids}`.
  defp start_worker(opts, script \\ []) do
    test_pid = self()
    agent = start_supervised!({Agent, fn -> script end})

    connect_fn = fn -> scripted_connect(agent, test_pid) end

    subscribe_fn = fn pid, asset_ids ->
      send(test_pid, {:subscribed, pid, asset_ids})
      :ok
    end

    start_supervised!(
      {Worker, [name: nil, connect_fn: connect_fn, subscribe_fn: subscribe_fn] ++ opts}
    )
  end

  defp scripted_connect(agent, test_pid) do
    case Agent.get_and_update(agent, fn
           [] -> {:ok, []}
           [result | rest] -> {result, rest}
         end) do
      :ok ->
        pid = spawn(fn -> fake_connection(test_pid) end)
        send(test_pid, {:connected, pid})
        {:ok, pid}

      {:error, reason} ->
        send(test_pid, :connect_failed)
        {:error, reason}
    end
  end

  # idles until the owning test exits, so fake connections don't outlive it.
  defp fake_connection(test_pid) do
    ref = Process.monitor(test_pid)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    end
  end
end
