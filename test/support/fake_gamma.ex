defmodule PolyBot.Support.FakeGamma do
  @moduledoc """
  Test double for `Polymarket.Gamma`, injected via the `:gamma_client` app env
  (see `PolyBot.EventFetch`). Configure the response per test with `set/1`:

      PolyBot.Support.FakeGamma.set([%Polymarket.Schemas.Event{id: "1"}])
      PolyBot.Support.FakeGamma.set(fn opts -> send(pid, {:opts, opts}); events end)

  A function responder receives the `opts` passed to `stream_events/1`, so tests
  can both assert on the forwarded options and simulate failures (by raising).
  """

  @key :fake_gamma_responder

  @doc "Install the response used by the next `stream_events/1` call(s)."
  @spec set([struct()] | (keyword() -> Enumerable.t())) :: :ok
  def set(responder), do: Application.put_env(:poly_bot, @key, responder)

  @doc "Mimics `Polymarket.Gamma.stream_events/1` using the responder from `set/1`."
  @spec stream_events(keyword()) :: Enumerable.t()
  def stream_events(opts \\ []) do
    case Application.get_env(:poly_bot, @key) do
      fun when is_function(fun, 1) -> fun.(opts)
      list when is_list(list) -> list
      nil -> []
    end
  end
end
