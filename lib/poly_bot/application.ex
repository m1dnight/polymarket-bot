defmodule PolyBot.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias PolyBot.EventFetch
  alias PolyBot.MarketData
  alias PolyBot.Parameters
  alias PolyBot.WebSocketManager

  @impl true
  def start(_type, _args) do
    PolyBot.EventHandler.attach()
    # counters must exist before any child process increments them.
    PolyBot.Stats.init()

    children = [
      PolyBotWeb.Telemetry,
      PolyBot.Repo,
      {DNSCluster, query: Application.get_env(:poly_bot, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PolyBot.PubSub},
      # Owns the top-of-book ETS table and sweeps it for staleness. Must start
      # before the websocket children below, whose handlers write to it.
      {MarketData.Worker, Parameters.market_data_worker_opts()},
      # Periodically fetches Polymarket events into the database.
      {EventFetch.Worker, Parameters.event_fetch_worker_opts()},
      # Supervises the Polymarket websocket connections opened via
      # `PolyBot.WebSocketManager`. `start_link/0` is arity 0, so it needs an
      # explicit child spec rather than the default `{module, arg}` form.
      Polymarket.Supervisor,
      # Routes asset subscriptions across the websocket connections; opens them
      # via the SocketSupervisor above, so it must start after it.
      {WebSocketManager.Worker, Parameters.websocket_worker_opts()},
      # Start to serve requests, typically the last entry
      PolyBotWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PolyBot.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PolyBotWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
