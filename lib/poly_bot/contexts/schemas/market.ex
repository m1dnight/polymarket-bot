defmodule PolyBot.Contexts.Schemas.Market do
  @moduledoc """
  A Polymarket market belonging to an `Event`, keyed by `external_id`.

  Fields:

    * `id` — an auto-generated surrogate primary key.
    * `external_id` — Polymarket's native market id. Unique (enforced by a
      unique index).
    * `event_id` — the surrogate `id` of the owning `Event` (a plain foreign
      key).
    * `enable_order_book`, `active`, `closed`, `accepting_orders`,
      `uma_resolution_status` — lifecycle/trading flags as reported by
      Polymarket. All nullable, since a payload may not supply every flag.
    * `clob_token_ids` — the CLOB token ids for the market (e.g. the yes/no
      token pair), as a list of strings. Nullable.
    * `outcomes` — the market's outcome labels (e.g. `["Yes", "No"]`).
      Positionally aligned with `clob_token_ids`: outcome `i` is traded via token
      `i`. Nullable.
  """

  use TypedEctoSchema

  import Ecto.Changeset

  alias PolyBot.Contexts.Schemas.Event

  typed_schema "markets" do
    field :external_id, :string
    field :enable_order_book, :boolean
    field :active, :boolean
    field :closed, :boolean
    field :accepting_orders, :boolean
    field :uma_resolution_status, :string
    field :clob_token_ids, {:array, :string}
    field :outcomes, {:array, :string}

    belongs_to :event, Event

    timestamps(type: :utc_datetime)
  end

  @doc "Build a changeset for a market from `attrs`."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(market, attrs) do
    market
    |> cast(attrs, [
      :external_id,
      :event_id,
      :enable_order_book,
      :active,
      :closed,
      :accepting_orders,
      :uma_resolution_status,
      :clob_token_ids,
      :outcomes
    ])
    |> validate_required([:external_id, :event_id])
    |> assoc_constraint(:event)
    |> unique_constraint(:external_id)
  end
end
