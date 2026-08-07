# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Opus.AuthorityShim do
  @moduledoc """
  The single home of every legacy allowance the authority cutover needs.

  While both execution paths exist, an authority-rooted execution still
  flows through machinery built for `%Sanctum.Policy{}` — the HTTP,
  storage and formula import handlers all consume its predicates. Rather
  than teach each handler a second vocabulary that dies with the
  migration, this module materializes a policy struct from the one edge
  and node-limit set the Authority carries, so the handlers stay
  untouched and every legacy concession is deletable in one place.

  Everything here disappears when the legacy path does; a test will
  assert this module no longer loads.
  """

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob

  @doc """
  Materialize the legacy policy equivalent of the Authority's current
  position: its edge's resources plus its node's clamped limits.

  Resource semantics are the edge's, verbatim — empty lists deny, and the
  scheme list is always explicit (unlike stored policies, whose nil means
  unchecked). An unbound authority has no resources, so everything denies
  and the zero limits apply.
  """
  @spec policy_from_edge(Authority.t()) :: Sanctum.Policy.t()
  def policy_from_edge(%Authority{} = authority) do
    limits = Authority.limits(authority)
    edge = edge_resources(authority)

    %Sanctum.Policy{
      allowed_domains: egress(edge, :domains),
      allowed_methods: egress(edge, :methods),
      allowed_private_ips: egress(edge, :private_ips),
      allowed_schemes: egress(edge, :schemes),
      allowed_paths: storage(edge, :paths),
      allowed_actions: storage(edge, :actions),
      allowed_tools: tools(edge),
      timeout: limits.timeout,
      max_memory_bytes: limits.max_memory_bytes,
      max_request_size: limits.max_request_size,
      max_response_size: limits.max_response_size,
      rate_limit: limits.rate_limit,
      max_concurrent_tasks: limits.max_concurrent_tasks,
      batch_timeout: limits.batch_timeout,
      is_public: false
    }
  end

  defp edge_resources(%Authority{resources: %Blob.Edge{} = edge}), do: edge
  defp edge_resources(%Authority{resources: :none}), do: nil

  defp egress(nil, _key), do: []
  defp egress(%Blob.Edge{egress: nil}, _key), do: []
  defp egress(%Blob.Edge{egress: egress}, key), do: Map.get(egress, key, [])

  defp storage(nil, _key), do: []
  defp storage(%Blob.Edge{storage: nil}, _key), do: []
  defp storage(%Blob.Edge{storage: storage}, key), do: Map.get(storage, key, [])

  defp tools(nil), do: []
  defp tools(%Blob.Edge{tools: tools}), do: tools
end
