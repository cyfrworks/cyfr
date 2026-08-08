# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.OAuthHandler do
  @moduledoc """
  Host function handler for OAuth token access.

  Provides the `cyfr:oauth/token@0.1.0` WASI host function import that
  enables Catalyst components to obtain OAuth access tokens without
  ever seeing client credentials or refresh tokens.

  ## Security Model

  - Client credentials and refresh tokens live sealed in vault entries —
    never exposed to WASM
  - Access tokens are the ONLY thing exposed to WASM, and they're masked in output
  - Provider matching happens at dispense: the bound vault entry refuses
    any provider it wasn't authorized for

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

  ## Options

  - `:resolver` (required) - `(provider -> {:ok, token} | {:error, term})`,
    vault-reader-backed from the consent edge. A component whose edge
    carries no vault binding gets a resolver that denies every request.
  """
  @spec build_oauth_imports(Context.t(), String.t(), String.t(), keyword()) :: map()
  def build_oauth_imports(%Context{} = ctx, component_ref, execution_id, opts \\ []) do
    # The resolver is edge-supplied (vault-reader-backed) — the
    # callee-keyed default died with the legacy execution path. Provider
    # matching and endpoint integrity live behind it: the vault entry is
    # provider-checked at dispense and its endpoints are covered by the
    # consent's binding digest.
    resolver = Keyword.fetch!(opts, :resolver)
    _ = ctx

    %{
      "cyfr:oauth/token@0.1.0" => %{
        "get-access-token" =>
          {:fn,
           fn provider ->
             get_access_token(provider, resolver, component_ref, execution_id)
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

  defp get_access_token(provider, resolver, component_ref, execution_id) do
    start_time = System.monotonic_time(:millisecond)

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
