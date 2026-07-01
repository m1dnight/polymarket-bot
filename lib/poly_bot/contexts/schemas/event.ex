defmodule PolyBot.Contexts.Schemas.Event do
  @moduledoc """
  A Polymarket event the bot records, keyed by `external_id`.

  Fields:

    * `id` — an auto-generated surrogate primary key.
    * `external_id` — Polymarket's native event id. Unique (enforced by a unique
      index); the bot only tracks Polymarket, so no venue column is needed.
    * `neg_risk`, `active`, `closed`, `archived` — lifecycle/status flags as
      reported by Polymarket. All nullable, since a payload may not supply every
      flag.

  The raw venue payload lives in a separate `event_payloads` table
  (`has_one :payload`) so it is never loaded by normal event queries; preload it
  only when you need it (see `PolyBot.Contexts.Events.get_payload/1`).
  """

  use TypedEctoSchema

  import Ecto.Changeset

  alias PolyBot.Contexts.Schemas.EventPayload
  alias PolyBot.Contexts.Schemas.Market

  typed_schema "events" do
    field :external_id, :string
    field :neg_risk, :boolean
    field :active, :boolean
    field :closed, :boolean
    field :archived, :boolean

    has_many :markets, Market, foreign_key: :event_id
    has_one :payload, EventPayload

    timestamps(type: :utc_datetime)
  end

  @doc "Build a changeset for an event from `attrs`."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:external_id, :neg_risk, :active, :closed, :archived])
    |> validate_required([:external_id])
    |> unique_constraint(:external_id)
  end
end
