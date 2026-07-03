defmodule PolyBot.WebSocketManager.WorkerTest do
  @moduledoc """
  Exercises `PolyBot.WebSocketManager.Worker` against fake connections.

  Each test starts an unnamed worker (the app already runs the named
  singleton) with `connect_fn`/`subscribe_fn` that message the test process,
  so no network is touched. Connect results are scripted through an Agent to
  drive the failure and retry paths.
  """

  use ExUnit.Case, async: true

  alias PolyBot.WebSocketManager.Worker

  @moduletag :capture_log

  # ---------------------------------------------------------------------------#
  #                                subscribe/2                                 #
  # ---------------------------------------------------------------------------#

  describe "subscribe/2" do
    test "spreads asset ids over connections, respecting the capacity" do
      worker = start_worker(max_assets_per_connection: 2)

      assert Worker.subscribe(worker, ["a", "b", "c"]) == :ok

      assert_receive {:connected, _pid1}
      assert_receive {:connected, _pid2}
      assert_receive {:subscribed, _, batch1}
      assert_receive {:subscribed, _, batch2}
      assert Enum.sort(batch1 ++ batch2) == ["a", "b", "c"]
      assert length(Worker.sockets(worker).sockets) == 2
    end

    test "fills free capacity before opening a new connection" do
      worker = start_worker(max_assets_per_connection: 2)

      assert Worker.subscribe(worker, ["a"]) == :ok
      assert_receive {:connected, _pid}
      assert_receive {:subscribed, _, ["a"]}

      assert Worker.subscribe(worker, ["b"]) == :ok
      assert_receive {:subscribed, _, ["b"]}
      refute_receive {:connected, _}
      assert length(Worker.sockets(worker).sockets) == 1
    end

    test "returns the error and subscribes nothing when connecting fails" do
      worker = start_worker([], [{:error, :econnrefused}])

      assert Worker.subscribe(worker, ["a"]) == {:error, :econnrefused}
      assert_receive :connect_failed
      refute_receive {:subscribed, _, _}
      assert Worker.sockets(worker) == %{sockets: [], pending_asset_count: 0}
    end

    test "keeps connections opened before the failure for the next call" do
      worker = start_worker([max_assets_per_connection: 1], [:ok, {:error, :timeout}])

      assert Worker.subscribe(worker, ["a", "b"]) == {:error, :timeout}
      assert_receive {:connected, _pid}
      assert_receive :connect_failed
      refute_receive {:subscribed, _, _}

      # the surviving connection covers the retried (smaller) subscription.
      assert Worker.subscribe(worker, ["a"]) == :ok
      assert_receive {:subscribed, _, ["a"]}
      refute_receive {:connected, _}
    end
  end

  # ---------------------------------------------------------------------------#
  #                             connection restore                             #
  # ---------------------------------------------------------------------------#

  describe "connection restore" do
    test "resubscribes the assets of a dead connection on a fresh one" do
      worker = start_worker(max_assets_per_connection: 2)

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
      worker = start_worker(max_assets_per_connection: 1)

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
      worker = start_worker([max_assets_per_connection: 1], [:ok, {:error, :timeout}])

      # opens one (empty) connection, then fails on the second.
      assert Worker.subscribe(worker, ["a", "b"]) == {:error, :timeout}
      assert_receive {:connected, pid}

      Process.exit(pid, :kill)

      refute_receive {:connected, _}
      assert Worker.sockets(worker) == %{sockets: [], pending_asset_count: 0}
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

    connect_fn = fn ->
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

    subscribe_fn = fn pid, asset_ids ->
      send(test_pid, {:subscribed, pid, asset_ids})
      :ok
    end

    start_supervised!(
      {Worker, [name: nil, connect_fn: connect_fn, subscribe_fn: subscribe_fn] ++ opts}
    )
  end

  # idles until the owning test exits, so fake connections don't outlive it.
  defp fake_connection(test_pid) do
    ref = Process.monitor(test_pid)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    end
  end
end
