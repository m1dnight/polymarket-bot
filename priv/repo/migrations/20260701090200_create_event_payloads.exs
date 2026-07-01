defmodule PolyBot.Repo.Migrations.CreateEventPayloads do
  use Ecto.Migration

  def change do
    create table(:event_payloads) do
      # The owning event. One payload per event; deleting the event drops it.
      add :event_id, references(:events, on_delete: :delete_all), null: false
      # The raw venue payload as jsonb. Kept out of the `events` table so normal
      # event queries never load it; fetch via `Repo.preload(:payload)`.
      add :raw, :map, null: false

      timestamps(type: :utc_datetime)
    end

    # One payload row per event (backs `has_one :payload` and the upsert).
    create unique_index(:event_payloads, [:event_id])
  end
end
