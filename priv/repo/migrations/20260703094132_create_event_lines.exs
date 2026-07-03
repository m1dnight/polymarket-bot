defmodule PolyBot.Repo.Migrations.CreateEventLines do
  use Ecto.Migration

  def change do
    create table(:event_lines) do
      # The event name, e.g. "connect", "disconnect".
      add :event, :string, null: false
      # The numbers you aggregate.
      add :measurements, :map, null: false, default: %{}
      # The tags you filter/group by.
      add :metadata, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    # The workhorse index: almost every query is "events of type X in window Y".
    create index(:event_lines, [:event, :inserted_at])
  end
end
