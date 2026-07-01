defmodule PolyBot.Contexts.EventsTest do
  use PolyBot.DataCase, async: true

  alias PolyBot.Contexts.Events
  alias PolyBot.Contexts.Markets
  alias PolyBot.Contexts.Schemas.Event
  alias PolyBot.Contexts.Schemas.EventPayload
  alias PolyBot.Fixtures

  describe "list_events/0" do
    test "returns [] when there are no events" do
      assert Events.list_events() == []
    end

    test "returns events newest first (desc inserted_at, then desc id)" do
      first = Fixtures.event_fixture()
      second = Fixtures.event_fixture()

      ids = Enum.map(Events.list_events(), & &1.id)
      assert ids == [second.id, first.id]
    end
  end

  describe "get_event!/1" do
    test "returns the event with the given id" do
      event = Fixtures.event_fixture()
      assert %Event{} = fetched = Events.get_event!(event.id)
      assert fetched.id == event.id
      assert fetched.external_id == event.external_id
    end

    test "raises Ecto.NoResultsError for a missing id" do
      assert_raise Ecto.NoResultsError, fn -> Events.get_event!(-1) end
    end
  end

  describe "create_event/1" do
    test "inserts an event for valid attrs" do
      assert {:ok, %Event{} = event} =
               Events.create_event(%{external_id: "ext-create", active: true, closed: false})

      assert event.id
      assert event.external_id == "ext-create"
      assert event.active == true
      assert event.closed == false
    end

    test "returns an error changeset when external_id is missing" do
      assert {:error, %Ecto.Changeset{} = changeset} = Events.create_event(%{active: true})
      assert %{external_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "defaults to blank attrs, which fail validation" do
      assert {:error, %Ecto.Changeset{} = changeset} = Events.create_event()
      assert %{external_id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "upsert_event/1" do
    test "inserts a new event" do
      assert {:ok, %Event{} = event} =
               Events.upsert_event(%{external_id: "up-1", active: true, closed: false})

      assert event.id
      assert event.external_id == "up-1"
    end

    test "updates the existing row on a repeated external_id and refreshes flags" do
      assert {:ok, first} =
               Events.upsert_event(%{
                 external_id: "up-same",
                 neg_risk: false,
                 active: true,
                 closed: false,
                 archived: false
               })

      assert {:ok, second} =
               Events.upsert_event(%{
                 external_id: "up-same",
                 neg_risk: true,
                 active: false,
                 closed: true,
                 archived: true
               })

      assert second.id == first.id
      assert second.neg_risk == true
      assert second.active == false
      assert second.closed == true
      assert second.archived == true

      # still exactly one row for that external_id
      assert Repo.aggregate(from(e in Event, where: e.external_id == "up-same"), :count) == 1
    end
  end

  describe "upsert_events/1" do
    test "returns {0, []} for an empty list" do
      assert {0, []} = Events.upsert_events([])
    end

    test "inserts two distinct external_ids and returns the count plus rows" do
      assert {2, rows} =
               Events.upsert_events([
                 %{external_id: "batch-1", active: true},
                 %{external_id: "batch-2", closed: true}
               ])

      # Returned rows carry the surrogate id + external_id so callers can link
      # owned rows (e.g. markets) without a second query.
      assert length(rows) == 2
      assert Enum.all?(rows, & &1.id)

      returned_ids = rows |> Enum.map(& &1.external_id) |> Enum.sort()
      assert returned_ids == ["batch-1", "batch-2"]

      external_ids =
        Event
        |> Repo.all()
        |> Enum.map(& &1.external_id)
        |> Enum.sort()

      assert external_ids == ["batch-1", "batch-2"]
    end

    test "dedups duplicate external_ids within the list, first occurrence wins" do
      assert {1, [row]} =
               Events.upsert_events([
                 %{external_id: "dup", active: true},
                 %{external_id: "dup", active: false}
               ])

      assert row.external_id == "dup"

      event = Repo.get_by!(Event, external_id: "dup")
      assert event.active == true
    end

    test "refreshes status flags on conflict and returns the existing surrogate id" do
      existing = Fixtures.event_fixture(%{external_id: "conflict", active: true, closed: false})

      assert {1, [row]} =
               Events.upsert_events([
                 %{
                   external_id: "conflict",
                   neg_risk: true,
                   active: false,
                   closed: true,
                   archived: true
                 }
               ])

      # The conflict-updated row comes back with the row's original surrogate id.
      assert row.id == existing.id

      event = Repo.get_by!(Event, external_id: "conflict")
      assert event.neg_risk == true
      assert event.active == false
      assert event.closed == true
      assert event.archived == true

      assert Repo.aggregate(from(e in Event, where: e.external_id == "conflict"), :count) == 1
    end

    test "preserves inserted_at but refreshes updated_at on conflict" do
      old = ~U[2020-01-01 00:00:00Z]
      Repo.insert_all(Event, [%{external_id: "keep-inserted", inserted_at: old, updated_at: old}])

      assert {1, _} = Events.upsert_events([%{external_id: "keep-inserted", active: false}])

      event = Repo.get_by!(Event, external_id: "keep-inserted")
      assert event.inserted_at == old
      assert DateTime.compare(event.updated_at, old) == :gt
    end

    test "sets timestamps on inserted rows" do
      assert {1, _} = Events.upsert_events([%{external_id: "ts", active: true}])

      event = Repo.get_by!(Event, external_id: "ts")
      assert event.inserted_at
      assert event.updated_at
    end
  end

  describe "update_event/2" do
    test "updates an event for valid attrs" do
      event = Fixtures.event_fixture(%{closed: false})
      assert {:ok, %Event{} = updated} = Events.update_event(event, %{closed: true})
      assert updated.id == event.id
      assert updated.closed == true
    end

    test "returns an error changeset when external_id is set to nil" do
      event = Fixtures.event_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Events.update_event(event, %{external_id: nil})

      assert %{external_id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "delete_event/1" do
    test "deletes the event" do
      event = Fixtures.event_fixture()
      assert {:ok, %Event{}} = Events.delete_event(event)
      assert_raise Ecto.NoResultsError, fn -> Events.get_event!(event.id) end
    end

    test "cascades the stored payload away" do
      event = Fixtures.event_fixture()
      assert {:ok, %EventPayload{}} = Events.put_payload(event, %{"title" => "cascade"})

      assert {:ok, %Event{}} = Events.delete_event(event)

      assert Repo.get_by(EventPayload, event_id: event.id) == nil
    end
  end

  describe "change_event/1,2" do
    test "returns a changeset for a blank event" do
      assert %Ecto.Changeset{} = Events.change_event()
    end

    test "returns a changeset for the given event and attrs" do
      event = Fixtures.event_fixture()
      assert %Ecto.Changeset{changes: changes} = Events.change_event(event, %{active: false})
      assert changes.active == false
    end
  end

  describe "put_payload/2" do
    test "stores the raw payload" do
      event = Fixtures.event_fixture()

      assert {:ok, %EventPayload{} = payload} =
               Events.put_payload(event, %{"title" => "Will it rain?"})

      assert payload.event_id == event.id
      assert payload.raw == %{"title" => "Will it rain?"}
    end

    test "replaces an existing payload so only one row survives with the latest raw" do
      event = Fixtures.event_fixture()

      assert {:ok, _} = Events.put_payload(event, %{"title" => "first"})
      assert {:ok, _} = Events.put_payload(event, %{"title" => "second"})

      assert Repo.aggregate(from(p in EventPayload, where: p.event_id == ^event.id), :count) == 1
      assert Events.get_payload(event) == %{"title" => "second"}
    end
  end

  describe "get_payload/1" do
    test "returns the stored raw as a string-keyed map" do
      event = Fixtures.event_fixture()
      assert {:ok, _} = Events.put_payload(event, %{"title" => "x", "n" => 1})

      assert Events.get_payload(event) == %{"title" => "x", "n" => 1}
    end

    test "returns nil when the event has no payload" do
      event = Fixtures.event_fixture()
      assert Events.get_payload(event) == nil
    end
  end

  describe "replace_markets/2" do
    test "returns {0, 0} for empty inputs" do
      assert {0, 0} = Events.replace_markets([], [])
    end

    test "upserts the given markets and returns the counts" do
      event = Fixtures.event_fixture()

      assert {2, 0} =
               Events.replace_markets([event.id], [
                 %{external_id: "rm-1", event_id: event.id, active: true},
                 %{external_id: "rm-2", event_id: event.id, closed: true}
               ])

      external_ids = Markets.list_markets() |> Enum.map(& &1.external_id) |> Enum.sort()
      assert external_ids == ["rm-1", "rm-2"]
    end

    test "deletes markets of the given events that are absent from the fresh set" do
      event = Fixtures.event_fixture()
      keep = Fixtures.market_fixture(%{event_id: event.id, external_id: "keep"})
      _obsolete = Fixtures.market_fixture(%{event_id: event.id, external_id: "gone"})

      assert {1, 1} =
               Events.replace_markets([event.id], [
                 %{external_id: "keep", event_id: event.id, active: true}
               ])

      external_ids = Markets.list_markets() |> Enum.map(& &1.external_id)
      assert external_ids == ["keep"]
      assert Markets.get_market!(keep.id).external_id == "keep"
    end

    test "prunes every market when an event reports none" do
      event = Fixtures.event_fixture()
      Fixtures.market_fixture(%{event_id: event.id})
      Fixtures.market_fixture(%{event_id: event.id})

      assert {0, 2} = Events.replace_markets([event.id], [])
      assert Markets.list_markets() == []
    end

    test "never touches markets owned by events outside event_ids" do
      synced = Fixtures.event_fixture()
      other = Fixtures.event_fixture()
      other_market = Fixtures.market_fixture(%{event_id: other.id, external_id: "other"})

      # syncing `synced` with no markets must not delete `other`'s market.
      assert {0, 0} = Events.replace_markets([synced.id], [])

      assert Markets.get_market!(other_market.id).external_id == "other"
    end
  end
end
