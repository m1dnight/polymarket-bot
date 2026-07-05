import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/poly_bot start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :poly_bot, PolyBotWeb.Endpoint, server: true
end

config :poly_bot, PolyBotWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Env-var-driven configuration. Skipped in the test environment, which hardcodes
# these values in config/test.exs so tests never read the environment.
if config_env() != :test do
  import PolyBot.Config, only: [optional: 3]

  # Backs the config-driven values in `PolyBot.Parameters` used by the event
  # fetch worker. Surfaced as env vars so they can be tuned per deployment
  # without a rebuild.
  config :poly_bot, :event_fetcher,
    # smallest acceptable event liquidity when fetching events from Gamma
    minimum_liquidity: optional("EVENT_FETCHER_MINIMUM_LIQUIDITY", :integer, 10_000),
    # delay between fetches, in ms; 0 (or less) disables polling entirely
    interval_ms: optional("EVENT_FETCHER_INTERVAL_MS", :integer, :timer.minutes(5))

  config :poly_bot, :websocket_manager,
    # subscription capacity of a single websocket connection; the worker opens
    # a new connection once all existing ones are full
    max_assets_per_connection: optional("WEBSOCKET_MAX_ASSETS_PER_CONNECTION", :integer, 100),
    # delay of the first backed-off retry when restoring a dead connection
    # fails, in ms; doubles per consecutive failure
    retry_base_ms: optional("WEBSOCKET_RETRY_BASE_MS", :integer, 1_000),
    # ceiling for the restore retry delay, in ms
    retry_max_ms: optional("WEBSOCKET_RETRY_MAX_MS", :integer, 30_000),
    # when false, resyncs subscribe nothing instead of querying the database
    # for tradable markets; tests disable it to keep the singleton off the DB
    resync_from_db: optional("WEBSOCKET_RESYNC_FROM_DB", :boolean, true)

  config :poly_bot, :market_data,
    # interval between top-of-book staleness sweeps (a full-table scan), in
    # ms; 0 (or less) disables sweeping entirely
    sweep_interval_ms: optional("MARKET_DATA_SWEEP_INTERVAL_MS", :integer, 5_000),
    # age above which a top-of-book row counts as stale in the sweep, in ms
    staleness_threshold_ms: optional("MARKET_DATA_STALENESS_THRESHOLD_MS", :integer, 30_000)

  config :poly_bot, :dashboard,
    # interval between dashboard stat refreshes, in ms
    refresh_ms: optional("DASHBOARD_REFRESH_MS", :integer, 5_000),
    # window for coalescing price-change activity into one row-blink push, in ms
    blink_ms: optional("DASHBOARD_BLINK_MS", :integer, 300)
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :poly_bot, PolyBot.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :poly_bot, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :poly_bot, PolyBotWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :poly_bot, PolyBotWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :poly_bot, PolyBotWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :poly_bot, PolyBot.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
