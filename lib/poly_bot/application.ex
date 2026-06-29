defmodule PolyBot.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PolyBotWeb.Telemetry,
      PolyBot.Repo,
      {DNSCluster, query: Application.get_env(:poly_bot, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PolyBot.PubSub},
      # Start a worker by calling: PolyBot.Worker.start_link(arg)
      # {PolyBot.Worker, arg},
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
