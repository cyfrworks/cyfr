# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.AuthorityTest do
  use ExUnit.Case, async: true

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Authority.Blob.Edge

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

  defp blob(edges \\ nil) do
    {:ok, blob} =
      Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @formula => %{
            "limits" => limits_map(),
            "edges" =>
              edges ||
                %{
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

  defp profile(overrides \\ %{}) do
    Map.merge(
      %{
        profile_id: "prof-1",
        consent_id: "consent-1",
        source_ref: @formula,
        kind: :owner,
        invoke_mode: :open_inert,
        activation: %{@formula => "sha256:f", @catalyst => "sha256:c"}
      },
      overrides
    )
  end

  # ============================================================================
  # root/3
  # ============================================================================

  describe "root/3" do
    test "binds at the source node with exactly the ingress resources" do
      {:ok, auth} = Authority.root(profile(), blob())

      assert auth.profile_id == "prof-1"
      assert auth.consent_id == "consent-1"
      assert auth.source_ref == @formula
      assert auth.profile_kind == :owner
      assert auth.invoke_mode == :open_inert
      assert auth.cursor == {:bound, @formula}
      assert %Edge{vault: nil, egress: nil, tools: []} = auth.resources
      assert auth.chain == [@formula]
      assert auth.depth == 0
      assert Authority.bound?(auth)
      assert Authority.current_node(auth) == {:ok, @formula}
    end

    test "clamps the blob by construction and sizes the budget from the clamped root node" do
      ceiling = %{timeout: "1m", max_concurrent_tasks: 5}
      {:ok, auth} = Authority.root(profile(), blob(), ceiling: ceiling)

      limits = Authority.limits(auth)
      assert limits.timeout == "1m"
      assert limits.max_concurrent_tasks == 5
      assert Authority.budget(auth) == %{in_flight: 0, cap: 5}
    end

    test "fails closed without a source node" do
      assert {:error, {:unknown_source_node, "formula:local.ghost"}} =
               Authority.root(profile(%{source_ref: "formula:local.ghost"}), blob())
    end

    test "fails closed without an @ingress edge" do
      no_ingress = blob(%{})

      assert {:error, {:missing_ingress, @formula}} =
               Authority.root(profile(), no_ingress)
    end

    test "public profiles must be edge_only" do
      assert {:error, {:invalid_profile, :public_requires_edge_only}} =
               Authority.root(profile(%{kind: :public}), blob())

      assert {:ok, auth} =
               Authority.root(profile(%{kind: :public, invoke_mode: :edge_only}), blob())

      assert auth.profile_kind == :public
      assert auth.invoke_mode == :edge_only
    end

    test "rejects malformed profiles" do
      assert {:error, {:invalid_profile, :profile_id}} =
               Authority.root(profile(%{profile_id: ""}), blob())

      assert {:error, {:invalid_profile, :kind}} =
               Authority.root(profile(%{kind: :admin}), blob())

      assert {:error, {:invalid_profile, :invoke_mode}} =
               Authority.root(profile(%{invoke_mode: :always}), blob())

      assert {:error, {:invalid_profile, :activation}} =
               Authority.root(profile(%{activation: %{@formula => 42}}), blob())

      assert {:error, {:invalid_profile, :not_a_map}} = Authority.root(nil, blob())
    end
  end

  # ============================================================================
  # Child construction
  # ============================================================================

  describe "child construction" do
    setup do
      {:ok, auth} = Authority.root(profile(), blob())
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
      assert Authority.try_acquire_invoke(child) == :ok
      assert Authority.budget(auth).in_flight == 1
    end

    test "unbound_child is structurally zero", %{auth: auth} do
      child = Authority.unbound_child(auth, "formula:evil.corp.tool")

      assert child.policy == :none
      assert child.resources == :none
      assert child.cursor == :unbound
      assert child.profile_id == nil
      assert child.consent_id == nil
      assert child.source_ref == nil
      assert child.profile_kind == nil
      assert child.activation == %{}
      assert child.invoke_mode == :open_inert
      assert child.chain == [@formula, "formula:evil.corp.tool"]
      assert child.depth == 1
      assert Authority.limits(child) == Authority.zero_limits()
      # Still spends the root's budget.
      assert child.budget == auth.budget
    end

    test "unbound is absorbing", %{auth: auth} do
      child = Authority.unbound_child(auth, "formula:evil.corp.tool")
      grandchild = Authority.unbound_child(child, "catalyst:local.http")

      assert grandchild.policy == :none
      assert grandchild.cursor == :unbound
      assert grandchild.chain == [@formula, "formula:evil.corp.tool", "catalyst:local.http"]
      assert grandchild.depth == 2
    end

    test "self_child preserves cursor and resources (D2)", %{auth: auth} do
      child = Authority.self_child(auth, @formula)

      assert child.cursor == auth.cursor
      assert child.resources == auth.resources
      assert child.policy == auth.policy
      assert child.chain == [@formula, @formula]
      assert child.depth == 1
    end
  end

  # ============================================================================
  # Budget + depth
  # ============================================================================

  describe "budget and depth" do
    test "budget exhausts at the root cap and release re-admits" do
      ceiling = %{max_concurrent_tasks: 2}
      {:ok, auth} = Authority.root(profile(), blob(), ceiling: ceiling)

      assert Authority.try_acquire_invoke(auth) == :ok
      assert Authority.try_acquire_invoke(auth) == :ok
      assert Authority.try_acquire_invoke(auth) == {:error, :invoke_budget_exhausted}
      assert Authority.budget(auth) == %{in_flight: 2, cap: 2}

      assert Authority.release_invoke(auth) == :ok
      assert Authority.try_acquire_invoke(auth) == :ok
    end

    test "depth_cap/0 is 8" do
      assert Authority.depth_cap() == 8
    end

    test "a bound Authority without a blob is unrepresentable in limits/1" do
      # Fail-closed: only the constructors build Authorities; a hand-forged
      # bound cursor with no blob has no limits clause.
      forged = %{Authority.zero() | cursor: {:bound, @formula}}
      assert_raise FunctionClauseError, fn -> Authority.limits(forged) end
    end
  end
end
