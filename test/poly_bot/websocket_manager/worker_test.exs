defmodule PolyBot.WebSocketManager.WorkerTest do
  @moduledoc """
  Exercises `PolyBot.WebSocketManager.Worker` through its public API.

  The application boots a named singleton, so every test starts a private,
  unnamed instance (`name: nil`) with injected `connect_fn`/`subscribe_fn`
  stubs — no real websocket connection is ever opened. Stub connections are
  plain idle processes the worker can monitor.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PolyBot.WebSocketManager.Worker

  # Starts a private worker whose connect/subscribe side effects are messages
  # sent back to the test process.
  defp start_worker(opts) do
    test_pid = self()

    defaults = [
      name: nil,
      connect_fn: fn ->
        pid = spawn(fn -> receive(do: (:stop -> :ok)) end)
        send(test_pid, {:connected, pid})
        {:ok, pid}
      end,
      subscribe_fn: fn pid, ids ->
        send(test_pid, {:subscribed, pid, ids})
        :ok
      end
    ]

    start_supervised!({Worker, Keyword.merge(defaults, opts)})
  end

  describe "subscribe/2" do
    test "opens a connection on demand and subscribes the asset ids" do
      worker = start_worker(max_assets_per_connection: 10)

      assert Worker.subscribe(worker, ["a", "b"]) == :ok

      assert_receive {:connected, conn}
      assert_receive {:subscribed, ^conn, ["a", "b"]}
      assert Worker.connections(worker) == %{conn => MapSet.new(["a", "b"])}
    end

    test "fills existing capacity before opening a new connection" do
      worker = start_worker(max_assets_per_connection: 2)

      assert Worker.subscribe(worker, ["a"]) == :ok
      assert_receive {:connected, first}

      assert Worker.subscribe(worker, ["b", "c"]) == :ok

      # "b" tops up the first connection; "c" overflows into a second one.
      assert_receive {:subscribed, ^first, ["b"]}
      assert_receive {:connected, second}
      assert_receive {:subscribed, ^second, ["c"]}

      assert Worker.connections(worker) == %{
               first => MapSet.new(["a", "b"]),
               second => MapSet.new(["c"])
             }
    end

    test "skips asset ids that are already subscribed" do
      worker = start_worker(max_assets_per_connection: 10)

      assert Worker.subscribe(worker, ["a"]) == :ok
      assert_receive {:subscribed, conn, ["a"]}

      assert Worker.subscribe(worker, ["a", "b"]) == :ok
      assert_receive {:subscribed, ^conn, ["b"]}
      assert Worker.connections(worker) == %{conn => MapSet.new(["a", "b"])}
    end

    test "is a no-op when every id is already subscribed" do
      worker = start_worker(max_assets_per_connection: 10)

      assert Worker.subscribe(worker, ["a"]) == :ok
      assert_receive {:subscribed, _conn, ["a"]}

      assert Worker.subscribe(worker, ["a", "a"]) == :ok
      refute_receive {:subscribed, _, _}, 30
    end

    test "returns the error when opening a connection fails" do
      worker = start_worker(connect_fn: fn -> {:error, :refused} end)

      assert Worker.subscribe(worker, ["a"]) == {:error, :refused}
      assert Worker.connections(worker) == %{}
    end
  end

  describe "handle_info {:DOWN, ...}" do
    test "drops a dead connection from the pool" do
      worker = start_worker(max_assets_per_connection: 10)

      assert Worker.subscribe(worker, ["a"]) == :ok
      assert_receive {:connected, conn}

      log =
        capture_log(fn ->
          ref = Process.monitor(conn)
          Process.exit(conn, :kill)
          assert_receive {:DOWN, ^ref, :process, ^conn, :killed}

          # The worker's own :DOWN was enqueued at death; this call syncs past it.
          _ = :sys.get_state(worker)
          assert Worker.connections(worker) == %{}
        end)

      assert log =~ "went down"
    end
  end
end
