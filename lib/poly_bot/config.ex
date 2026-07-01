defmodule PolyBot.Config do
  @moduledoc """
  Helpers for reading runtime configuration from environment variables.

  Used from `config/runtime.exs` so every tunable is surfaced as an env var with
  a sensible default.
  """

  @typedoc "Supported coercions for an environment variable's raw string value."
  @type cast :: :integer | :boolean | :string

  # ---------------------------------------------------------------------------#
  #                                Public API                                  #
  # ---------------------------------------------------------------------------#

  @doc """
  Read environment variable `name`, coercing it to `type`, falling back to
  `default` when the variable is unset or blank.

  ## Examples

      iex> PolyBot.Config.optional("EVENT_FETCHER_MINIMUM_LIQUIDITY", :integer, 10_000)
      10_000

  """
  @spec optional(String.t(), cast(), term()) :: term()
  def optional(name, type, default) do
    case System.get_env(name) do
      value when value in [nil, ""] -> default
      value -> cast(value, type)
    end
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  @spec cast(String.t(), cast()) :: integer() | boolean() | String.t()
  defp cast(value, :integer), do: String.to_integer(value)
  defp cast(value, :boolean), do: value in ~w(true 1 yes)
  defp cast(value, :string), do: value
end
