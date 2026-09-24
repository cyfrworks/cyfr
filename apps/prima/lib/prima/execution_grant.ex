# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ExecutionGrant do
  @moduledoc """
  The standing an admitted execution runs under: the estate it was
  admitted in (`athanor_id`) and that estate's `security_generation` when
  its root was admitted (`generation`).

  A root's grant is read from the estate's current active standing at
  admission and stored on its attempt row; a child and every successor
  attempt carry their parent's stored grant unchanged. An archive raises
  the estate's generation, and a reopen raises it again, so a grant stamped
  before an archive never matches the estate's standing afterwards: the
  work it admitted is retired for good, and only a freshly admitted root
  runs in the reopened estate.

  A grant carries no permissions and no credentials. It stays on the
  control plane: a worker presents its signed attempt identity, never a
  grant, and CYFR reads the grant from what it stored.
  """

  @enforce_keys [:athanor_id, :generation]
  defstruct [:athanor_id, :generation]

  @type t :: %__MODULE__{athanor_id: String.t(), generation: pos_integer()}

  @doc """
  A grant for `athanor_id` at `generation`: `{:ok, grant}`, or
  `{:error, :invalid_grant}` for an estate id that is not a non-empty
  string or a generation that is not a positive integer.
  """
  @spec new(term(), term()) :: {:ok, t()} | {:error, :invalid_grant}
  def new(athanor_id, generation)
      when is_binary(athanor_id) and athanor_id != "" and is_integer(generation) and
             generation > 0,
      do: {:ok, %__MODULE__{athanor_id: athanor_id, generation: generation}}

  def new(_athanor_id, _generation), do: {:error, :invalid_grant}

  @doc "Whether `term` is a well-formed grant."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{athanor_id: athanor_id, generation: generation}),
    do: match?({:ok, _}, new(athanor_id, generation))

  def valid?(_term), do: false
end
