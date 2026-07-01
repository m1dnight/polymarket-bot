defmodule PolyBot.Contexts.Markets do
  @moduledoc """
  Persistence for `PolyBot.Contexts.Schemas.Market` rows — the Polymarket
  markets owned by an `Event`, keyed by `external_id`.
  """

  import Ecto.Query, only: [from: 2]

  alias PolyBot.Contexts.Schemas.Market
  alias PolyBot.Repo

  # On upsert, refresh every column with the latest values Polymarket reported,
  # except these three: `id` is the surrogate primary key (clobbering it would
  # break rows that reference the market and re-key it on every sync),
  # `external_id` is the identity/conflict key, and `inserted_at` must keep its
  # original first-seen time. Using `replace_all_except` means new columns are
  # picked up automatically instead of silently going stale.
  @conflict_preserve [:id, :external_id, :inserted_at]

  @doc """
  Return every stored market, oldest first.

  ## Examples

      iex> list_markets()
      [%Market{}, ...]

  """
  @spec list_markets() :: [Market.t()]
  def list_markets do
    Repo.all(from m in Market, order_by: [asc: m.id])
  end

  @doc """
  Fetch the market with `id`, raising `Ecto.NoResultsError` if absent.

  ## Examples

      iex> get_market!(42)
      %Market{id: 42}

      iex> get_market!(-1)
      ** (Ecto.NoResultsError)

  """
  @spec get_market!(integer()) :: Market.t()
  def get_market!(id), do: Repo.get!(Market, id)

  @doc """
  Insert a market from `attrs`.

  ## Examples

      iex> create_market(%{external_id: "0xabc", event_id: 42, active: true})
      {:ok, %Market{}}

      iex> create_market(%{active: true})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_market(map()) :: {:ok, Market.t()} | {:error, Ecto.Changeset.t()}
  def create_market(attrs \\ %{}) do
    %Market{}
    |> Market.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Insert `attrs` as a new market, or update the existing market with the same
  `external_id` — its owning event and lifecycle/trading flags are refreshed.
  Lets the periodic fetcher re-see a market without tripping the `external_id`
  unique constraint.

  ## Examples

      iex> upsert_market(%{external_id: "0xabc", event_id: 42, active: true})
      {:ok, %Market{}}

  """
  @spec upsert_market(map()) :: {:ok, Market.t()} | {:error, Ecto.Changeset.t()}
  def upsert_market(attrs) do
    %Market{}
    |> Market.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, @conflict_preserve},
      conflict_target: :external_id
    )
  end

  @doc """
  Upsert a list of market `attrs` maps in a single query — the batch counterpart
  to `upsert_market/1`. Existing markets (matched on `external_id`) have their
  owning event and lifecycle/trading flags refreshed; new ones are inserted.
  Returns `{count, nil}`.

  Duplicate `external_id`s within `attrs_list` are collapsed to their first
  occurrence, since Postgres cannot update the same row twice in one upsert.

  ## Examples

      iex> upsert_markets([%{external_id: "0xabc", event_id: 42, active: true}])
      {1, nil}

      iex> upsert_markets([])
      {0, nil}

  """
  @spec upsert_markets([map()]) :: {non_neg_integer(), nil}
  def upsert_markets(attrs_list) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      attrs_list
      |> Enum.uniq_by(& &1.external_id)
      |> Enum.map(&Map.merge(&1, %{inserted_at: now, updated_at: now}))

    Repo.insert_all(Market, rows,
      on_conflict: {:replace_all_except, @conflict_preserve},
      conflict_target: :external_id
    )
  end

  @doc """
  Update `market` with `attrs`.

  ## Examples

      iex> update_market(market, %{accepting_orders: false})
      {:ok, %Market{}}

      iex> update_market(market, %{external_id: nil})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_market(Market.t(), map()) :: {:ok, Market.t()} | {:error, Ecto.Changeset.t()}
  def update_market(%Market{} = market, attrs) do
    market
    |> Market.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete `market`.

  ## Examples

      iex> delete_market(market)
      {:ok, %Market{}}

  """
  @spec delete_market(Market.t()) :: {:ok, Market.t()} | {:error, Ecto.Changeset.t()}
  def delete_market(%Market{} = market) do
    Repo.delete(market)
  end

  @doc """
  Build a changeset for `market` (defaults to a blank one) from `attrs`.

  ## Examples

      iex> change_market(market, %{closed: true})
      %Ecto.Changeset{data: %Market{}}

  """
  @spec change_market(Market.t(), map()) :: Ecto.Changeset.t()
  def change_market(%Market{} = market \\ %Market{}, attrs \\ %{}) do
    Market.changeset(market, attrs)
  end
end
