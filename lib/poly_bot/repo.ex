defmodule PolyBot.Repo do
  use Ecto.Repo,
    otp_app: :poly_bot,
    adapter: Ecto.Adapters.Postgres
end
