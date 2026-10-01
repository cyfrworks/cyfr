# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Confirmation do
  @moduledoc """
  A pending confirmation of a sensitive change moved, on its person's own
  `Cyfr.Bus.confirmations/2` topic. The kind is what happened to it. It
  carries the confirmation's public `ref` (`Prima.Confirmation.ref/1`),
  the `operation` it confirms (`tool.action`) and its `expires_at`, and
  nothing else: never the secret its asking request holds, the change's
  arguments or its preview, which a client reads through
  `confirmation.pending` under its own session.
  """

  alias Cyfr.Bus.Payload

  @kinds [:opened, :confirmed, :consumed, :cancelled, :voided, :expired]
  @fields [:ref, :operation, :expires_at]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :opened | :confirmed | :consumed | :cancelled | :voided | :expired

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          ref: String.t() | nil,
          operation: String.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0` or a field
  this struct does not declare raises.
  """
  @spec new(Prima.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Prima.Actor{} = actor, kind, fields \\ %{}) do
    Payload.build(__MODULE__, @fields, fields, %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds)
    })
  end
end
