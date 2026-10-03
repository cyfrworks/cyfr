# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Origin do
  @moduledoc """
  How a run started, set by the admission path that starts it and never by
  the credential it carries. The enum is closed:

    * `interactive` — a person acting on an interactive surface: Prism
      under a session, or a paired device.
    * `programmatic` — a call over the HTTP API or MCP, whatever credential
      is behind it.
    * `schedule` — a scheduler's fire.
    * `webhook` — a delivery to a webhook.

  The wire spelling of each is its name. Children inherit their root's
  origin. A grant names the non-empty set of origins it admits
  (`parse_list/1`); one that names none admits `interactive` alone.
  Origin records how a run started, not that a person stays present.
  """

  @origins [:interactive, :programmatic, :schedule, :webhook]
  @by_spelling Map.new(@origins, &{Atom.to_string(&1), &1})

  @type t :: :interactive | :programmatic | :schedule | :webhook

  @doc "The four origins, in their fixed order."
  @spec values() :: [t()]
  def values, do: @origins

  @doc "The four wire spellings, in the same order."
  @spec spellings() :: [String.t()]
  def spellings, do: Enum.map(@origins, &Atom.to_string/1)

  @doc "Whether `value` is an origin."
  @spec origin?(term()) :: boolean()
  def origin?(value), do: value in @origins

  @doc "An origin's wire spelling."
  @spec to_wire(t()) :: String.t()
  def to_wire(origin) when origin in @origins, do: Atom.to_string(origin)

  @doc "The origin a wire spelling names; any other value is refused."
  @spec from_wire(term()) :: {:ok, t()} | {:error, {:unknown_origin, term()}}
  def from_wire(spelling) do
    case Map.fetch(@by_spelling, spelling) do
      {:ok, origin} -> {:ok, origin}
      :error -> {:error, {:unknown_origin, spelling}}
    end
  end

  @doc """
  The origins a grant admits, from their wire spellings: a non-empty list
  of distinct origins, answered in the enum's order.
  """
  @spec parse_list(term()) ::
          {:ok, [t(), ...]}
          | {:error, :empty_origins | :duplicate_origin | {:unknown_origin, term()}}
  def parse_list([_ | _] = spellings) do
    with {:ok, origins} <- parse_each(spellings) do
      if length(Enum.uniq(origins)) == length(origins),
        do: {:ok, Enum.filter(@origins, &(&1 in origins))},
        else: {:error, :duplicate_origin}
    end
  end

  def parse_list(_spellings), do: {:error, :empty_origins}

  @doc "The wire spellings of a set of origins, in the enum's order."
  @spec to_wire_list([t()]) :: [String.t()]
  def to_wire_list(origins), do: for(origin <- @origins, origin in origins, do: to_wire(origin))

  defp parse_each(spellings) do
    Enum.reduce_while(spellings, {:ok, []}, fn spelling, {:ok, acc} ->
      case from_wire(spelling) do
        {:ok, origin} -> {:cont, {:ok, acc ++ [origin]}}
        error -> {:halt, error}
      end
    end)
  end
end
