defmodule PolyBot.Stats do
  @moduledoc """
  Low-overhead runtime counters for hot paths (e.g. counting websocket
  messages).

  The counters live in a single `:counters` array created with
  `:write_concurrency` (per-scheduler cells, so concurrent increments don't
  contend on a cache line) whose reference is stored once in
  `:persistent_term`. `increase/2` is a macro: the counter name is resolved to
  its array index at compile time, so an increment compiles down to a plain
  `:counters.add/3` on a `:persistent_term.get/1` — no runtime lookup, and an
  unknown counter name fails the build.

  Counters are monotonic. Readers that want a rate keep the previous total and
  diff it; there is deliberately no reset (a read-then-zero on `:counters`
  would lose concurrent increments).

  Callers of `increase/2` must `require` this module (it is a macro):

      require PolyBot.Stats, as: Stats

      Stats.increase(:ws_messages)

  New counters are added by extending `@counters` (and mirroring the name in
  `t:counter/0`).
  """

  # The registry of counters, in array order. `t:counter/0` mirrors this list.
  @counters [:ws_messages]

  @pt_key __MODULE__

  @typedoc "A counter name. Mirrors `@counters`."
  @type counter :: :ws_messages

  # ---------------------------------------------------------------------------#
  #                                Public API                                  #
  # ---------------------------------------------------------------------------#

  @doc """
  Create the counters array and store its reference in `:persistent_term`.

  Called once from `PolyBot.Application.start/2` before the supervision tree
  starts, so the counters exist before any process increments them. Calling it
  again replaces the array, resetting every counter to zero (useful in tests).

  ## Examples

      iex> PolyBot.Stats.init()
      :ok

  """
  @spec init() :: :ok
  def init do
    :persistent_term.put(@pt_key, :counters.new(length(@counters), [:write_concurrency]))
  end

  @doc """
  Increment counter `name` by `delta` (default 1).

  Macro: `name` must be a literal atom from `@counters`; it is resolved to the
  counter's array index at compile time and an unknown name raises at build
  time.

  ## Examples

      iex> PolyBot.Stats.increase(:ws_messages)
      :ok

      iex> PolyBot.Stats.increase(:ws_messages, 10)
      :ok

  """
  defmacro increase(name, delta \\ 1) do
    index = counter_index!(name)

    quote do
      :counters.add(:persistent_term.get(unquote(@pt_key)), unquote(index), unquote(delta))
    end
  end

  @doc """
  Return the current total of counter `name`.

  ## Examples

      iex> PolyBot.Stats.get(:ws_messages)
      42

  """
  @spec get(counter()) :: integer()
  def get(name)

  for {name, index} <- Enum.with_index(@counters, 1) do
    def get(unquote(name)) do
      :counters.get(:persistent_term.get(@pt_key), unquote(index))
    end
  end

  @doc """
  Return the current totals of all registered counters as a map.

  ## Examples

      iex> PolyBot.Stats.all()
      %{ws_messages: 42}

  """
  @spec all() :: %{counter() => integer()}
  def all do
    ref = :persistent_term.get(@pt_key)

    @counters
    |> Enum.with_index(1)
    |> Map.new(fn {name, index} -> {name, :counters.get(ref, index)} end)
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # Resolves a literal counter name to its 1-based array index at macro
  # expansion time.
  defp counter_index!(name) do
    case Enum.find_index(@counters, &(&1 == name)) do
      nil ->
        raise ArgumentError,
              "unknown counter #{inspect(name)}; the name must be a literal atom " <>
                "from #{inspect(@counters)} (see PolyBot.Stats)"

      index ->
        index + 1
    end
  end
end
