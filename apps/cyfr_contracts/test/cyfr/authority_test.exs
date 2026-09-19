# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Cyfr.AuthorityTest do
  use ExUnit.Case, async: true

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob
  alias Cyfr.Authority.Blob.Edge

  @formula "formula:local.daily-report"
  @catalyst "catalyst:supabase.com.database"
  @ceiling Cyfr.Limits.Ceiling.lowered(%{})

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
      {:ok, auth} = Authority.root(profile(), blob(), ceiling: @ceiling)

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

    test "fails closed without a source node" do
      assert {:error, {:unknown_source_node, "formula:local.ghost"}} =
               Authority.root(profile(%{source_ref: "formula:local.ghost"}), blob(),
                 ceiling: @ceiling
               )
    end

    test "fails closed without an @ingress edge" do
      no_ingress = blob(%{})

      assert {:error, {:missing_ingress, @formula}} =
               Authority.root(profile(), no_ingress, ceiling: @ceiling)
    end

    test "public profiles must be edge_only" do
      assert {:error, {:invalid_profile, :public_requires_edge_only}} =
               Authority.root(profile(%{kind: :public}), blob(), ceiling: @ceiling)

      assert {:ok, auth} =
               Authority.root(profile(%{kind: :public, invoke_mode: :edge_only}), blob(),
                 ceiling: @ceiling
               )

      assert auth.profile_kind == :public
      assert auth.invoke_mode == :edge_only
    end

    test "rejects malformed profiles" do
      assert {:error, {:invalid_profile, :profile_id}} =
               Authority.root(profile(%{profile_id: ""}), blob(), ceiling: @ceiling)

      assert {:error, {:invalid_profile, :kind}} =
               Authority.root(profile(%{kind: :admin}), blob(), ceiling: @ceiling)

      assert {:error, {:invalid_profile, :invoke_mode}} =
               Authority.root(profile(%{invoke_mode: :always}), blob(), ceiling: @ceiling)

      assert {:error, {:invalid_profile, :activation}} =
               Authority.root(profile(%{activation: %{@formula => 42}}), blob(),
                 ceiling: @ceiling
               )

      assert {:error, {:invalid_profile, :not_a_map}} =
               Authority.root(nil, blob(), ceiling: @ceiling)
    end
  end

  # ============================================================================
  # Child construction
  # ============================================================================

  describe "child construction" do
    setup do
      {:ok, auth} = Authority.root(profile(), blob(), ceiling: @ceiling)
      %{auth: auth}
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

    test "self_child preserves cursor and resources", %{auth: auth} do
      child = Authority.self_child(auth, @formula)

      assert child.cursor == auth.cursor
      assert child.resources == auth.resources
      assert child.policy == auth.policy
      assert child.chain == [@formula, @formula]
      assert child.depth == 1
    end
  end

  # ============================================================================
  # Depth
  # ============================================================================

  describe "depth" do
    test "depth_cap/0 is 8" do
      assert Authority.depth_cap() == 8
    end

    test "a bound Authority without a blob is unrepresentable in limits/1" do
      # Fail-closed: the constructors never pair a bound cursor with no
      # blob, and a literal one the compiler refuses at the call site. The
      # wire is where such a pairing can still arrive: `from_wire/1` reads
      # a bound cursor beside a null policy, and `limits/1` has no clause
      # for what it hands back.
      wire =
        Authority.zero()
        |> Authority.to_wire()
        |> Map.put("cursor", %{"bound" => @formula})

      assert {:ok, decoded} = Authority.from_wire(wire)
      assert_raise FunctionClauseError, fn -> Authority.limits(decoded) end
      assert decoded.policy == :none
      assert decoded.cursor == {:bound, @formula}
    end
  end

  # ============================================================================
  # Wire
  # ============================================================================

  # The budget crosses as its id alone.
  defp decoded(auth), do: %{auth | budget: %{auth.budget | cap: 0}}

  describe "from_wire/1" do
    setup do
      {:ok, root} = Authority.root(profile(), blob(), ceiling: @ceiling)
      {:ok, edge} = Blob.lookup_edge(root.policy, @formula, @catalyst, "source")
      %{root: root, child: Authority.bound_child(root, @catalyst, edge)}
    end

    test "reads back a root, a bound child, an unbound child and the zero authority",
         %{root: root, child: child} do
      for auth <- [root, child, Authority.unbound_child(child, "formula:evil.corp.tool")] do
        wire = Authority.to_wire(auth)
        assert {:ok, back} = Authority.from_wire(wire)
        assert back == decoded(auth)
        assert {:ok, ^back} = wire |> Jason.encode!() |> Jason.decode!() |> Authority.from_wire()
        assert Authority.limits(back) == Authority.limits(auth)
      end

      zero = Authority.zero()
      assert {:ok, back} = Authority.from_wire(Authority.to_wire(zero))
      assert back == decoded(zero)
    end

    test "reads an absent member as nil, as an assignment carries the map", %{child: child} do
      unbound = Authority.unbound_child(child, "formula:evil.corp.tool")
      sparse = unbound |> Authority.to_wire() |> Map.reject(fn {_key, value} -> is_nil(value) end)

      refute Map.has_key?(sparse, "profile_id")
      refute Map.has_key?(sparse, "policy")
      assert {:ok, back} = Authority.from_wire(sparse)
      assert back == decoded(unbound)
    end

    test "a decoded budget charges nothing: its cap is 0, its id the root's", %{child: child} do
      assert {:ok, %{budget: budget}} = Authority.from_wire(Authority.to_wire(child))
      assert budget == %Authority.Budget{id: child.budget.id, cap: 0}
    end

    test "fails closed on a malformed map", %{child: child} do
      wire = Authority.to_wire(child)

      assert {:error, {:invalid_wire_keys, ["extra"]}} =
               Authority.from_wire(Map.put(wire, "extra", 1))

      assert {:error, {:invalid_wire_budget, nil}} =
               Authority.from_wire(Map.delete(wire, "budget"))

      assert {:error, {:invalid_wire_budget, _}} =
               Authority.from_wire(%{wire | "budget" => %{"id" => "x", "cap" => 1}})

      assert {:error, {:invalid_wire_cursor, _}} =
               Authority.from_wire(%{wire | "cursor" => "bound"})

      assert {:error, {:invalid_wire_value, _}} =
               Authority.from_wire(%{wire | "invoke_mode" => "anything"})

      assert {:error, {:invalid_wire_value, "profile_id"}} =
               Authority.from_wire(%{wire | "profile_id" => 7})

      assert {:error, {:invalid_wire_chain, _}} = Authority.from_wire(%{wire | "chain" => [""]})

      assert {:error, {:invalid_wire_activation, _}} =
               Authority.from_wire(%{wire | "activation" => %{"a" => 1}})

      bad_policy = put_in(wire, ["policy", "canonical"], "jcs-9")
      assert {:error, {:invalid_wire_policy, _}} = Authority.from_wire(bad_policy)

      assert {:error, {:invalid_wire_resources, _}} =
               Authority.from_wire(%{wire | "resources" => "all"})

      assert {:error, {:invalid_wire, _}} = Authority.from_wire("not a map")
    end

    test "cannot hand back an authority past the depth cap", %{child: child} do
      wire = Authority.to_wire(child)

      assert {:error, {:invalid_wire_depth, _}} =
               Authority.from_wire(%{wire | "depth" => Authority.depth_cap() + 1})

      assert {:error, {:invalid_wire_depth, _}} = Authority.from_wire(%{wire | "depth" => -1})
      assert {:ok, _} = Authority.from_wire(%{wire | "depth" => Authority.depth_cap()})
    end
  end
end
