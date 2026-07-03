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
end
