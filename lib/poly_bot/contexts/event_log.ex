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

  # Stored form of the connect/disconnect telemetry events (see
  # `PolyBot.EventHandler`, which logs `inspect(event_name)`).
  @connect_event "[:poly_bot, :websocket, :connect]"
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
  Websocket counts and average lifespans since the application booted, split
  into sockets that already logged a disconnect (lifespan: connect to
  disconnect line) and sockets still connected (a connect line with no
  matching disconnect, measured up to now). Lifespans are whole seconds;
  an average is `nil` when no socket falls in that class.

  Only connect lines inserted after boot are counted, so connects orphaned by
  a previous run are never reported as still connected.

  ## Examples

      iex> websocket_stats()
      %{
        connected: %{count: 3, avg_lifespan: 512},
        disconnected: %{count: 10, avg_lifespan: 3600}
      }

  """
  @spec websocket_stats() :: %{
          connected: %{count: non_neg_integer(), avg_lifespan: non_neg_integer() | nil},
          disconnected: %{count: non_neg_integer(), avg_lifespan: non_neg_integer() | nil}
        }
  def websocket_stats do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    booted_at = DateTime.add(DateTime.utc_now(), -uptime_ms, :millisecond)

    query =
      from c in EventLine,
        where: c.event == ^@connect_event,
        where: c.inserted_at >= ^booted_at,
        left_join: d in EventLine,
        on: d.event == ^@disconnect_event and d.metadata["id"] == c.metadata["id"],
        select: %{
          connected: %{
            count: filter(count(c.id), is_nil(d.id)),
            avg_lifespan:
              type(
                filter(
                  avg(fragment("EXTRACT(EPOCH FROM (now() - ?))", c.inserted_at)),
                  is_nil(d.id)
                ),
                :integer
              )
          },
          disconnected: %{
            count: filter(count(c.id), not is_nil(d.id)),
            avg_lifespan:
              type(
                filter(
                  avg(fragment("EXTRACT(EPOCH FROM (? - ?))", d.inserted_at, c.inserted_at)),
                  not is_nil(d.id)
                ),
                :integer
              )
          }
        }

    Repo.one(query)
  end
end
