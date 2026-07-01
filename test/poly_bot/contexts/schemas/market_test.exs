defmodule PolyBot.Contexts.Schemas.MarketTest do
  use PolyBot.DataCase, async: true

  alias PolyBot.Contexts.Schemas.Market
  alias PolyBot.Fixtures

  describe "changeset/2" do
    test "is valid with external_id + event_id and casts array fields" do
      event = Fixtures.event_fixture()

      attrs = %{
        external_id: "mkt-#{System.unique_integer([:positive])}",
        event_id: event.id,
        enable_order_book: true,
        active: true,
        closed: false,
        accepting_orders: true,
        uma_resolution_status: "resolved",
        clob_token_ids: ["tok-yes", "tok-no"],
        outcomes: ["Yes", "No"]
      }

      changeset = Market.changeset(%Market{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :clob_token_ids) == ["tok-yes", "tok-no"]
      assert get_change(changeset, :outcomes) == ["Yes", "No"]
      assert get_change(changeset, :external_id) == attrs.external_id
      assert get_change(changeset, :event_id) == event.id
    end

    test "persists and round-trips array fields through the database" do
      event = Fixtures.event_fixture()

      {:ok, market} =
        %Market{}
        |> Market.changeset(%{
          external_id: "mkt-#{System.unique_integer([:positive])}",
          event_id: event.id,
          clob_token_ids: ["a", "b"],
          outcomes: ["Yes", "No"]
        })
        |> Repo.insert()

      reloaded = Repo.get!(Market, market.id)
      assert reloaded.clob_token_ids == ["a", "b"]
      assert reloaded.outcomes == ["Yes", "No"]
    end

    test "is invalid and requires external_id and event_id when both are missing" do
      changeset = Market.changeset(%Market{}, %{})

      refute changeset.valid?

      errors = errors_on(changeset)
      assert "can't be blank" in errors.external_id
      assert "can't be blank" in errors.event_id
    end

    test "is invalid when only event_id is missing" do
      changeset = Market.changeset(%Market{}, %{external_id: "mkt-x"})

      refute changeset.valid?

      errors = errors_on(changeset)
      assert "can't be blank" in errors.event_id
      refute Map.has_key?(errors, :external_id)
    end

    test "assoc_constraint rejects a non-existent event_id on insert" do
      changeset =
        Market.changeset(%Market{}, %{
          external_id: "mkt-#{System.unique_integer([:positive])}",
          event_id: 999_999
        })

      assert {:error, cs} = Repo.insert(changeset)
      assert "does not exist" in errors_on(cs).event
    end

    test "unique_constraint rejects a duplicate external_id on insert" do
      event = Fixtures.event_fixture()
      external_id = "mkt-#{System.unique_integer([:positive])}"

      assert {:ok, _first} =
               %Market{}
               |> Market.changeset(%{external_id: external_id, event_id: event.id})
               |> Repo.insert()

      assert {:error, cs} =
               %Market{}
               |> Market.changeset(%{external_id: external_id, event_id: event.id})
               |> Repo.insert()

      assert "has already been taken" in errors_on(cs).external_id
    end
  end
end
