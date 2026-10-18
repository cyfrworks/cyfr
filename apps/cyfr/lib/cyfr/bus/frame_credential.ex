# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.FrameCredential do
  @moduledoc """
  A frame credential of one person was suspended or revoked, on the global
  `Cyfr.Bus.frame_credentials/1` topic keyed by the person: a stream held
  open under that credential is re-established at once. `credential_id`
  is the credential's row id, never its bearer.
  """

  alias Cyfr.Bus.Payload

  @kinds [:suspended, :revoked]

  @enforce_keys [:kind, :user_id, :credential_id]
  defstruct [:kind, :user_id, :credential_id]

  @type kind :: :suspended | :revoked
  @type t :: %__MODULE__{kind: kind(), user_id: String.t(), credential_id: String.t()}

  @doc "The closed union of what happened to the credential."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "`credential_id` of `user_id` was suspended or revoked; a kind outside `kinds/0` raises."
  @spec new(kind(), String.t(), String.t()) :: t()
  def new(kind, user_id, credential_id) when is_binary(user_id) and is_binary(credential_id),
    do: %__MODULE__{
      kind: Payload.kind!(__MODULE__, kind, @kinds),
      user_id: user_id,
      credential_id: credential_id
    }
end
