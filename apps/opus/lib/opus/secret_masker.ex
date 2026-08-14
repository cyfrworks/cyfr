# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.SecretMasker do
  @moduledoc """
  Masks credential values in execution output to prevent leakage in logs.

  A component that reads a credential must not have it echoed back into
  execution logs or audit records, so every value it was handed is replaced
  with `[REDACTED]` before the output is recorded.

  ## Usage

  The caller supplies the values, because it is the caller that dispensed
  them: `Opus.Executor` masks with the fields it preloaded from the vault
  plus whatever `Opus.OAuthHandler` dispensed during the run.

      masked_output = Opus.SecretMasker.mask(output, secret_values)

  ## Security Note

  This is a defense-in-depth measure. The primary control is that a
  credential reaches a component only through a consent edge; masking
  covers the case where the component puts one in its own output.
  """

  require Logger

  @redacted "[REDACTED]"

  @doc """
  Mask secret values in output.

  Replaces any occurrence of secret values in the output with `[REDACTED]`.
  Works with maps, lists, and string values.

  ## Examples

      iex> Opus.SecretMasker.mask(%{"result" => "key is sk-secret123"}, ["sk-secret123"])
      %{"result" => "key is [REDACTED]"}

      iex> Opus.SecretMasker.mask(%{"data" => ["value1", "sk-secret"]}, ["sk-secret"])
      %{"data" => ["value1", "[REDACTED]"]}

  """
  @spec mask(term(), [String.t()]) :: term()
  def mask(output, []), do: output

  def mask(output, secret_values) when is_map(output) do
    # Convert to JSON, mask, and convert back
    # This handles nested structures consistently
    case Jason.encode(output) do
      {:ok, json} ->
        masked_json = mask_in_string(json, secret_values)

        case Jason.decode(masked_json) do
          {:ok, result} ->
            result

          {:error, _} ->
            Logger.warning(
              "[Opus.SecretMasker] JSON re-decode failed after masking — masking operation may have broken JSON structure. Falling back to direct map masking."
            )

            mask_map(output, secret_values)
        end

      {:error, _} ->
        Logger.debug(
          "[Opus.SecretMasker] Output is not JSON-encodable, using direct map masking instead"
        )

        mask_map(output, secret_values)
    end
  end

  def mask(output, secret_values) when is_binary(output) do
    mask_in_string(output, secret_values)
  end

  def mask(output, secret_values) when is_list(output) do
    Enum.map(output, fn item -> mask(item, secret_values) end)
  end

  def mask(output, _secret_values), do: output

  # Mask secrets directly in a map (fallback for non-JSON-encodable maps)
  defp mask_map(map, secret_values) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      {mask(k, secret_values), mask(v, secret_values)}
    end)
    |> Map.new()
  end

  # Replace all occurrences of secrets in a string, including encoded variants.
  # This is defense-in-depth: the primary control is domain restriction.
  defp mask_in_string(str, secret_values) when is_binary(str) do
    Enum.reduce(secret_values, str, fn secret, acc ->
      acc = String.replace(acc, secret, @redacted)

      # Only mask encoded variants for secrets >= 4 chars (short secrets
      # produce encoded forms that are too likely to cause false positives)
      if String.length(secret) >= 4 do
        mask_encoded_variants(acc, secret)
      else
        acc
      end
    end)
  end

  # Mask base64 and hex-encoded variants of a secret value
  defp mask_encoded_variants(str, secret) do
    b64 = Base.encode64(secret)
    b64_url = Base.url_encode64(secret)
    hex_lower = Base.encode16(secret, case: :lower)
    hex_upper = Base.encode16(secret, case: :upper)

    str
    |> String.replace(b64, @redacted)
    |> String.replace(b64_url, @redacted)
    |> String.replace(hex_lower, @redacted)
    |> String.replace(hex_upper, @redacted)
  end
end
