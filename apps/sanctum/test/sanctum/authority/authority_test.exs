# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.AuthorityTest do
  use ExUnit.Case, async: true

  alias Prima.Authority
  alias Prima.Authority.Blob

  @formula "formula:local.daily-report"
  @catalyst "catalyst:supabase.com.database"

  defp limits_map(overrides \\ %{}) do
    Map.merge(
      %{
        "timeout" => "15m",
        "max_memory_bytes" => 67_108_864,
        "max_request_size" => 1_048_576,
        "max_response_size" => 5_242_880,
        "rate_limit" => %{"requests" => 100, "window" => "1m"},
        "max_concurrent_tasks" => 30,
        "batch_timeout" => "5m"
      },
      overrides
    )
  end

  defp blob do
    {:ok, blob} =
      Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @formula => %{
            "limits" => limits_map(),
            "edges" => %{
              "@ingress" => %{},
              "#{@catalyst}|source" => %{
                "vault" => %{"entry_id" => "vault-1", "binding_digest" => "sha256:aaa"},
                "egress" => %{"domains" => ["prod.supabase.co"]}
              }
            }
          },
          @catalyst => %{"limits" => limits_map(%{"timeout" => "30s"}), "edges" => %{}}
        }
      })

    blob
  end

  defp profile do
    %{
      profile_id: "prof-1",
      consent_id: "consent-1",
      source_ref: @formula,
      kind: :owner,
      invoke_mode: :open_inert,
      activation: %{@formula => "sha256:f", @catalyst => "sha256:c"}
    }
  end

  # ============================================================================
  # root/3
  # ============================================================================

  describe "root/3" do
    test "clamps the blob by construction and sizes the budget from the clamped root node" do
      ceiling = %{timeout: "1m", max_concurrent_tasks: 5}
      {:ok, auth} = Authority.root(profile(), blob(), ceiling: ceiling)

      limits = Authority.limits(auth)
      assert limits.timeout == "1m"
      assert limits.max_concurrent_tasks == 5
      assert Sanctum.Authority.budget(auth) == %{in_flight: 0, cap: 5}
    end
  end

  # ============================================================================
  # Child construction
  # ============================================================================

  describe "child construction" do
    setup do
      {:ok, auth} =
        Authority.root(profile(), blob(), ceiling: Sanctum.Policy.Ceiling.platform_ceiling())

      {:ok, edge} = Blob.lookup_edge(auth.policy, @formula, @catalyst, "source")
      %{auth: auth, edge: edge}
    end

    test "bound_child carries exactly the selected edge", %{auth: auth, edge: edge} do
      child = Authority.bound_child(auth, @catalyst, edge)

      assert child.cursor == {:bound, @catalyst}
      assert child.resources == edge
      assert child.resources.vault.entry_id == "vault-1"
      assert child.chain == [@formula, @catalyst]
      assert child.depth == 1
      # Identity, blob and activation ride along unchanged.
      assert child.profile_id == auth.profile_id
      assert child.policy == auth.policy
      assert child.activation == auth.activation
      # The child runs under the CALLEE's own limits.
      assert Authority.limits(child).timeout == "30s"
      # Root-keyed budget: same atomics ref, not a copy.
      assert child.budget == auth.budget
      assert Sanctum.Authority.try_acquire_invoke(child) == :ok
      assert Sanctum.Authority.budget(auth).in_flight == 1
    end
  end

  # ============================================================================
  # Budget
  # ============================================================================

  describe "budget" do
    test "budget exhausts at the root cap and release re-admits" do
      ceiling = %{max_concurrent_tasks: 2}
      {:ok, auth} = Authority.root(profile(), blob(), ceiling: ceiling)

      assert Sanctum.Authority.try_acquire_invoke(auth) == :ok
      assert Sanctum.Authority.try_acquire_invoke(auth) == :ok
      assert Sanctum.Authority.try_acquire_invoke(auth) == {:error, :invoke_budget_exhausted}
      assert Sanctum.Authority.budget(auth) == %{in_flight: 2, cap: 2}

      assert Sanctum.Authority.release_invoke(auth) == :ok
      assert Sanctum.Authority.try_acquire_invoke(auth) == :ok
    end
  end
end
