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

  Every token is an `oauth_token` host call of the execution's attempt
  (`Opus.HostClient.oauth_token/2`): CYFR meters the node's `oauth:` rate,
  resolves the token from the consent edge's vault resource and adds it to
  the attempt's masking set before answering it. A refusal crosses the WIT
  `result<string, string>` boundary as a sentence naming its shape, never
  the material involved; a host call CYFR refuses crosses as the sentence
  for an unavailable credential store.
  """

  alias Opus.HostClient

  @doc """
  Build the WASI host function imports for OAuth token access by the
  guest whose attempt `host` is attached to. Returns a map suitable for
  merging into the Wasmex imports.
  """
  @spec build_oauth_imports(HostClient.t()) :: map()
  def build_oauth_imports(%HostClient{} = host) do
    %{
      "cyfr:oauth/token@0.1.0" => %{
        "get-access-token" => {:fn, fn provider -> token(host, provider) end}
      }
    }
  end

  defp token(host, provider) when is_binary(provider) do
    case HostClient.oauth_token(host, provider) do
      {:ok, token} -> {:ok, token}
      {:error, {:guest_error, _type, message}} -> {:error, message}
      {:error, {:uncertain, sentence}} -> {:error, sentence}
      {:error, _refusal} -> {:error, "the credential store is unavailable"}
    end
  end

  defp token(_host, _provider), do: {:error, "the provider must be a string"}
end
