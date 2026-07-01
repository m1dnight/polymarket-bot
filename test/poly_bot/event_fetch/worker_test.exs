defmodule PolyBot.EventFetch.WorkerTest do
  @moduledoc """
  Exercises the `PolyBot.EventFetch.Worker` GenServer callbacks directly.

  The application boots a named `PolyBot.EventFetch.Worker` (interval 0, polling
  disabled), so we never call `start_link/1` here — it would clash on the name.
  Instead we drive `init/1` and `handle_info/2` in the test process itself, which
  means `Process.send_after(self(), :fetch, _)` delivers `:fetch` right back to
  us and the Ecto sandbox connection is shared.
  """

  use PolyBot.DataCase, async: false

  import ExUnit.CaptureLog

  alias PolyBot.Contexts.Events
  alias PolyBot.EventFetch.Worker
  alias PolyBot.Fixtures
  alias PolyBot.Support.FakeGamma

  setup do
    Application.put_env(:poly_bot, :gamma_client, FakeGamma)
    on_exit(fn -> Application.delete_env(:poly_bot, :gamma_client) end)
    :ok
  end

  # ---------------------------------------------------------------------------#
  #                                start_link/1                                 #
  # ---------------------------------------------------------------------------#

  describe "start_link/1" do
    test "is a named singleton — the app already runs one, so a second refuses" do
      assert {:error, {:already_started, pid}} = Worker.start_link()
      assert pid == Process.whereis(Worker)
    end
  end

  # ---------------------------------------------------------------------------#
  #                                init/1                                       #
  # ---------------------------------------------------------------------------#

  describe "init/1" do
    test "does not schedule a fetch when polling is disabled (interval_ms: 0)" do
      assert Worker.init(interval_ms: 0, fetch_opts: []) ==
               {:ok, %{interval_ms: 0, fetch_opts: []}}

      refute_receive :fetch, 30
    end

    test "does not schedule a fetch for a negative interval" do
      assert {:ok, %{interval_ms: -5, fetch_opts: []}} = Worker.init(interval_ms: -5)

      refute_receive :fetch, 30
    end

    test "schedules a fetch when interval_ms is positive" do
      assert {:ok, %{interval_ms: 10, fetch_opts: []}} = Worker.init(interval_ms: 10)

      assert_receive :fetch, 300
    end

    test "carries fetch_opts through into the state" do
      assert {:ok, %{interval_ms: 0, fetch_opts: [closed: false]}} =
               Worker.init(interval_ms: 0, fetch_opts: [closed: false])
    end

    test "defaults interval to 5 minutes and fetch_opts to [] when unset" do
      assert {:ok, state} = Worker.init([])
      assert state.interval_ms == :timer.minutes(5)
      assert state.fetch_opts == []

      # 5 minutes away, so nothing arrives promptly.
      refute_receive :fetch, 30
    end
  end

  # ---------------------------------------------------------------------------#
  #                              handle_info/2                                  #
  # ---------------------------------------------------------------------------#

  describe "handle_info(:fetch, state)" do
    test "fetches, persists events, and reschedules the next fetch" do
      FakeGamma.set([Fixtures.gamma_event(id: "w1")])

      state = %{interval_ms: 10, fetch_opts: []}
      assert Worker.handle_info(:fetch, state) == {:noreply, state}

      external_ids = Enum.map(Events.list_events(), & &1.external_id)
      assert "w1" in external_ids

      # handle_info always reschedules regardless of the polling? check.
      assert_receive :fetch, 300
    end

    test "rescues a failing fetch, logs it, and still returns {:noreply, state}" do
      FakeGamma.set(fn _opts -> raise "boom" end)

      state = %{interval_ms: 10, fetch_opts: []}

      {result, log} = with_log(fn -> Worker.handle_info(:fetch, state) end)

      assert result == {:noreply, state}
      assert log =~ "EventFetch failed"
      assert log =~ "boom"
    end

    test "does not raise and stores nothing when the fetch fails" do
      FakeGamma.set(fn _opts -> raise "kaboom" end)

      capture_log(fn ->
        assert {:noreply, _state} = Worker.handle_info(:fetch, %{interval_ms: 0, fetch_opts: []})
      end)

      assert Events.list_events() == []
    end
  end
end
