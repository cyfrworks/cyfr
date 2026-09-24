# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Payload do
  @moduledoc false
  # The checks every payload constructor under `Cyfr.Bus` shares: a
  # tenant payload's athanor is its actor's, a kind outside the struct's
  # closed union raises, and a field the struct does not declare raises
  # rather than riding along.

  @doc false
  @spec athanor!(Prima.Actor.t()) :: String.t()
  def athanor!(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "",
      do: athanor_id

  def athanor!(%Prima.Actor{athanor_id: athanor_id}) do
    raise ArgumentError,
          "a tenant payload needs an actor with a non-empty athanor_id, got #{inspect(athanor_id)}"
  end

  def athanor!(other) do
    raise ArgumentError, "a tenant payload needs a Prima.Actor, got #{inspect(other, limit: 3)}"
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

  @refusal_max_bytes 200

  @doc false
  # A refusal fit for a payload: its class and its public sentence
  # (`Prima.Refusal.classify/1`, which keeps a refusal the bridge already
  # classified), the sentence cut to 200 bytes on a character boundary —
  # never an arbitrary term. No refusal is `nil`.
  @spec refusal(term()) :: %{class: Prima.Refusal.class(), message: String.t()} | nil
  def refusal(nil), do: nil

  def refusal(reason) do
    %Prima.Refusal{class: class, message: message} = Prima.Refusal.classify(reason)
    {message, _cut?} = cap(message, @refusal_max_bytes)
    %{class: class, message: message}
  end

  @doc false
  # `refusal/1` over the named fields of `fields` that are present.
  @spec refusals(map(), [atom()]) :: map()
  def refusals(fields, keys) do
    Enum.reduce(keys, fields, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.update!(acc, key, &refusal/1), else: acc
    end)
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
