defmodule PolyBot.Contexts.Schemas.EventTest do
  use PolyBot.DataCase, async: true

  alias PolyBot.Contexts.Schemas.Event
  alias PolyBot.Fixtures

  describe "changeset/2" do
    test "is valid and casts all status fields from full attrs" do
      attrs = %{
        external_id: "evt-full",
        neg_risk: true,
        active: false,
        closed: true,
        archived: true
      }

      changeset = Event.changeset(%Event{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :external_id) == "evt-full"
      assert Ecto.Changeset.get_change(changeset, :neg_risk) == true
      assert Ecto.Changeset.get_change(changeset, :active) == false
      assert Ecto.Changeset.get_change(changeset, :closed) == true
      assert Ecto.Changeset.get_change(changeset, :archived) == true
    end

    test "produces an insertable changeset with the applied field values" do
      changeset =
        Event.changeset(%Event{}, %{
          external_id: "evt-insertable",
          neg_risk: false,
          active: true,
          closed: false,
          archived: false
        })

      assert {:ok, event} = Repo.insert(changeset)
      assert event.external_id == "evt-insertable"
      assert event.neg_risk == false
      assert event.active == true
      assert event.closed == false
      assert event.archived == false
    end

    test "is valid when only external_id is supplied (status flags nullable)" do
      changeset = Event.changeset(%Event{}, %{external_id: "evt-minimal"})

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :neg_risk)
      refute Map.has_key?(changeset.changes, :active)
      refute Map.has_key?(changeset.changes, :closed)
      refute Map.has_key?(changeset.changes, :archived)
    end

    test "ignores unknown/unpermitted fields" do
      changeset =
        Event.changeset(%Event{}, %{external_id: "evt-extra", not_a_field: "nope", id: 999})

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :not_a_field)
      refute Map.has_key?(changeset.changes, :id)
    end

    test "casts string-keyed attrs (jsonb round-trip shape)" do
      changeset =
        Event.changeset(%Event{}, %{
          "external_id" => "evt-string-keys",
          "neg_risk" => true,
          "active" => false
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :external_id) == "evt-string-keys"
      assert Ecto.Changeset.get_change(changeset, :neg_risk) == true
      assert Ecto.Changeset.get_change(changeset, :active) == false
    end

    test "is invalid when external_id is missing" do
      changeset = Event.changeset(%Event{}, %{active: true})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).external_id
    end

    test "is invalid when external_id is nil" do
      changeset = Event.changeset(%Event{}, %{external_id: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).external_id
    end

    test "enforces the unique constraint on external_id" do
      Fixtures.event_fixture(%{external_id: "dup"})

      assert {:error, changeset} =
               %Event{}
               |> Event.changeset(%{external_id: "dup"})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).external_id
    end
  end
end
