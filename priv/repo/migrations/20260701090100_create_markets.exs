defmodule PolyBot.Repo.Migrations.CreateMarkets do
  use Ecto.Migration

  def change do
    create table(:markets) do
      # Polymarket's native market id. Unique (see the index below); the
      # surrogate bigint primary key is added automatically.
      add :external_id, :string, null: false
      # The owning event's surrogate primary key — a plain single-column foreign
      # key. Markets cascade when their event is deleted.
      add :event_id, references(:events, on_delete: :delete_all), null: false

      # Lifecycle/trading flags as reported by Polymarket. Nullable: a payload
      # may not supply every flag.
      add :enable_order_book, :boolean, null: true
      add :active, :boolean, null: true
      add :closed, :boolean, null: true
      add :accepting_orders, :boolean, null: true
      add :uma_resolution_status, :string, null: true

      # The CLOB token ids for this market (e.g. the yes/no token pair). A small,
      # always-loaded list, so a Postgres text array rather than a join table.
      # Nullable.
      add :clob_token_ids, {:array, :string}, null: true
      # The market's outcome labels (e.g. ["Yes", "No"]). Positionally aligned
      # with `clob_token_ids` — outcome i is traded via token i — so kept as an
      # ordered Postgres array. Nullable.
      add :outcomes, {:array, :string}, null: true

      timestamps(type: :utc_datetime)
    end

    # A market is uniquely identified by its Polymarket id.
    create unique_index(:markets, [:external_id])
    # Keep lookups by owning event fast.
    create index(:markets, [:event_id])
  end
end
