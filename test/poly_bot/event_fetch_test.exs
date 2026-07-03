defmodule PolyBot.EventFetchTest do
  use PolyBot.DataCase, async: false

  alias PolyBot.Contexts.Events
  alias PolyBot.Contexts.Markets
  alias PolyBot.EventFetch
  alias PolyBot.Fixtures
  alias PolyBot.Support.FakeGamma

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

    test "stores the markets nested on each event, linked to the owning event" do
      FakeGamma.set([
        Fixtures.gamma_event(
          id: "evt-with-markets",
          markets: [
            Fixtures.gamma_market(id: "mkt-a", active: true, outcomes: ["Yes", "No"]),
            Fixtures.gamma_market(id: "mkt-b", closed: true)
          ]
        )
      ])

      assert EventFetch.sync_events() == 1

      assert [event] = Events.list_events()
      markets = Markets.list_markets()

      assert length(markets) == 2
      assert Enum.all?(markets, &(&1.event_id == event.id))

      external_ids = markets |> Enum.map(& &1.external_id) |> Enum.sort()
      assert external_ids == ["mkt-a", "mkt-b"]

      mkt_a = Enum.find(markets, &(&1.external_id == "mkt-a"))
      assert mkt_a.active == true
      assert mkt_a.outcomes == ["Yes", "No"]
    end

    test "persists no markets for an event that has none" do
      FakeGamma.set([Fixtures.gamma_event(id: "no-markets")])

      assert EventFetch.sync_events() == 1
      assert Markets.list_markets() == []
    end

    test "re-syncing refreshes existing markets instead of duplicating them" do
      FakeGamma.set([
        Fixtures.gamma_event(id: "e", markets: [Fixtures.gamma_market(id: "m", closed: false)])
      ])

      assert EventFetch.sync_events() == 1

      FakeGamma.set([
        Fixtures.gamma_event(id: "e", markets: [Fixtures.gamma_market(id: "m", closed: true)])
      ])

      assert EventFetch.sync_events() == 1

      assert [market] = Markets.list_markets()
      assert market.external_id == "m"
      assert market.closed == true
    end

    test "prunes markets an event no longer reports on the next sync" do
      FakeGamma.set([
        Fixtures.gamma_event(
          id: "e",
          markets: [Fixtures.gamma_market(id: "m1"), Fixtures.gamma_market(id: "m2")]
        )
      ])

      assert EventFetch.sync_events() == 1
      assert length(Markets.list_markets()) == 2

      # m2 is gone from the event's payload on the next sync.
      FakeGamma.set([Fixtures.gamma_event(id: "e", markets: [Fixtures.gamma_market(id: "m1")])])

      assert EventFetch.sync_events() == 1

      external_ids = Markets.list_markets() |> Enum.map(& &1.external_id)
      assert external_ids == ["m1"]
    end

    test "does not prune markets of events absent from the current sync" do
      FakeGamma.set([
        Fixtures.gamma_event(id: "a", markets: [Fixtures.gamma_market(id: "ma")]),
        Fixtures.gamma_event(id: "b", markets: [Fixtures.gamma_market(id: "mb")])
      ])

      assert EventFetch.sync_events() == 2
      assert length(Markets.list_markets()) == 2

      # A later sync only sees event "a"; event "b"'s market must survive.
      FakeGamma.set([Fixtures.gamma_event(id: "a", markets: [Fixtures.gamma_market(id: "ma")])])

      assert EventFetch.sync_events() == 1

      external_ids = Markets.list_markets() |> Enum.map(& &1.external_id) |> Enum.sort()
      assert external_ids == ["ma", "mb"]
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
