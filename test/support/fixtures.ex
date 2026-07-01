defmodule PolyBot.Fixtures do
  @moduledoc """
  Test fixtures for the persisted domain schemas. Each helper inserts a row with
  sensible defaults, merging in any `attrs` overrides.
  """

  alias PolyBot.Contexts.Schemas.Event
  alias PolyBot.Contexts.Schemas.Market
  alias PolyBot.Repo

  @doc """
  Insert an `Event`. A unique `external_id` is generated unless overridden.
  """
  @spec event_fixture(map()) :: Event.t()
  def event_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        external_id: "evt-#{System.unique_integer([:positive])}",
        neg_risk: false,
        active: true,
        closed: false,
        archived: false
      })

    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Insert a `Market`. Creates an owning `Event` unless `:event_id` is supplied.
  """
  @spec market_fixture(map()) :: Market.t()
  def market_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    event_id = Map.get_lazy(attrs, :event_id, fn -> event_fixture().id end)

    attrs =
      attrs
      |> Map.put(:event_id, event_id)
      |> Map.put_new(:external_id, "mkt-#{System.unique_integer([:positive])}")
      |> Map.put_new(:active, true)
      |> Map.put_new(:closed, false)

    %Market{}
    |> Market.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Build a `Polymarket.Schemas.Event` struct (the Gamma API shape) for feeding
  `PolyBot.Support.FakeGamma`. Only the fields `PolyBot.EventFetch` reads are
  set. Pass `markets: [gamma_market(...)]` to nest markets under the event.
  """
  @spec gamma_event(keyword()) :: Polymarket.Schemas.Event.t()
  def gamma_event(attrs \\ []) do
    defaults = [
      id: "gamma-#{System.unique_integer([:positive])}",
      enable_neg_risk: false,
      active: true,
      closed: false,
      archived: false
    ]

    struct(Polymarket.Schemas.Event, Keyword.merge(defaults, attrs))
  end

  @doc """
  Build a `Polymarket.Schemas.Market` struct (the Gamma API shape) for nesting
  under `gamma_event/1`. Only the fields `PolyBot.EventFetch` reads are set.
  """
  @spec gamma_market(keyword()) :: Polymarket.Schemas.Market.t()
  def gamma_market(attrs \\ []) do
    defaults = [
      id: "gamma-mkt-#{System.unique_integer([:positive])}",
      enable_order_book: true,
      active: true,
      closed: false,
      accepting_orders: true,
      uma_resolution_status: nil,
      clob_token_ids: ["tok-yes", "tok-no"],
      outcomes: ["Yes", "No"]
    ]

    struct(Polymarket.Schemas.Market, Keyword.merge(defaults, attrs))
  end
end
