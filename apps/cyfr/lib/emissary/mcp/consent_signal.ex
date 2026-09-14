# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ConsentSignal do
  @moduledoc """
  Maps four consent remediation signals to JSON-RPC errors with distinct
  codes and structured data that clients can branch on.

  Each signal includes a -335xx code, a human-readable sentence and
  `error.data` shaped as `{"tag": ..., "payload": ...}`.

  The GUEST wire is not this: in-chain formula children keep the
  remediation object shape `Cyfr.Remediation` owns (component-guide
  documents it), and the tincture iframe bridge keeps its own protocol.
  """

  @tags [:setup_required, :consent_required, :consent_conflict, :restart_required]

  @type tag :: :setup_required | :consent_required | :consent_conflict | :restart_required

  @doc "Whether a term is a consent signal — `{tag, payload}` with a map payload."
  @spec signal?(term()) :: boolean()
  def signal?({tag, payload}) when tag in @tags and is_map(payload), do: true
  def signal?(_), do: false

  @doc "The four tag atoms, for rosters and drift tests."
  @spec tags() :: [tag()]
  def tags, do: @tags

  @doc """
  The short human sentence for a signal — what a client that reads no
  `data` shows. The payload's detail is for clients that branch.
  """
  @spec message({tag(), map()}) :: String.t()
  def message({:setup_required, payload}) do
    case payload do
      %{"need" => need, "node_ref" => ref} when is_binary(need) and is_binary(ref) ->
        "Setup required: #{ref} needs a vault entry for \"#{need}\" — grant it a profile first"

      %{"node_ref" => ref} when is_binary(ref) ->
        "Setup required: #{ref} is not ready — grant it a profile first"

      _ ->
        "Setup required: the component is not ready — grant it a profile first"
    end
  end

  def message({:consent_required, payload}) do
    case payload do
      %{"detail" => detail} when is_binary(detail) ->
        "Consent required: #{detail}"

      _ ->
        "Consent required: permissions changed since they were approved — review and re-grant"
    end
  end

  def message({:consent_conflict, _payload}),
    do: "Consent conflict: the consent changed while deciding — re-run the grant"

  def message({:restart_required, _payload}),
    do: "Approved — re-run the command to continue (the in-flight run was stopped)"

  @doc ~S(The `error.data` object: `{"tag": tag, "payload": payload}`.)
  @spec data({tag(), map()}) :: map()
  def data({tag, payload}) when tag in @tags and is_map(payload),
    do: %{"tag" => Atom.to_string(tag), "payload" => payload}
end
