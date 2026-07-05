defmodule PolyBot.Contexts.Events do
  @moduledoc """
  Persistence for `PolyBot.Contexts.Schemas.Event` rows — the Polymarket events
  the bot records, keyed by `external_id`.

  The raw venue payload is stored separately (`put_payload/2` / `get_payload/1`,
  backed by `PolyBot.Contexts.Schemas.EventPayload`) so it never weighs on the
  queries below.
  """

  import Ecto.Query, only: [from: 2]

  alias PolyBot.Broadcast
  alias PolyBot.Contexts.Markets
  alias PolyBot.Contexts.Schemas.Event
  alias PolyBot.Contexts.Schemas.EventPayload
  alias PolyBot.Contexts.Schemas.Market
  alias PolyBot.Repo

  # On upsert, refresh every column with the latest values Polymarket reported,
  # except these three: `id` is the surrogate primary key (clobbering it would
  # break rows that reference the event and re-key it on every sync),
  # `external_id` is the identity/conflict key, and `inserted_at` must keep its
  # original first-seen time. Using `replace_all_except` means new columns are
  # picked up automatically instead of silently going stale.
  @conflict_preserve [:id, :external_id, :inserted_at]

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
  Return the number of stored events, as a single `count(*)` query.

  ## Examples

      iex> count_events()
      42

  """
  @spec count_events() :: non_neg_integer()
  def count_events do
    Repo.aggregate(Event, :count)
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
      on_conflict: {:replace_all_except, @conflict_preserve},
      conflict_target: :external_id
    )
  end

  @doc """
  Upsert a list of event `attrs` maps in a single query — the batch counterpart
  to `upsert_event/1`. Existing events (matched on `external_id`) have their
  status flags refreshed; new ones are inserted.

  Returns `{count, rows}`, where `rows` are the upserted events as fully-loaded
  structs (both for freshly inserted and for conflict-updated rows), so callers
  can link owned rows — e.g. an event's markets — to each event without a
  second query. An empty list returns `{0, []}`.

  Duplicate `external_id`s within `attrs_list` are collapsed to their first
  occurrence, since Postgres cannot update the same row twice in one upsert.

  This is the plain write: no classification, no broadcasts. Callers that need
  to know which events are new — or want them announced — should go through
  `store_events/1`.

  ## Examples

      iex> upsert_events([%{external_id: "1", active: true}, %{external_id: "2", closed: true}])
      {2, [%Event{id: 1, external_id: "1"}, %Event{id: 2, external_id: "2"}]}

      iex> upsert_events([])
      {0, []}

  """
  @spec upsert_events([map()]) :: {non_neg_integer(), [Event.t()]}
  def upsert_events([]), do: {0, []}

  def upsert_events(attrs_list) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      attrs_list
      |> Enum.uniq_by(& &1.external_id)
      |> Enum.map(&Map.merge(&1, %{inserted_at: now, updated_at: now}))

    Repo.insert_all(Event, rows,
      on_conflict: {:replace_all_except, @conflict_preserve},
      conflict_target: :external_id,
      returning: true
    )
  end

  @doc """
  Upsert `attrs_list` (via `upsert_events/1`) and split the result into
  `%{new: events, updated: events}` — the events inserted for the first time
  vs the conflict-updates of events already stored.

  The pre-select of already-known `external_id`s and the upsert run in a
  single transaction, so the classification is consistent with what the upsert
  saw. Once the transaction commits, the new events (if any) are broadcast as
  `{:events_new, events}` on the `"events:new"` PubSub topic — updates stay
  silent, so subscribers only hear about events Polymarket newly listed.

  ## Examples

      iex> store_events([%{external_id: "1", active: true}])
      %{new: [%Event{external_id: "1"}], updated: []}

      iex> store_events([%{external_id: "1", closed: true}])
      %{new: [], updated: [%Event{external_id: "1"}]}

  """
  @spec store_events([map()]) :: %{new: [Event.t()], updated: [Event.t()]}
  def store_events([]), do: %{new: [], updated: []}

  def store_events(attrs_list) do
    external_ids = attrs_list |> Enum.map(& &1.external_id) |> Enum.uniq()

    {:ok, {new_events, updated}} =
      Repo.transaction(fn ->
        known =
          MapSet.new(
            Repo.all(
              from e in Event, where: e.external_id in ^external_ids, select: e.external_id
            )
          )

        {_count, stored} = upsert_events(attrs_list)

        Enum.split_with(stored, &(not MapSet.member?(known, &1.external_id)))
      end)

    if new_events != [] do
      Broadcast.broadcast_events_new(new_events)
    end

    %{new: new_events, updated: updated}
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

  @doc """
  Reconcile the markets owned by the events in `event_ids` against
  `market_attrs`.

  Upserts every market in `market_attrs` (each carrying its owning `event_id`,
  via `PolyBot.Contexts.Markets.upsert_markets/1`) and then deletes any market
  belonging to one of `event_ids` whose `external_id` is absent from
  `market_attrs` — i.e. the markets Polymarket no longer reports for those
  events.

  `event_ids` scopes the delete: markets owned by events outside the set are
  never touched, and an event whose markets have all vanished is still pruned
  (it simply contributes no `market_attrs`, but stays in `event_ids`). Runs as
  two batched queries regardless of how many events or markets are involved.
  Returns `{upserted, deleted}` counts.

  ## Examples

      iex> replace_markets([1, 2], [%{external_id: "0xabc", event_id: 1, active: true}])
      {1, 3}

      iex> replace_markets([], [])
      {0, 0}

  """
  @spec replace_markets([integer()], [map()]) :: {non_neg_integer(), non_neg_integer()}
  def replace_markets(event_ids, market_attrs) do
    {upserted, _} = Markets.upsert_markets(market_attrs)

    fresh_external_ids = Enum.map(market_attrs, & &1.external_id)

    {deleted, _} =
      Repo.delete_all(
        from m in Market,
          where: m.event_id in ^event_ids and m.external_id not in ^fresh_external_ids
      )

    {upserted, deleted}
  end
end
