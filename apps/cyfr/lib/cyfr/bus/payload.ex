# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Payload do
  @moduledoc false
  # The checks every payload constructor under `Cyfr.Bus` shares: a
  # tenant payload's athanor is its actor's, a kind outside the struct's
  # closed union raises, and a field the struct does not declare raises
  # rather than riding along.

  @doc false
  @spec athanor!(Cyfr.Actor.t()) :: String.t()
  def athanor!(%Cyfr.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "",
      do: athanor_id

  def athanor!(%Cyfr.Actor{athanor_id: athanor_id}) do
    raise ArgumentError,
          "a tenant payload needs an actor with a non-empty athanor_id, got #{inspect(athanor_id)}"
  end

  def athanor!(other) do
    raise ArgumentError, "a tenant payload needs a Cyfr.Actor, got #{inspect(other, limit: 3)}"
  end

  @doc false
  @spec kind!(module(), atom(), [atom()]) :: atom()
  def kind!(module, kind, kinds) do
    if kind in kinds do
      kind
    else
      raise ArgumentError,
            "#{inspect(module)} has no kind #{inspect(kind)}; its kinds are #{inspect(kinds)}"
    end
  end

  @doc false
  # `text` cut to at most `max` bytes on a character boundary, and whether
  # anything was cut.
  @spec cap(binary(), non_neg_integer()) :: {binary(), boolean()}
  def cap(text, max) when is_binary(text) and byte_size(text) <= max, do: {text, false}
  def cap(text, max) when is_binary(text), do: {whole(binary_part(text, 0, max)), true}

  defp whole(bin) do
    if String.valid?(bin), do: bin, else: whole(binary_part(bin, 0, byte_size(bin) - 1))
  end

  @doc false
  @spec build(module(), [atom()], map() | keyword(), map()) :: struct()
  def build(module, allowed, fields, fixed) do
    fields = Map.new(fields)

    case Map.keys(fields) -- allowed do
      [] ->
        struct!(module, Map.merge(fields, fixed))

      unknown ->
        raise ArgumentError, "#{inspect(module)} declares no field #{inspect(Enum.sort(unknown))}"
    end
  end
end
