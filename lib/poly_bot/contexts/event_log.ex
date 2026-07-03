defmodule PolyBot.Contexts.EventLog do
  @moduledoc """
  The application event log: persistence for
  `PolyBot.Contexts.Schemas.EventLine` rows — the events (websocket connects,
  disconnects, ...) the bot logs for later inspection.

  The table is append-only and indexed on `(event, inserted_at)`, so queries
  should stay in the "events of type X in window Y" shape that
  `list_event_lines/2` implements.
  """

  import Ecto.Query, only: [from: 2]

  alias PolyBot.Contexts.Schemas.EventLine
  alias PolyBot.Repo

  # Stored form of the disconnect telemetry event (see `PolyBot.EventHandler`,
  # which logs `inspect([:poly_bot, :websocket, :disconnect])`).
  @disconnect_event "[:poly_bot, :websocket, :disconnect]"

  @doc """
  Log an event: append a line with the given `event` name, `measurements`
  (the numbers you aggregate) and `metadata` (the tags you filter/group by).

  ## Examples

      iex> log_event("disconnect", %{duration_ms: 1200}, %{shard: 3})
      {:ok, %EventLine{}}

      iex> log_event(nil)
      {:error, %Ecto.Changeset{}}

  """
  @spec log_event(String.t(), map(), map()) ::
          {:ok, EventLine.t()} | {:error, Ecto.Changeset.t()}
  def log_event(event, measurements \\ %{}, metadata \\ %{}) do
    %EventLine{}
    |> EventLine.changeset(%{event: event, measurements: measurements, metadata: metadata})
    |> Repo.insert()
  end

  @doc """
  Return the lines of type `event` logged at or after `since`, newest first.
  Served by the `(event, inserted_at)` index.

  ## Examples

      iex> list_event_lines("disconnect", DateTime.add(DateTime.utc_now(), -3600))
      [%EventLine{event: "disconnect"}, ...]

  """
  @spec list_event_lines(String.t(), DateTime.t()) :: [EventLine.t()]
  def list_event_lines(event, %DateTime{} = since) do
    Repo.all(
      from l in EventLine,
        where: l.event == ^event and l.inserted_at >= ^since,
        order_by: [desc: l.inserted_at]
    )
  end

  @doc """
  Min, max and average websocket lifespan (minutes) across all logged
  disconnects. Each field is `nil` when there are no disconnect rows.

  ## Examples

      iex> websocket_lifespan_stats()
      %{min: 1.0, max: 180.0, avg: 42.5}

  """
  @spec websocket_lifespan_stats() :: %{
          min: float() | nil,
          max: float() | nil,
          avg: float() | nil
        }
  def websocket_lifespan_stats do
    Repo.one(
      from l in EventLine,
        where: l.event == @disconnect_event,
        select: %{
          min: min(fragment("(?->>'lifespan')::float", l.metadata)),
          max: max(fragment("(?->>'lifespan')::float", l.metadata)),
          avg: avg(fragment("(?->>'lifespan')::float", l.metadata))
        }
    )
  end
end
