# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.Error do
  @moduledoc """
  The host's renderer for any refusal a tool can produce, whichever
  vocabulary it came from.

  The refusal vocabulary itself is `Cyfr.Refusal`, in the contracts, where
  the runner's renderer reads it too — one vocabulary, and this is one of
  its readers. What this module adds is the product vocabularies only the
  control plane knows: an unauthorized caller (`Sanctum.Unauthorized`), an
  OCI registry's own error (`Compendium.OCI.Errors`), and a consent signal
  (`Emissary.MCP.ConsentSignal`, a protocol error with a -335xx code and
  structured `error.data`, which the wire router emits as a JSON-RPC
  error).

  Compiler output, upstream error codes and other specific diagnostics may
  remain client-safe strings, and render as themselves.
  """

  @doc """
  The client-safe sentence for ANY refusal a tool can produce, or `nil`
  when the term is internal and must not be reflected.

  Callers log an unknown term where it was produced and hand the caller a
  generic sentence rather than `inspect/1`'s spelling of it.

  Keeping this here also keeps `apps/opus` off the product vocabularies'
  own modules: `Cyfr.Boundaries` pins what opus may reach into, and a
  renderer is not a reason to widen that.
  """
  @spec render(term(), atom() | nil) :: String.t() | nil
  def render(reason, auth_method \\ nil)

  def render(reason, _auth_method) when is_binary(reason), do: reason

  def render(reason, auth_method) do
    cond do
      # The method rides along so the API-key remediation hint renders on
      # every surface, not only the wire router's own refusal path.
      Sanctum.Unauthorized.reason?(reason) -> Sanctum.Unauthorized.message(reason, auth_method)
      Cyfr.Refusal.reason?(reason) -> Cyfr.Refusal.message(reason)
      match?(%Compendium.OCI.Errors{}, reason) -> Compendium.MCP.Shared.to_error_string(reason)
      Emissary.MCP.ConsentSignal.signal?(reason) -> Emissary.MCP.ConsentSignal.message(reason)
      true -> nil
    end
  end
end
