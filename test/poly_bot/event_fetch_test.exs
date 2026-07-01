defmodule PolyBot.EventFetchTest do
  use PolyBot.DataCase, async: false

  alias PolyBot.EventFetch
  alias PolyBot.Contexts.Events
  alias PolyBot.Support.FakeGamma
  alias PolyBot.Fixtures

  setup do
    Application.put_env(:poly_bot, :gamma_client, FakeGamma)
    on_exit(fn -> Application.delete_env(:poly_bot, :gamma_client) end)
    :ok
  end

  describe "sync_events/1" do
    test "stores each gamma event and returns the number persisted" do
      FakeGamma.set([Fixtures.gamma_event(id: "1"), Fixtures.gamma_event(id: "2")])

      assert EventFetch.sync_events() == 2

      events = Events.list_events()
      assert length(events) == 2

      external_ids = events |> Enum.map(& &1.external_id) |> Enum.sort()
      assert external_ids == ["1", "2"]
    end

    test "maps gamma fields onto the stored event (enable_neg_risk -> neg_risk)" do
      FakeGamma.set([
        Fixtures.gamma_event(
          id: "mapped",
          enable_neg_risk: true,
          active: false,
          closed: true,
          archived: true
        )
      ])

      assert EventFetch.sync_events() == 1

      assert [event] = Events.list_events()
      assert event.external_id == "mapped"
      assert event.neg_risk == true
      assert event.active == false
      assert event.closed == true
      assert event.archived == true
    end

    test "returns 0 and persists nothing for an empty stream" do
      FakeGamma.set([])

      assert EventFetch.sync_events() == 0
      assert Events.list_events() == []
    end

    test "chunks the stream and sums the per-chunk counts across 250 events" do
      gamma_events = Enum.map(1..250, fn i -> Fixtures.gamma_event(id: "id-#{i}") end)
      FakeGamma.set(gamma_events)

      assert EventFetch.sync_events() == 250
      assert length(Events.list_events()) == 250
    end

    test "forwards opts to the gamma client's stream_events/1" do
      test = self()

      FakeGamma.set(fn opts ->
        send(test, {:opts, opts})
        []
      end)

      assert EventFetch.sync_events(closed: false) == 0
      assert_receive {:opts, [closed: false]}
    end
  end
end
