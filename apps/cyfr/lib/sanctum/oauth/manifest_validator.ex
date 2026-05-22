# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.OAuth.ManifestValidator do
  @moduledoc """
  Validates the `"oauth"` block in catalyst manifests.

  The oauth block is a map of provider names to OAuth config:

      %{
        "google" => %{
          "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
          "token_url" => "https://oauth2.googleapis.com/token",
          "client_id_secret" => "GOOGLE_CLIENT_ID",
          "client_secret_secret" => "GOOGLE_CLIENT_SECRET",
          "scopes" => ["https://www.googleapis.com/auth/gmail.readonly"],
          "auth_style" => "params",
          "extra_params" => %{"access_type" => "offline"}
        }
      }
  """

  @max_provider_length 64
  @valid_auth_styles ["params", "header"]

  @doc """
  Validate an oauth manifest block.

  Returns `:ok` or `{:error, errors}` where errors is a list of strings.
  """
  @spec validate(map()) :: :ok | {:error, [String.t()]}
  def validate(oauth) when is_map(oauth) do
    errors =
      oauth
      |> Enum.flat_map(fn {provider, config} ->
        validate_provider(provider, config)
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  def validate(_), do: {:error, ["oauth must be a map"]}

  defp validate_provider(provider, config) when is_binary(provider) and is_map(config) do
    validate_provider_name(provider) ++
      validate_required_url(config, "authorize_url", provider) ++
      validate_required_url(config, "token_url", provider) ++
      validate_required_string(config, "client_id_secret", provider) ++
      validate_optional_string(config, "client_secret_secret", provider) ++
      validate_scopes(config, provider) ++
      validate_auth_style(config, provider) ++
      validate_extra_params(config, provider)
  end

  defp validate_provider(provider, _config) when is_binary(provider) do
    ["#{provider}: config must be a map"]
  end

  defp validate_provider(provider, _config) do
    ["provider key must be a string, got: #{inspect(provider)}"]
  end

  defp validate_provider_name(name) do
    cond do
      String.length(name) == 0 ->
        ["provider name cannot be empty"]

      String.length(name) > @max_provider_length ->
        ["provider '#{name}': name exceeds #{@max_provider_length} characters"]

      not Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9\-]*$/, name) ->
        ["provider '#{name}': name must be alphanumeric with hyphens, starting with alphanumeric"]

      true ->
        []
    end
  end

  defp validate_required_url(config, field, provider) do
    case Map.get(config, field) do
      nil ->
        ["#{provider}: missing required field '#{field}'"]

      url when is_binary(url) ->
        if String.starts_with?(url, "https://") do
          []
        else
          ["#{provider}: #{field} must use https:// (got: #{String.slice(url, 0, 30)}...)"]
        end

      _ ->
        ["#{provider}: #{field} must be a string"]
    end
  end

  defp validate_required_string(config, field, provider) do
    case Map.get(config, field) do
      nil -> ["#{provider}: missing required field '#{field}'"]
      val when is_binary(val) and val != "" -> []
      _ -> ["#{provider}: #{field} must be a non-empty string"]
    end
  end

  defp validate_optional_string(config, field, provider) do
    case Map.get(config, field) do
      nil -> []
      val when is_binary(val) and val != "" -> []
      _ -> ["#{provider}: #{field} must be a non-empty string if provided"]
    end
  end

  defp validate_scopes(config, provider) do
    case Map.get(config, "scopes") do
      nil ->
        ["#{provider}: missing required field 'scopes'"]

      scopes when is_list(scopes) ->
        cond do
          scopes == [] ->
            ["#{provider}: scopes must be a non-empty list"]

          not Enum.all?(scopes, &is_binary/1) ->
            ["#{provider}: all scopes must be strings"]

          true ->
            []
        end

      _ ->
        ["#{provider}: scopes must be a list of strings"]
    end
  end

  defp validate_auth_style(config, provider) do
    case Map.get(config, "auth_style") do
      nil -> []
      style when style in @valid_auth_styles -> []
      other -> ["#{provider}: auth_style must be one of #{inspect(@valid_auth_styles)}, got: #{inspect(other)}"]
    end
  end

  defp validate_extra_params(config, provider) do
    case Map.get(config, "extra_params") do
      nil ->
        []

      params when is_map(params) ->
        if Enum.all?(params, fn {k, v} -> is_binary(k) and is_binary(v) end) do
          []
        else
          ["#{provider}: extra_params must be a map of string keys to string values"]
        end

      _ ->
        ["#{provider}: extra_params must be a map"]
    end
  end
end
