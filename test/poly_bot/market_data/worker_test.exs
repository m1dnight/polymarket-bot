defmodule PolyBot.MarketData.WorkerTest do
  @moduledoc """
  Exercises the `PolyBot.MarketData.Worker` GenServer callbacks directly.

  The application boots a named `PolyBot.MarketData.Worker` (sweep disabled)
  that owns the shared `:market_state` table, so we never call `start_link/1`
  here — it would clash on the name — and every `init/1` call passes a private
  `:table` (creating `:market_state` again would raise). Driving the callbacks
  in the test process means `Process.send_after(self(), :sweep, _)` delivers
  `:sweep` right back to us, and the private table dies with the test.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PolyBot.MarketData.Worker

  @staleness_event [:poly_bot, :market_data, :staleness]

  # ---------------------------------------------------------------------------#
  #                                start_link/1                                #
  # ---------------------------------------------------------------------------#

  describe "start_link/1" do
    test "is a named singleton — the app already runs one, so a second refuses" do
      assert {:error, {:already_started, pid}} = Worker.start_link()
      assert pid == Process.whereis(Worker)
    end
  end

  # ---------------------------------------------------------------------------#
  #                                  init/1                                    #
  # ---------------------------------------------------------------------------#

  describe "init/1" do
    test "creates the table with the shape the write/read paths expect" do
      assert {:ok, _state} = Worker.init(table: :md_worker_test_init, sweep_interval_ms: 0)

      info = :ets.info(:md_worker_test_init)
      assert info[:type] == :set
      assert info[:protection] == :public
      assert info[:named_table]
      assert info[:read_concurrency]
      assert info[:write_concurrency]
    end

    test "does not schedule a sweep when sweeping is disabled (sweep_interval_ms: 0)" do
      assert {:ok, _state} = Worker.init(table: :md_worker_test_disabled, sweep_interval_ms: 0)

      refute_receive :sweep, 30
    end

    test "schedules a sweep when the interval is positive" do
      assert {:ok, _state} = Worker.init(table: :md_worker_test_enabled, sweep_interval_ms: 5)

      assert_receive :sweep, 300
    end

    test "defaults the interval to 5s and the threshold to 30s" do
      assert {:ok, state} = Worker.init(table: :md_worker_test_defaults)

      assert state.sweep_interval_ms == 5_000
      assert state.staleness_threshold_ms == 30_000
      refute state.feed_stale?
    end
  end

  # ---------------------------------------------------------------------------#
  #                             handle_info/2                                  #
  # ---------------------------------------------------------------------------#

  describe "handle_info(:sweep, state)" do
    test "sweeps the table, emits telemetry, and reschedules" do
      {:ok, state} = Worker.init(table: :md_worker_test_sweep, sweep_interval_ms: 5)
      assert_receive :sweep, 300

      ref = :telemetry_test.attach_event_handlers(self(), [@staleness_event])

      assert {:noreply, ^state} = Worker.handle_info(:sweep, state)

      assert_received {@staleness_event, ^ref, %{total: 0}, _metadata}
      assert_receive :sweep, 300
    end

    test "logs when the whole feed freezes, once, and again when it recovers" do
      table = :md_worker_test_freeze

      {:ok, state} =
        Worker.init(table: table, sweep_interval_ms: 0, staleness_threshold_ms: 10)

      :ets.insert(table, {"a", 0.4, 0.6, 0, System.monotonic_time(:millisecond) - 60_000})

      {result, log} = with_log(fn -> Worker.handle_info(:sweep, state) end)
      assert {:noreply, %{feed_stale?: true} = frozen} = result
      assert log =~ "no top-of-book update"

      # still frozen: no repeat warning.
      {result, log} = with_log(fn -> Worker.handle_info(:sweep, frozen) end)
      assert {:noreply, %{feed_stale?: true}} = result
      refute log =~ "no top-of-book update"

      # a fresh write thaws the feed; the recovery is logged at :info, which
      # the test logger level (:warning) drops, so only assert the state flip.
      :ets.insert(table, {"a", 0.4, 0.6, 0, System.monotonic_time(:millisecond)})
      assert {:noreply, %{feed_stale?: false}} = Worker.handle_info(:sweep, frozen)
    end

    test "an empty table never counts as frozen" do
      {:ok, state} =
        Worker.init(
          table: :md_worker_test_empty,
          sweep_interval_ms: 0,
          staleness_threshold_ms: 10
        )

      assert {:noreply, %{feed_stale?: false}} = Worker.handle_info(:sweep, state)
    end
  end
end
