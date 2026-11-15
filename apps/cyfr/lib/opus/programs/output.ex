# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.Output do
  @moduledoc """
  Bytes a program wrote on its terminal, as `Opus.Programs` hands them to
  a process attached to the session: each `{:bytes, output}` message and
  an attach's `tail`. What a program prints may be a credential (a
  sign-in's code, an address with a token in it), so the value inspects
  as its size alone, and a crash report or a status that prints a
  mailbox, a message or a state holding one prints none of its bytes.
  """

  @enforce_keys [:bytes]
  defstruct [:bytes]

  @type t :: %__MODULE__{bytes: binary()}

  @doc "Wrap `bytes`."
  @spec new(binary()) :: t()
  def new(bytes) when is_binary(bytes), do: %__MODULE__{bytes: bytes}

  defimpl Inspect, for: Opus.Programs.Output do
    use Boundary, classify_to: Opus

    def inspect(%{bytes: bytes}, _opts),
      do: "#Opus.Programs.Output<#{byte_size(bytes)} bytes>"
  end
end
