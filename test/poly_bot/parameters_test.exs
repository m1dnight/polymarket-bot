defmodule PolyBot.ParametersTest do
  # async: false because we mutate the :event_fetcher application env.
  use ExUnit.Case, async: false

  alias PolyBot.Parameters

  setup do
    original = Application.get_env(:poly_bot, :event_fetcher)

    on_exit(fn ->
      # Restore whatever the config was before this test ran.
      if is_nil(original) do
        Application.delete_env(:poly_bot, :event_fetcher)
      else
        Application.put_env(:poly_bot, :event_fetcher, original)
      end
    end)

    {:ok, original: original}
  end

  describe "event_fetch_opts/0" do
    test "returns the default Gamma query filters in the test config" do
      assert Parameters.event_fetch_opts() == [
               liquidity_min: 10_000,
               limit: 100,
               closed: false,
               active: true
             ]
    end

    test "reflects a custom minimum_liquidity from config" do
      Application.put_env(:poly_bot, :event_fetcher,
        minimum_liquidity: 42_000,
        interval_ms: 0
      )

      opts = Parameters.event_fetch_opts()

      assert Keyword.fetch!(opts, :liquidity_min) == 42_000
      assert Keyword.fetch!(opts, :limit) == 100
      assert Keyword.fetch!(opts, :closed) == false
      assert Keyword.fetch!(opts, :active) == true
    end

    test "omits :liquidity_min when minimum_liquidity is :infinity" do
      Application.put_env(:poly_bot, :event_fetcher,
        minimum_liquidity: :infinity,
        interval_ms: 0
      )

      opts = Parameters.event_fetch_opts()

      refute Keyword.has_key?(opts, :liquidity_min)

      # The static filters remain untouched.
      assert Keyword.fetch!(opts, :limit) == 100
      assert Keyword.fetch!(opts, :closed) == false
      assert Keyword.fetch!(opts, :active) == true
    end
  end

  describe "event_fetch_worker_opts/0" do
    test "bundles the default interval and fetch_opts in the test config" do
      assert Parameters.event_fetch_worker_opts() == [
               interval_ms: 0,
               fetch_opts: [
                 liquidity_min: 10_000,
                 limit: 100,
                 closed: false,
                 active: true
               ]
             ]
    end

    test "flows a custom interval_ms through from config" do
      Application.put_env(:poly_bot, :event_fetcher,
        minimum_liquidity: 10_000,
        interval_ms: 12_345
      )

      opts = Parameters.event_fetch_worker_opts()

      assert Keyword.fetch!(opts, :interval_ms) == 12_345

      assert Keyword.fetch!(opts, :fetch_opts) == [
               liquidity_min: 10_000,
               limit: 100,
               closed: false,
               active: true
             ]
    end

    test "fetch_opts drops :liquidity_min when minimum_liquidity is :infinity" do
      Application.put_env(:poly_bot, :event_fetcher,
        minimum_liquidity: :infinity,
        interval_ms: 999
      )

      opts = Parameters.event_fetch_worker_opts()

      assert Keyword.fetch!(opts, :interval_ms) == 999
      refute Keyword.has_key?(Keyword.fetch!(opts, :fetch_opts), :liquidity_min)
    end
  end
end
