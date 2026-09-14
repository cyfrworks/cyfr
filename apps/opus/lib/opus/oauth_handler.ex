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

  Every token is dispensed by the execution's `Cyfr.Execution.Attempt`
  (`dispense_oauth/2`): it meters the node's `oauth:` rate, resolves the
  token from the consent edge's vault resource and adds it to the
  execution's masking set before the guest has it. A refusal crosses the
  WIT `result<string, string>` boundary as a sentence naming its shape,
  never the material involved.
  """

  @doc """
  Build the WASI host function imports for OAuth token access by the
  guest of `execution_id`, whose attempt is open. Returns a map suitable
  for merging into the Wasmex imports.
  """
  @spec build_oauth_imports(String.t()) :: map()
  def build_oauth_imports(execution_id) when is_binary(execution_id) do
    %{
      "cyfr:oauth/token@0.1.0" => %{
        "get-access-token" =>
          {:fn, fn provider -> Cyfr.Execution.Attempt.dispense_oauth(execution_id, provider) end}
      }
    }
  end
end
