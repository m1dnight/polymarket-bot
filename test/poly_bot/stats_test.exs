defmodule PolyBot.StatsTest do
  # the counters are global (persistent_term), so don't run alongside other
  # test modules that might touch them.
  use ExUnit.Case, async: false

  require PolyBot.Stats, as: Stats

  setup do
    # reset all counters to zero.
    Stats.init()
    :ok
  end

  describe "increase/2" do
    test "increments by 1 by default" do
      assert Stats.get(:ws_messages) == 0

      Stats.increase(:ws_messages)
      Stats.increase(:ws_messages)

      assert Stats.get(:ws_messages) == 2
    end

    test "increments by the given delta" do
      Stats.increase(:ws_messages, 5)
      Stats.increase(:ws_messages, 2)

      assert Stats.get(:ws_messages) == 7
    end

    test "all/0 returns a map of every counter's total" do
      assert Stats.all() == %{ws_messages: 0}

      Stats.increase(:ws_messages, 3)

      assert Stats.all() == %{ws_messages: 3}
    end

    test "rejects unknown counter names at compile time" do
      assert_raise ArgumentError, ~r/unknown counter :nope/, fn ->
        Code.compile_string("""
        defmodule PolyBot.StatsTest.UnknownCounter do
          require PolyBot.Stats

          def bump, do: PolyBot.Stats.increase(:nope)
        end
        """)
      end
    end
  end
end
