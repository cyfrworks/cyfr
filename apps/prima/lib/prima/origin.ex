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
  origin. Origin records how a run started, for the record and the screens
  that show runs; it admits or refuses nothing, since a run stands on the
  grant of the person it acts as whatever started it, and it does not
  record that a person stays present.
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
end
