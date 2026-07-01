defmodule PolyBot.Contexts.Markets do
  @moduledoc """
  Persistence for `PolyBot.Contexts.Schemas.Market` rows — the Polymarket
  markets owned by an `Event`, keyed by `external_id`.
  """

  import Ecto.Query, only: [from: 2]

  alias PolyBot.Contexts.Schemas.Market
  alias PolyBot.Repo

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
