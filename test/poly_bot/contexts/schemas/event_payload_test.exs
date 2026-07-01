defmodule PolyBot.Contexts.Schemas.EventPayloadTest do
  use PolyBot.DataCase, async: true

  alias PolyBot.Contexts.Schemas.EventPayload
  alias PolyBot.Fixtures

  describe "changeset/2" do
    test "is invalid when :raw is missing" do
      cs = EventPayload.changeset(%EventPayload{}, %{})

      refute cs.valid?
      assert "can't be blank" in errors_on(cs).raw
    end

    test "is invalid when :raw is explicitly nil" do
      cs = EventPayload.changeset(%EventPayload{}, %{raw: nil})

      refute cs.valid?
      assert "can't be blank" in errors_on(cs).raw
    end

    test "casts :raw and produces a valid changeset" do
      cs =
        Fixtures.event_fixture()
        |> Ecto.build_assoc(:payload)
        |> EventPayload.changeset(%{raw: %{"k" => "v"}})

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :raw) == %{"k" => "v"}
    end

    test "inserts a payload for an event" do
      event = Fixtures.event_fixture()

      assert {:ok, payload} =
               event
               |> Ecto.build_assoc(:payload)
               |> EventPayload.changeset(%{raw: %{"k" => "v"}})
               |> Repo.insert()

      assert payload.event_id == event.id
      assert payload.raw == %{"k" => "v"}
    end

    test "event_id is taken from the struct (build_assoc), not cast from attrs" do
      event = Fixtures.event_fixture()
      other_event = Fixtures.event_fixture()

      # Even if attrs try to smuggle a different event_id, it is ignored.
      assert {:ok, payload} =
               event
               |> Ecto.build_assoc(:payload)
               |> EventPayload.changeset(%{raw: %{"k" => "v"}, event_id: other_event.id})
               |> Repo.insert()

      assert payload.event_id == event.id
    end

    test "payload raw round-trips through jsonb as a string-keyed map" do
      event = Fixtures.event_fixture()

      {:ok, payload} =
        event
        |> Ecto.build_assoc(:payload)
        |> EventPayload.changeset(%{raw: %{outer: %{inner: 1}, list: [%{a: "b"}]}})
        |> Repo.insert()

      reloaded = Repo.get!(EventPayload, payload.id)

      assert reloaded.raw == %{"outer" => %{"inner" => 1}, "list" => [%{"a" => "b"}]}
    end

    test "enforces a unique payload per event" do
      event = Fixtures.event_fixture()

      assert {:ok, _first} =
               event
               |> Ecto.build_assoc(:payload)
               |> EventPayload.changeset(%{raw: %{"k" => "v"}})
               |> Repo.insert()

      assert {:error, cs} =
               event
               |> Ecto.build_assoc(:payload)
               |> EventPayload.changeset(%{raw: %{"k" => "other"}})
               |> Repo.insert()

      refute cs.valid?
      assert "has already been taken" in errors_on(cs).event_id
    end

    test "allows distinct payloads for distinct events" do
      event_one = Fixtures.event_fixture()
      event_two = Fixtures.event_fixture()

      assert {:ok, _} =
               event_one
               |> Ecto.build_assoc(:payload)
               |> EventPayload.changeset(%{raw: %{"k" => "v"}})
               |> Repo.insert()

      assert {:ok, _} =
               event_two
               |> Ecto.build_assoc(:payload)
               |> EventPayload.changeset(%{raw: %{"k" => "v"}})
               |> Repo.insert()
    end
  end
end
