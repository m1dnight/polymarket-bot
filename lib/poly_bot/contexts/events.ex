defmodule PolyBot.Contexts.Events do
  @moduledoc """
  Persistence for `PolyBot.Contexts.Schemas.Event` rows — the Polymarket events
  the bot records, keyed by `external_id`.

  The raw venue payload is stored separately (`put_payload/2` / `get_payload/1`,
  backed by `PolyBot.Contexts.Schemas.EventPayload`) so it never weighs on the
  queries below.
  """

  import Ecto.Query, only: [from: 2]

  alias PolyBot.Contexts.Schemas.Event
  alias PolyBot.Contexts.Schemas.EventPayload
  alias PolyBot.Repo

  @doc """
  Return every stored event, newest first.

  ## Examples

      iex> list_events()
      [%Event{}, ...]

  """
  @spec list_events() :: [Event.t()]
  def list_events do
    Repo.all(from e in Event, order_by: [desc: e.inserted_at, desc: e.id])
  end

  @doc """
  Fetch the event with `id`, raising `Ecto.NoResultsError` if absent.

  ## Examples

      iex> get_event!(42)
      %Event{id: 42}

      iex> get_event!(-1)
      ** (Ecto.NoResultsError)

  """
  @spec get_event!(integer()) :: Event.t()
  def get_event!(id), do: Repo.get!(Event, id)

  @doc """
  Insert an event from `attrs`.

  ## Examples

      iex> create_event(%{external_id: "12345", active: true})
      {:ok, %Event{}}

      iex> create_event(%{active: true})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_event(map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def create_event(attrs \\ %{}) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Insert `attrs` as a new event, or update the existing event with the same
  `external_id` — its status flags are refreshed. Lets the periodic fetcher
  re-see an event without tripping the `external_id` unique constraint.

  ## Examples

      iex> upsert_event(%{external_id: "12345", active: true, closed: false})
      {:ok, %Event{}}

  """
  @spec upsert_event(map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def upsert_event(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:neg_risk, :active, :closed, :archived, :updated_at]},
      conflict_target: :external_id
    )
  end

  @doc """
  Upsert a list of event `attrs` maps in a single query — the batch counterpart
  to `upsert_event/1`. Existing events (matched on `external_id`) have their
  status flags refreshed; new ones are inserted. Returns `{count, nil}`.

  Duplicate `external_id`s within `attrs_list` are collapsed to their first
  occurrence, since Postgres cannot update the same row twice in one upsert.

  ## Examples

      iex> upsert_events([%{external_id: "1", active: true}, %{external_id: "2", closed: true}])
      {2, nil}

      iex> upsert_events([])
      {0, nil}

  """
  @spec upsert_events([map()]) :: {non_neg_integer(), nil}
  def upsert_events(attrs_list) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      attrs_list
      |> Enum.uniq_by(& &1.external_id)
      |> Enum.map(&Map.merge(&1, %{inserted_at: now, updated_at: now}))

    Repo.insert_all(Event, rows,
      on_conflict: {:replace, [:neg_risk, :active, :closed, :archived, :updated_at]},
      conflict_target: :external_id
    )
  end

  @doc """
  Update `event` with `attrs`.

  ## Examples

      iex> update_event(event, %{closed: true})
      {:ok, %Event{}}

      iex> update_event(event, %{external_id: nil})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_event(Event.t(), map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def update_event(%Event{} = event, attrs) do
    event
    |> Event.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete `event`. Its stored payload cascades away with it.

  ## Examples

      iex> delete_event(event)
      {:ok, %Event{}}

  """
  @spec delete_event(Event.t()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def delete_event(%Event{} = event) do
    Repo.delete(event)
  end

  @doc """
  Build a changeset for `event` (defaults to a blank one) from `attrs`.

  ## Examples

      iex> change_event(event, %{active: false})
      %Ecto.Changeset{data: %Event{}}

  """
  @spec change_event(Event.t(), map()) :: Ecto.Changeset.t()
  def change_event(%Event{} = event \\ %Event{}, attrs \\ %{}) do
    Event.changeset(event, attrs)
  end

  @doc """
  Store (or replace) the raw venue payload for `event`. It lives in the separate
  `event_payloads` table, so it never loads on the list/get queries above; read
  it back with `get_payload/1` or `Repo.preload(event, :payload)`.

  ## Examples

      iex> put_payload(event, %{"title" => "Will it rain?", "markets" => [...]})
      {:ok, %EventPayload{}}

  """
  @spec put_payload(Event.t(), map()) :: {:ok, EventPayload.t()} | {:error, Ecto.Changeset.t()}
  def put_payload(%Event{} = event, raw) do
    event
    |> Ecto.build_assoc(:payload)
    |> EventPayload.changeset(%{raw: raw})
    |> Repo.insert(on_conflict: {:replace, [:raw, :updated_at]}, conflict_target: :event_id)
  end

  @doc """
  Return the raw venue payload stored for `event`, or `nil` if none.

  ## Examples

      iex> put_payload(event, %{"title" => "Will it rain?"})
      iex> get_payload(event)
      %{"title" => "Will it rain?"}

      iex> get_payload(event_without_payload)
      nil

  """
  @spec get_payload(Event.t()) :: map() | nil
  def get_payload(%Event{id: id}) do
    case Repo.get_by(EventPayload, event_id: id) do
      nil -> nil
      payload -> payload.raw
    end
  end
end
