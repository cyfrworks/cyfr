# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.OAuthHandler do
  @moduledoc """
  Host function handler for OAuth token access.

  Provides the `cyfr:oauth/token@0.1.0` WASI host function import that
  enables Catalyst components to obtain OAuth access tokens without
  ever seeing client credentials or refresh tokens.

  ## Security Model

  - Client credentials stored encrypted in oauth_credentials table — never exposed to WASM
  - Refresh tokens stored encrypted — never exposed to WASM
  - Access tokens are the ONLY thing exposed to WASM, and they're masked in output
  - Provider parameter validated against manifest's declared providers

  ## Architecture

  Follows the same pattern as `Opus.HttpHandler` and `Opus.StorageHandler`.
  Uses ETS for tracking dispensed tokens (cross-process safe — host function
  closures run in the Wasmex GenServer process, but finalize_execution runs
  in the executor process).
  """

  require Logger

  alias Sanctum.Context

  @table :opus_oauth_dispensed_tokens

  @doc """
  Initialize the ETS table for tracking dispensed OAuth tokens.
  Called from `Opus.Application.start/2`.
  """
  @spec init_table() :: :ets.table()
  def init_table do
    :ets.new(@table, [:named_table, :public, :bag])
  end

  @doc """
  Build the WASI host function imports for OAuth token access.

  Returns a map suitable for merging into the Wasmex imports.
  Only call for catalysts that have an oauth block in their manifest.

  ## Options

  - `:resolver` - `(provider -> {:ok, token} | {:error, term})`. The
    default is the legacy callee-keyed lookup; an authority execution
    passes a vault-reader-backed resolver so the token comes from the
    consent edge. Everything else — the manifest validation, the
    dispensed-token tracking that feeds masking and timeout draining, the
    telemetry — is identical on both paths.
  """
  @spec build_oauth_imports(Context.t(), String.t(), String.t(), map(), keyword()) :: map()
  def build_oauth_imports(%Context{} = ctx, component_ref, execution_id, oauth_config, opts \\ [])
      when is_map(oauth_config) do
    resolver =
      Keyword.get(opts, :resolver, fn provider ->
        Sanctum.OAuth.get_access_token(ctx, component_ref, provider)
      end)

    %{
      "cyfr:oauth/token@0.1.0" => %{
        "get-access-token" =>
          {:fn,
           fn provider ->
             get_access_token(provider, resolver, component_ref, execution_id, oauth_config)
           end}
      }
    }
  end

  @doc """
  Collect and delete all dispensed tokens for an execution.
  Returns a list of token strings for use with SecretMasker.
  Safe to call multiple times (second call returns empty list).
  """
  @spec collect_dispensed(String.t() | nil) :: [String.t()]
  def collect_dispensed(nil), do: []

  def collect_dispensed(execution_id) do
    tokens = :ets.lookup(@table, execution_id) |> Enum.map(&elem(&1, 1))
    :ets.delete(@table, execution_id)
    tokens
  rescue
    ArgumentError -> []
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp get_access_token(provider, resolver, component_ref, execution_id, oauth_config) do
    start_time = System.monotonic_time(:millisecond)

    case Map.get(oauth_config, provider) do
      nil ->
        {:error, "provider '#{provider}' not declared in manifest oauth block"}

      provider_config ->
        # Belt + suspenders: validate token_url is https at runtime
        token_url = provider_config["token_url"] || ""

        if not String.starts_with?(token_url, "https://") do
          {:error, "provider '#{provider}' has invalid token_url — must use https://"}
        else
          case resolver.(provider) do
            {:ok, token} ->
              try do
                :ets.insert(@table, {execution_id, token})
              rescue
                ArgumentError ->
                  Logger.warning("[Opus.OAuthHandler] ETS table unavailable for token tracking")
              end

              duration = System.monotonic_time(:millisecond) - start_time

              :telemetry.execute(
                [:cyfr, :opus, :oauth, :token_request],
                %{duration_ms: duration},
                %{component_ref: component_ref, provider: provider, status: :ok}
              )

              {:ok, token}

            {:error, reason} ->
              duration = System.monotonic_time(:millisecond) - start_time

              :telemetry.execute(
                [:cyfr, :opus, :oauth, :token_request],
                %{duration_ms: duration},
                %{
                  component_ref: component_ref,
                  provider: provider,
                  status: :error,
                  reason: String.slice(to_string(reason), 0, 100)
                }
              )

              {:error, reason}
          end
        end
    end
  end
end
