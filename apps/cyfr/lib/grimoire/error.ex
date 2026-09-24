# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.Error do
  @moduledoc """
  The gate's normalization of any refusal a tool can produce, whichever
  vocabulary it came from, into `%Prima.Refusal{}`.

  The authorization vocabulary (`Sanctum.Unauthorized`) classifies its own
  reasons and is asked first; `Prima.Refusal`'s closed table answers the
  rest — the consent signals among them — and a `%Prima.Refusal{}` a
  provider already built (a registry's own error, from
  `Compendium.Providers.Shared.refusal/1`) is itself. A reason nobody
  knows is `internal`, with the fixed sentence, logged by its shape.
  """

  @doc "The normalized refusal for `reason`."
  @spec classify(term()) :: Prima.Refusal.t()
  def classify(reason) do
    if Sanctum.Unauthorized.reason?(reason) do
      %Prima.Refusal{
        class: Sanctum.Unauthorized.class(reason),
        reason: reason,
        message: Sanctum.Unauthorized.message(reason)
      }
    else
      Prima.Refusal.classify(reason)
    end
  end

  @doc """
  The gate's own refusal of `reason`, made before any handler ran:
  `classify/1`'s refusal with `stage: :admission`.
  """
  @spec admission(term()) :: Prima.Refusal.t()
  def admission(reason), do: %{classify(reason) | stage: :admission}

  @doc """
  The public sentence for any refusal: `classify/1`'s message, never `nil`
  and never an `inspect/1` of the term.
  """
  @spec render(term()) :: String.t()
  def render(reason), do: classify(reason).message

  @doc """
  The JSON-RPC code name a refusal's row answers with in place of its
  class's code, or `nil` (`Sanctum.Unauthorized.code_override/1`,
  `Prima.Refusal.code_override/1`).
  """
  @spec code_override(Prima.Refusal.t()) :: atom() | nil
  def code_override(%Prima.Refusal{reason: reason} = refusal) do
    if Sanctum.Unauthorized.reason?(reason),
      do: Sanctum.Unauthorized.code_override(reason),
      else: Prima.Refusal.code_override(refusal)
  end
end
