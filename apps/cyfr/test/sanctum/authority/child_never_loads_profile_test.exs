# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.ChildNeverLoadsProfileTest do
  use ExUnit.Case, async: true

  alias Sanctum.Authority
  alias Sanctum.Authority.Transition
  alias Sanctum.Test.AuthorityFixtures, as: Fixtures

  # §6 "Child never loads a callee profile": a shared entry point that
  # resolves the callee's own profile is precisely the confused-deputy
  # surface the redesign removes. In the transition relation this is
  # structural — step/3 takes (authority, function, target) and nothing
  # else, so there is no profile store it COULD consult — and behavioral:
  # even when the callee has its own profile with broader grants, the child
  # gets exactly the caller's edge.

  @catalyst "catalyst:supabase.com.database"

  test "a callee with its own (broader) profile still receives only the caller's edge" do
    # The supabase catalyst also has a standalone profile in this deployment,
    # consented with far broader authority. It must be invisible in-chain.
    callee_own_profile =
      Fixtures.profile(%{
        profile_id: "prof-supabase-standalone",
        consent_id: "consent-standalone",
        source_ref: @catalyst,
        activation: %{@catalyst => "sha256:act-catalyst"}
      })

    # It is loadable as a ROOT (external ingress)…
    {:ok, direct_blob} =
      Sanctum.Authority.Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @catalyst => %{
            "limits" => Fixtures.limits_map(),
            "edges" => %{
              "@ingress" => %{
                "vault" => %{"entry_id" => "vault-admin", "binding_digest" => "sha256:admin"},
                "tools" => ["storage.read", "storage.write", "component.search"]
              }
            }
          }
        }
      })

    {:ok, direct} = Authority.root(callee_own_profile, direct_blob)
    assert direct.resources.vault.entry_id == "vault-admin"

    # …but in-chain, the child transition uses the CALLER's edge only.
    caller = Fixtures.root!()

    {:child, child} =
      Transition.step(
        caller,
        :call,
        Fixtures.invoke(@catalyst, need: "source", declared_needs: Fixtures.formula_needs())
      )

    assert child.profile_id == caller.profile_id
    assert child.consent_id == caller.consent_id
    assert child.resources.vault.entry_id == "vault-source"
    refute child.resources.vault.entry_id == "vault-admin"
    assert {:deny, :tool_not_granted} =
             Transition.step(child, :call, {:tool, %{tool: "component", action: "search"}})
  end

  test "step/3 has no way to be handed a profile store" do
    # Structural half of the gate: the relation's entire input surface is
    # (authority, guest_fn, target) — pinned here so a future "convenience"
    # parameter shows up as a red test.
    assert {:module, Transition} = Code.ensure_loaded(Transition)
    assert function_exported?(Transition, :step, 3)
    refute function_exported?(Transition, :step, 4)
  end
end
