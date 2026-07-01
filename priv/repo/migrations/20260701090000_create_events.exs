defmodule PolyBot.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events) do
      # Polymarket's native event id. Unique (see the index below); the
      # surrogate bigint primary key is added automatically.
      add :external_id, :string, null: false

      # Lifecycle/status flags as reported by Polymarket. Nullable: a payload
      # may not supply every flag.
      add :neg_risk, :boolean, null: true
      add :active, :boolean, null: true
      add :closed, :boolean, null: true
      add :archived, :boolean, null: true

      timestamps(type: :utc_datetime)
    end

    # An event is uniquely identified by its Polymarket id.
    create unique_index(:events, [:external_id])
  end
end
