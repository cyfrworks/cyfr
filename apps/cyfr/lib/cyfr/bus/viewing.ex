# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Viewing do
  @moduledoc """
  The estate a page has in view, told to the bar over that page on the
  page-local `Cyfr.Bus.page_viewing/1`. It names an estate the bar
  already lists and grants nothing: the bar ignores one it does not.
  """

  alias Cyfr.Bus.Payload

  @kinds [:viewing]

  @enforce_keys [:kind, :athanor_id]
  defstruct [:kind, :athanor_id]

  @type kind :: :viewing
  @type t :: %__MODULE__{kind: kind(), athanor_id: String.t()}

  @doc "The closed union: the estate in view."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "`athanor_id` is in view."
  @spec new(String.t()) :: t()
  def new(athanor_id) when is_binary(athanor_id),
    do: %__MODULE__{kind: Payload.kind!(__MODULE__, :viewing, @kinds), athanor_id: athanor_id}
end
