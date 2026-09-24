# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.SecretMasker do
  @moduledoc """
  Masks credential values in execution output to prevent leakage in logs.

  A component that reads a credential must not have it echoed back into
  execution logs or audit records, so every value it was handed is replaced
  with `[REDACTED]` before the output is recorded.

  ## Usage

  The caller supplies the values, because it is the caller that dispensed
  them (the vault fields unsealed for the run plus the OAuth tokens handed
  out during it), and masks at each egress of guest-influenced text:
  completed output, failure messages and guest-emitted events.

      masked_output = Prima.SecretMasker.mask(output, secret_values)

  ## Security Note

  This is a defense-in-depth measure. The primary control is that a
  credential reaches a component only through a consent edge; masking
  covers the case where the component puts one in its own output.
  """

  @redacted "[REDACTED]"

  @doc """
  Mask secret values in output.

  Replaces any occurrence of secret values in the output with `[REDACTED]`.
  Works with maps, lists, and string values.

  ## Examples

      iex> Prima.SecretMasker.mask(%{"result" => "key is sk-secret123"}, ["sk-secret123"])
      %{"result" => "key is [REDACTED]"}

      iex> Prima.SecretMasker.mask(%{"data" => ["value1", "sk-secret"]}, ["sk-secret"])
      %{"data" => ["value1", "[REDACTED]"]}

  """
  @spec mask(term(), [String.t()]) :: term()
  def mask(output, secret_values) do
    case usable_secrets(secret_values) do
      [] -> output
      secrets -> do_mask(output, secrets)
    end
  end

  # A secret is replaceable only as a non-empty binary. `String.replace/3`
  # with `""` inserts the marker between every character — corrupting the
  # whole output rather than redacting anything — and a non-binary raises.
  # Both shapes come from caller data (a vault field projected empty, a
  # token bundle that carried a non-string), so they are filtered, not
  # trusted.
  @doc """
  How many bytes at the end of `text` could begin a form `mask/2` replaces
  without completing it: the longest tail of `text` that is a proper prefix
  of one. A stream that holds those bytes back until more text arrives never
  releases part of a credential it would have masked whole, and holds
  nothing back when the text ends in no such prefix.

      iex> Prima.SecretMasker.pending_prefix("key: sk-se", ["sk-secret"])
      5

      iex> Prima.SecretMasker.pending_prefix("nothing to hold", ["sk-secret"])
      0
  """
  @spec pending_prefix(binary(), [String.t()]) :: non_neg_integer()
  def pending_prefix(text, secret_values) when is_binary(text) do
    secret_values
    |> usable_secrets()
    |> Enum.flat_map(&forms/1)
    |> Enum.map(&open_prefix(text, &1))
    |> Enum.max(fn -> 0 end)
  end

  defp open_prefix(text, form) do
    size = byte_size(text)

    Enum.find(min(size, byte_size(form) - 1)..1//-1, 0, fn k ->
      binary_part(text, size - k, k) == binary_part(form, 0, k)
    end)
  end

  defp usable_secrets(values) when is_list(values),
    do: Enum.filter(values, &(is_binary(&1) and &1 != ""))

  defp usable_secrets(_values), do: []

  # Through JSON, so nested structures mask consistently. A value JSON
  # cannot carry, or a replacement that broke the JSON, masks the map
  # directly instead.
  defp do_mask(output, secret_values) when is_map(output) do
    with {:ok, json} <- Jason.encode(output),
         {:ok, result} <- json |> mask_in_string(secret_values) |> Jason.decode() do
      result
    else
      {:error, _} -> mask_map(output, secret_values)
    end
  end

  defp do_mask(output, secret_values) when is_binary(output) do
    mask_in_string(output, secret_values)
  end

  defp do_mask(output, secret_values) when is_list(output) do
    Enum.map(output, fn item -> do_mask(item, secret_values) end)
  end

  defp do_mask(output, _secret_values), do: output

  # Mask secrets directly in a map (fallback for non-JSON-encodable maps)
  defp mask_map(map, secret_values) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      {do_mask(k, secret_values), do_mask(v, secret_values)}
    end)
    |> Map.new()
  end

  # Replace every form of every secret in a string.
  defp mask_in_string(str, secret_values) when is_binary(str) do
    secret_values
    |> Enum.flat_map(&forms/1)
    |> Enum.reduce(str, &String.replace(&2, &1, @redacted))
  end

  # A secret and, for one of four or more characters, its base64 and hex
  # encodings; a shorter secret's encodings match too much unrelated text.
  defp forms(secret) do
    if String.length(secret) >= 4 do
      [
        secret,
        Base.encode64(secret),
        Base.url_encode64(secret),
        Base.encode16(secret, case: :lower),
        Base.encode16(secret, case: :upper)
      ]
    else
      [secret]
    end
  end
end
