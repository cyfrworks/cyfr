# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.AthanorArchived do
  @moduledoc """
  An athanor was archived, on the global
  `Cyfr.Bus.athanor_archived_global/0`: whatever serves it from outside
  any tenant topic must stop. Announced after the archive's own
  synchronous work, so nothing reads it as permission to keep going.
  """

  alias Cyfr.Bus.Payload

  @kinds [:archived]

  @enforce_keys [:kind, :athanor_id]
  defstruct [:kind, :athanor_id]

  @type kind :: :archived
  @type t :: %__MODULE__{kind: kind(), athanor_id: String.t()}

  @doc "The closed union: the athanor was archived."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The archive of `athanor_id`."
  @spec new(String.t()) :: t()
  def new(athanor_id) when is_binary(athanor_id) and athanor_id != "",
    do: %__MODULE__{kind: Payload.kind!(__MODULE__, :archived, @kinds), athanor_id: athanor_id}
end
