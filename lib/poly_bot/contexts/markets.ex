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
  Return the number of stored markets, as a single `count(*)` query.

  ## Examples

      iex> count_markets()
      42

  """
  @spec count_markets() :: non_neg_integer()
  def count_markets do
    Repo.aggregate(Market, :count)
  end

  @doc """
  Return the total number of CLOB asset ids across all stored markets, as a
  single aggregate query (summed `cardinality(clob_token_ids)`; markets
  without token ids contribute nothing).

  ## Examples

      iex> count_assets()
      84

  """
  @spec count_assets() :: non_neg_integer()
  def count_assets do
    Repo.one(
      from m in Market, select: coalesce(sum(fragment("cardinality(?)", m.clob_token_ids)), 0)
    )
  end

  @doc """
  Map each CLOB asset id to its owning event's surrogate id, across all stored
  markets. One query copying only the two needed columns; markets without
  `clob_token_ids` contribute nothing.

  ## Examples

      iex> asset_event_map()
      %{"71321045679" => 1, "89561230011" => 1, "12340009999" => 2}

  """
  @spec asset_event_map() :: %{String.t() => integer()}
  def asset_event_map do
    Repo.all(
      from m in Market,
        where: not is_nil(m.clob_token_ids),
        select: {m.clob_token_ids, m.event_id}
    )
    |> Enum.flat_map(fn {tokens, event_id} -> Enum.map(tokens, &{&1, event_id}) end)
    |> Map.new()
  end

  @doc """
  Return the CLOB asset ids of every tradable market — active, not closed,
  accepting orders, order book enabled — flattened into one list, as a single
  query. Markets missing any of those flags (or without token ids) are
  excluded. Used to seed the websocket subscriptions on startup.

  ## Examples

      iex> list_subscribable_asset_ids()
      ["71321045679252212594626385532706912345", ...]

  """
  @spec list_subscribable_asset_ids() :: [String.t()]
  def list_subscribable_asset_ids do
    from(m in Market,
      where:
        m.active and not m.closed and m.accepting_orders and m.enable_order_book and
          not is_nil(m.clob_token_ids),
      select: m.clob_token_ids
    )
    |> Repo.all()
    |> List.flatten()
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
