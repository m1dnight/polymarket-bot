defmodule PolyBot.Contexts.MarketsTest do
  use PolyBot.DataCase, async: true

  alias PolyBot.Contexts.Markets
  alias PolyBot.Contexts.Schemas.Market
  alias PolyBot.Fixtures

  describe "list_markets/0" do
    test "returns [] when there are no markets" do
      assert Markets.list_markets() == []
    end

    test "returns every stored market, oldest first (asc id)" do
      first = Fixtures.market_fixture()
      second = Fixtures.market_fixture()

      ids = Enum.map(Markets.list_markets(), & &1.id)
      assert ids == [first.id, second.id]
    end
  end

  describe "count_markets/0" do
    test "returns 0 when there are no markets" do
      assert Markets.count_markets() == 0
    end

    test "returns the number of stored markets" do
      Fixtures.market_fixture()
      Fixtures.market_fixture()

      assert Markets.count_markets() == 2
    end
  end

  describe "get_market!/1" do
    test "returns the market with the given id" do
      market = Fixtures.market_fixture()

      fetched = Markets.get_market!(market.id)
      assert %Market{} = fetched
      assert fetched.id == market.id
      assert fetched.external_id == market.external_id
    end

    test "raises Ecto.NoResultsError for a missing id" do
      assert_raise Ecto.NoResultsError, fn -> Markets.get_market!(-1) end
    end
  end

  describe "create_market/1" do
    test "inserts a market from valid attrs" do
      event = Fixtures.event_fixture()

      attrs = %{
        external_id: "mkt-create-#{System.unique_integer([:positive])}",
        event_id: event.id,
        active: true,
        closed: false,
        accepting_orders: true,
        enable_order_book: true,
        uma_resolution_status: "resolved",
        clob_token_ids: ["tok-yes", "tok-no"],
        outcomes: ["Yes", "No"]
      }

      assert {:ok, %Market{} = market} = Markets.create_market(attrs)
      assert market.external_id == attrs.external_id
      assert market.event_id == event.id
      assert market.active == true
      assert market.closed == false
      assert market.accepting_orders == true
      assert market.enable_order_book == true
      assert market.uma_resolution_status == "resolved"
      assert market.clob_token_ids == ["tok-yes", "tok-no"]
      assert market.outcomes == ["Yes", "No"]
    end

    test "returns an error changeset when required fields are missing" do
      assert {:error, %Ecto.Changeset{} = changeset} = Markets.create_market(%{active: true})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.external_id
      assert "can't be blank" in errors.event_id
    end

    test "defaults to blank attrs, which fail validation" do
      assert {:error, %Ecto.Changeset{} = changeset} = Markets.create_market()

      errors = errors_on(changeset)
      assert "can't be blank" in errors.external_id
      assert "can't be blank" in errors.event_id
    end

    test "returns an error changeset when the owning event does not exist" do
      attrs = %{
        external_id: "mkt-bad-event-#{System.unique_integer([:positive])}",
        event_id: -1
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Markets.create_market(attrs)
      assert "does not exist" in errors_on(changeset).event
    end

    test "enforces external_id uniqueness" do
      existing = Fixtures.market_fixture()
      event = Fixtures.event_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Markets.create_market(%{external_id: existing.external_id, event_id: event.id})

      assert "has already been taken" in errors_on(changeset).external_id
    end
  end

  describe "upsert_market/1" do
    test "inserts a new market" do
      event = Fixtures.event_fixture()

      attrs = %{
        external_id: "up-mkt-#{System.unique_integer([:positive])}",
        event_id: event.id,
        active: true,
        closed: false
      }

      assert {:ok, %Market{} = market} = Markets.upsert_market(attrs)
      assert market.external_id == attrs.external_id
      assert market.event_id == event.id
    end

    test "refreshes flags on conflict with an existing external_id, keeping the row" do
      market =
        Fixtures.market_fixture(%{
          external_id: "up-conflict",
          closed: false,
          accepting_orders: true
        })

      assert {:ok, %Market{} = updated} =
               Markets.upsert_market(%{
                 external_id: "up-conflict",
                 event_id: market.event_id,
                 closed: true,
                 accepting_orders: false
               })

      assert updated.id == market.id
      assert updated.closed == true
      assert updated.accepting_orders == false
      assert length(Markets.list_markets()) == 1
    end
  end

  describe "upsert_markets/1" do
    test "returns {0, nil} for an empty list" do
      assert {0, nil} = Markets.upsert_markets([])
    end

    test "inserts multiple markets and returns the count" do
      event = Fixtures.event_fixture()

      assert {2, nil} =
               Markets.upsert_markets([
                 %{external_id: "bm-1", event_id: event.id, active: true},
                 %{external_id: "bm-2", event_id: event.id, closed: true}
               ])

      external_ids = Markets.list_markets() |> Enum.map(& &1.external_id) |> Enum.sort()
      assert external_ids == ["bm-1", "bm-2"]
    end

    test "dedups duplicate external_ids within the list, first occurrence wins" do
      event = Fixtures.event_fixture()

      assert {1, nil} =
               Markets.upsert_markets([
                 %{external_id: "bm-dup", event_id: event.id, active: true},
                 %{external_id: "bm-dup", event_id: event.id, active: false}
               ])

      market = Enum.find(Markets.list_markets(), &(&1.external_id == "bm-dup"))
      assert market.active == true
    end

    test "refreshes flags on conflict with an existing row" do
      market = Fixtures.market_fixture(%{external_id: "bm-conflict", closed: false})

      assert {1, nil} =
               Markets.upsert_markets([
                 %{external_id: "bm-conflict", event_id: market.event_id, closed: true}
               ])

      refreshed = Markets.get_market!(market.id)
      assert refreshed.closed == true
      assert length(Markets.list_markets()) == 1
    end

    test "sets timestamps on inserted rows" do
      event = Fixtures.event_fixture()

      assert {1, nil} = Markets.upsert_markets([%{external_id: "bm-ts", event_id: event.id}])

      market = Enum.find(Markets.list_markets(), &(&1.external_id == "bm-ts"))
      assert market.inserted_at
      assert market.updated_at
    end
  end

  describe "update_market/2" do
    test "updates a market with valid attrs" do
      market = Fixtures.market_fixture(%{accepting_orders: true})

      assert {:ok, %Market{} = updated} =
               Markets.update_market(market, %{accepting_orders: false})

      assert updated.id == market.id
      assert updated.accepting_orders == false
      assert Markets.get_market!(market.id).accepting_orders == false
    end

    test "returns an error changeset when external_id is set to nil" do
      market = Fixtures.market_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Markets.update_market(market, %{external_id: nil})

      assert "can't be blank" in errors_on(changeset).external_id
      assert Markets.get_market!(market.id).external_id == market.external_id
    end
  end

  describe "delete_market/1" do
    test "deletes the market" do
      market = Fixtures.market_fixture()

      assert {:ok, %Market{} = deleted} = Markets.delete_market(market)
      assert deleted.id == market.id
      assert_raise Ecto.NoResultsError, fn -> Markets.get_market!(market.id) end
    end
  end

  describe "change_market/1,2" do
    test "returns a changeset for a blank market by default" do
      assert %Ecto.Changeset{data: %Market{}} = Markets.change_market(%Market{})
    end

    test "returns a changeset reflecting the given attrs" do
      market = Fixtures.market_fixture()

      changeset = Markets.change_market(market, %{closed: true})
      assert %Ecto.Changeset{data: %Market{}} = changeset
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :closed) == true
    end
  end
end
