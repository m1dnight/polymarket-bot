defmodule PolyBot.Contexts.Schemas.EventPayload do
  @moduledoc """
  The raw venue payload for an `Event`, kept in its own `event_payloads` table so
  the hot `events` queries never load the (potentially large) jsonb. Fetch it
  explicitly with `PolyBot.Contexts.Events.get_payload/1` or
  `Repo.preload(event, :payload)` when you actually need the original data.

  Structs are JSON-encoded on write and come back as **string-keyed maps** on
  read, so don't rely on the struct type or atom keys surviving a round trip.
  """

  use TypedEctoSchema

  import Ecto.Changeset

  alias PolyBot.Contexts.Schemas.Event

  typed_schema "event_payloads" do
    field :raw, :map

    belongs_to :event, Event

    timestamps(type: :utc_datetime)
  end

  @doc """
  Build a changeset for an event payload from `attrs`. The owning `event_id` is
  set on the struct (see `Ecto.build_assoc/3`), not cast from `attrs`.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(payload, attrs) do
    payload
    |> cast(attrs, [:raw])
    |> validate_required([:raw])
    |> assoc_constraint(:event)
    |> unique_constraint(:event_id)
  end
end
