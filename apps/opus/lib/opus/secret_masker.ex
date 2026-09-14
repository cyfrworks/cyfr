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
  them — `Opus.ExecutionPipeline.secrets/1` is the one collector (vault
  fields preloaded by the executor plus whatever `Opus.OAuthHandler`
  dispensed during the run). Masking happens at each egress of
  guest-influenced text: completed output and failure messages in
  `Opus.Executor` (record, telemetry, terminal event), and guest-emitted
  events in `Opus.FormulaHandler.handle_emit`.

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
  The longest form `mask/2` replaces for any of `secret_values`, in
  bytes, or 0 when there is nothing to mask. A stream that holds back one
  less than this many characters never releases part of a credential it
  would have masked whole.

      iex> Opus.SecretMasker.max_length(["abc", "sk-secret"])
      18
  """
  @spec max_length([String.t()]) :: non_neg_integer()
  def max_length(secret_values) do
    secret_values
    |> usable_secrets()
    |> Enum.flat_map(&forms/1)
    |> Enum.map(&byte_size/1)
    |> Enum.max(fn -> 0 end)
  end

  defp usable_secrets(values) when is_list(values),
    do: Enum.filter(values, &(is_binary(&1) and &1 != ""))

  defp usable_secrets(_values), do: []

  defp do_mask(output, secret_values) when is_map(output) do
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
