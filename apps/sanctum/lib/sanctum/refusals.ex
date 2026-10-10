# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Refusals do
  @moduledoc """
  The gate's normalization of any refusal a tool can produce, whichever
  vocabulary it came from, into `%Prima.Refusal{}`.

  The authorization vocabulary (`Sanctum.Unauthorized`) classifies its own
  reasons and is asked first; `Prima.Refusal`'s closed table answers the
  rest — the consent signals among them — and a `%Prima.Refusal{}` a
  provider already built (a registry's own error, from
  `Compendium.Providers.Shared.refusal/1`) is itself. A reason nobody
  knows is `internal`, with the fixed sentence, logged by its shape.

  `classify/2` is the one place a refusal's sentence is chosen for the
  caller's credential, and `known?/1` the one answer to whether either
  vocabulary knows a reason.
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
  `classify/1`'s refusal with its sentence chosen for the caller's
  credential (`Sanctum.Context`'s `auth_method`) where its reason is an
  authorization reason, bare or inside a `%Prima.Refusal{}`: an API key's
  missing permission names the scope to recreate the key with
  (`Sanctum.Unauthorized.message/2`). Every other field, and every other
  reason's sentence, is `classify/1`'s, so the class, the stage and the
  code a surface answers with do not depend on the credential.

  It is its own function rather than `classify/1` with a default: a
  wrapped refusal's sentence is re-chosen here, where `classify/1`
  returns it as the provider built it.
  """
  @spec classify(term(), Sanctum.Context.auth_method()) :: Prima.Refusal.t()
  def classify(reason, auth_method) do
    %Prima.Refusal{reason: inner} = refusal = classify(reason)

    if Sanctum.Unauthorized.reason?(inner),
      do: %{refusal | message: Sanctum.Unauthorized.message(inner, auth_method)},
      else: refusal
  end

  @doc """
  Whether `reason` is a refusal either vocabulary knows: an authorization
  reason (`Sanctum.Unauthorized.reason?/1`) or a reason of
  `Prima.Refusal`'s table, a `%Prima.Refusal{}` among them
  (`Prima.Refusal.reason?/1`). A producer's bare sentence and a term
  nobody knows are not.
  """
  @spec known?(term()) :: boolean()
  def known?(reason), do: Sanctum.Unauthorized.reason?(reason) or Prima.Refusal.reason?(reason)

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
