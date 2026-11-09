# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.AquaAsk do
  @moduledoc """
  What a page asks the person's own assistant beside it, on the
  page-local `Cyfr.Bus.aqua_ask/1`: the panel opens with `sentence`,
  which Prism wrote, after any draft the person has, and sends nothing.
  It names what it asks about by the names a declaration and the layout
  give it, never a line of what a page shows.
  """

  alias Cyfr.Bus.Payload

  @kinds [:ask]

  @enforce_keys [:kind, :sentence]
  defstruct [:kind, :sentence]

  @type kind :: :ask
  @type t :: %__MODULE__{kind: kind(), sentence: String.t()}

  @doc "The closed union: an ask."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Open the assistant with `sentence`."
  @spec new(String.t()) :: t()
  def new(sentence) when is_binary(sentence),
    do: %__MODULE__{kind: Payload.kind!(__MODULE__, :ask, @kinds), sentence: sentence}
end
