defmodule Opus.SecretMasker do
  @moduledoc """
  Masks secret values in execution output to prevent leakage in logs.

  When a component has access to secrets, those secret values should not
  appear in execution logs or audit records. This module replaces any
  occurrences of secret values with `[REDACTED]`.

  ## Usage

      # Get the list of secret values the component can access
      secret_values = Opus.SecretMasker.get_granted_secrets(ctx, component_ref)

      # After execution, mask any secrets in the output
      masked_output = Opus.SecretMasker.mask(output, secret_values)

  ## Security Note

  This is a defense-in-depth measure. The primary security control is
  that secrets are only accessible via the WASI interface with explicit
  grants. Masking provides an additional layer of protection against
  accidental exposure in logs.
  """

  alias Sanctum.Context

  @redacted "[REDACTED]"

  @doc """
  Get the list of secret values a component has access to.

  Returns a list of secret values (not names) that the component can read.
  This is used to know which values to mask in output.

  ## Examples

      iex> Opus.SecretMasker.get_granted_secrets(ctx, "my-component:1.0")
      ["sk-secret123", "api-key-456"]

  """
  @spec get_granted_secrets(Context.t() | nil, String.t() | nil) :: [String.t()]
  def get_granted_secrets(nil, _component_ref), do: []
  def get_granted_secrets(_ctx, nil), do: []
  def get_granted_secrets(%Context{} = ctx, component_ref) when is_binary(component_ref) do
    # Use resolve_granted via MCP boundary to get all granted secret values at once
    case Sanctum.MCP.handle("secret", ctx, %{"action" => "resolve_granted", "component_ref" => component_ref}) do
      {:ok, %{secrets: secrets}} when is_map(secrets) ->
        Map.values(secrets)

      {:error, _} ->
        []
    end
  end

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
          {:ok, result} -> result
          {:error, _} -> output  # Return original if decode fails
        end

      {:error, _} ->
        # Can't encode as JSON, try direct map masking
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
      # Only mask non-trivial secrets (at least 4 chars)
      if String.length(secret) >= 4 do
        acc
        |> String.replace(secret, @redacted)
        |> mask_encoded_variants(secret)
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
