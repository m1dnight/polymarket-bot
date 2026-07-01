defmodule PolyBot.ConfigTest do
  use ExUnit.Case, async: false

  alias PolyBot.Config

  describe "optional/3 when the variable is unset" do
    test "returns the default value" do
      name = "POLY_BOT_TEST_UNSET"
      System.delete_env(name)
      on_exit(fn -> System.delete_env(name) end)

      assert Config.optional(name, :string, "fallback") == "fallback"
      assert Config.optional(name, :integer, 99) == 99
      assert Config.optional(name, :boolean, true) == true
    end
  end

  describe "optional/3 when the variable is an empty string" do
    test "returns the default value" do
      name = "POLY_BOT_TEST_EMPTY"
      System.put_env(name, "")
      on_exit(fn -> System.delete_env(name) end)

      assert Config.optional(name, :string, "fallback") == "fallback"
      assert Config.optional(name, :integer, 99) == 99
      assert Config.optional(name, :boolean, true) == true
    end
  end

  describe "optional/3 with :integer coercion" do
    test "parses the raw string into an integer" do
      name = "POLY_BOT_TEST_INT"
      System.put_env(name, "42")
      on_exit(fn -> System.delete_env(name) end)

      assert Config.optional(name, :integer, 0) == 42
    end

    test "parses negative integers" do
      name = "POLY_BOT_TEST_INT_NEG"
      System.put_env(name, "-7")
      on_exit(fn -> System.delete_env(name) end)

      assert Config.optional(name, :integer, 0) == -7
    end
  end

  describe "optional/3 with :boolean coercion" do
    test ~s(coerces "true", "1", and "yes" to true) do
      on_exit(fn ->
        System.delete_env("POLY_BOT_TEST_BOOL_TRUE")
        System.delete_env("POLY_BOT_TEST_BOOL_ONE")
        System.delete_env("POLY_BOT_TEST_BOOL_YES")
      end)

      System.put_env("POLY_BOT_TEST_BOOL_TRUE", "true")
      System.put_env("POLY_BOT_TEST_BOOL_ONE", "1")
      System.put_env("POLY_BOT_TEST_BOOL_YES", "yes")

      assert Config.optional("POLY_BOT_TEST_BOOL_TRUE", :boolean, false) == true
      assert Config.optional("POLY_BOT_TEST_BOOL_ONE", :boolean, false) == true
      assert Config.optional("POLY_BOT_TEST_BOOL_YES", :boolean, false) == true
    end

    test ~s(coerces "false", "0", "no", and any other value to false) do
      on_exit(fn ->
        System.delete_env("POLY_BOT_TEST_BOOL_FALSE")
        System.delete_env("POLY_BOT_TEST_BOOL_ZERO")
        System.delete_env("POLY_BOT_TEST_BOOL_NO")
        System.delete_env("POLY_BOT_TEST_BOOL_OTHER")
      end)

      System.put_env("POLY_BOT_TEST_BOOL_FALSE", "false")
      System.put_env("POLY_BOT_TEST_BOOL_ZERO", "0")
      System.put_env("POLY_BOT_TEST_BOOL_NO", "no")
      System.put_env("POLY_BOT_TEST_BOOL_OTHER", "other")

      assert Config.optional("POLY_BOT_TEST_BOOL_FALSE", :boolean, true) == false
      assert Config.optional("POLY_BOT_TEST_BOOL_ZERO", :boolean, true) == false
      assert Config.optional("POLY_BOT_TEST_BOOL_NO", :boolean, true) == false
      assert Config.optional("POLY_BOT_TEST_BOOL_OTHER", :boolean, true) == false
    end
  end

  describe "optional/3 with :string coercion" do
    test "returns the raw string unchanged" do
      name = "POLY_BOT_TEST_STR"
      System.put_env(name, "hello world")
      on_exit(fn -> System.delete_env(name) end)

      assert Config.optional(name, :string, "default") == "hello world"
    end

    test "does not trim or alter whitespace-containing values" do
      name = "POLY_BOT_TEST_STR_WS"
      System.put_env(name, "  spaced  ")
      on_exit(fn -> System.delete_env(name) end)

      assert Config.optional(name, :string, "default") == "  spaced  "
    end
  end
end
