# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Loader.Decision do
  @moduledoc """
  The consent-integrity decision table: given what was granted and what is
  installed, exactly one outcome.

  Grain follows what the consent actually stores. Row integrity is checked
  **per node** (a `release_digest` column that no longer re-derives from its
  own row is tampering wherever it sits). Pinned equality is checked at
  **graph** grain — pinned means the activation digest, not a version
  string. The shape comparison is **profile-level**, because a consent
  carries one `shape_digest` covering what the operator was shown.

  Ordering is fail-closed and fixed: an unresolvable live graph refuses
  before anything else; tampering alarms before any equality can allow; a
  clean equality allows before scope rules are consulted. A local rebuild
  under a pin re-pins rather than alarms — every local rebuild legitimately
  takes a new activation identity, and training operators to click through
  alarms is worse than one extra consent keystroke.
  """

  @type live ::
          {:ok,
           %{
             digest: String.t(),
             graph: %{String.t() => String.t()},
             nodes: %{String.t() => %{release_digest: String.t(), integrity: :ok | :mismatch}}
           }}
          | {:error, {:incomplete, atom()}}

  @type shape_comparison :: :match | :differ | :unknown

  @type outcome ::
          :allow
          | {:allow_record, %{digest: String.t(), graph: %{String.t() => String.t()}}}
          | :needs_consent
          | :needs_consent_repin
          | {:integrity_alarm, [String.t()]}
          | {:setup_required, atom()}

  @doc """
  Evaluate one consent against the installed world.

  * `scope` — the consent's scope.
  * `granted_digest` — hash of the consent's stored activation map.
  * `live` — the verified live resolution (`Compendium.Activation.resolve_verified/2` shape).
  * `shape` — live shape digest vs the consent's `shape_digest`; `:unknown`
    is treated as `:differ` (fail closed) until the live derivation exists.
  * `local_source?` — whether the profile's source component is
    local-published (the D7 re-pin row).
  """
  @spec evaluate(
          Sanctum.Consent.scope(),
          String.t(),
          live(),
          shape_comparison(),
          boolean()
        ) :: outcome()
  def evaluate(scope, granted_digest, live, shape, local_source?)
      when scope in [:versionless, :pinned] and is_binary(granted_digest) and
             shape in [:match, :differ, :unknown] and is_boolean(local_source?) do
    case live do
      {:error, {:incomplete, reason}} ->
        {:setup_required, reason}

      {:ok, %{digest: live_digest, graph: graph, nodes: nodes}} ->
        case tampered_nodes(nodes) do
          [] -> compare(scope, granted_digest, live_digest, graph, shape, local_source?)
          tampered -> {:integrity_alarm, tampered}
        end
    end
  end

  defp compare(_scope, granted, granted, _graph, _shape, _local?), do: :allow

  defp compare(:pinned, _granted, _live, _graph, _shape, true), do: :needs_consent_repin
  defp compare(:pinned, _granted, _live, _graph, _shape, false), do: :needs_consent

  defp compare(:versionless, _granted, live_digest, graph, :match, _local?),
    do: {:allow_record, %{digest: live_digest, graph: graph}}

  defp compare(:versionless, _granted, _live, _graph, _shape, _local?), do: :needs_consent

  defp tampered_nodes(nodes) do
    nodes
    |> Enum.filter(fn {_key, %{integrity: integrity}} -> integrity == :mismatch end)
    |> Enum.map(fn {key, _} -> key end)
    |> Enum.sort()
  end
end
