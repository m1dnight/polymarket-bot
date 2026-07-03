defmodule PolyBot.Contexts.Schemas.EventLine do
  @moduledoc """
  A single line in the application event log (e.g. websocket `"connect"` /
  `"disconnect"`), mirroring the telemetry shape: `measurements` holds the
  numbers you aggregate, `metadata` the tags you filter/group by.

  Rows are append-only — there is no `updated_at` and no update path. Both maps
  are stored as jsonb, so values come back as **string-keyed maps** on read.
  """

  use TypedEctoSchema

  import Ecto.Changeset

  typed_schema "event_lines" do
    field :event, :string
    field :measurements, :map, default: %{}
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Build a changeset for an event line from `attrs`.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(event_line, attrs) do
    event_line
    |> cast(attrs, [:event, :measurements, :metadata])
    |> validate_required([:event])
  end
end
