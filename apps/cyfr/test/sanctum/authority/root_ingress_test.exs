# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.RootIngressTest do
  use ExUnit.Case, async: true

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Authority.Transition
  alias Sanctum.Test.AuthorityFixtures, as: Fixtures

  # §6 "Root ingress": authority always comes from an edge — a directly
  # invoked catalyst receives its resources exactly as a nested one does,
  # through the synthetic @ingress edge. One rule, no new entity.

  @catalyst "catalyst:supabase.com.database"

  defp catalyst_rooted_blob do
    {:ok, blob} =
      Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @catalyst => %{
            "limits" => Fixtures.limits_map(%{"timeout" => "30s"}),
            "edges" => %{
              "@ingress" => %{
                "vault" => %{
                  "entry_id" => "vault-direct",
                  "binding_digest" => "sha256:bind",
                  "projection" => %{"fields" => ["url", "anon_key"]}
                },
                "egress" => %{"domains" => ["prod.supabase.co"]},
                "tools" => ["storage.read"]
              }
            }
          }
        }
      })

    blob
  end

  test "a directly invoked catalyst receives exactly its @ingress resources" do
    blob = catalyst_rooted_blob()

    {:ok, auth} =
      Authority.root(
        Fixtures.profile(%{source_ref: @catalyst, activation: %{@catalyst => "sha256:c"}}),
        blob
      )

    {:ok, ingress_edge} = Blob.ingress(auth.policy, @catalyst)

    assert auth.cursor == {:bound, @catalyst}
    assert auth.resources == ingress_edge
    assert auth.resources.vault.entry_id == "vault-direct"
    assert auth.resources.egress.domains == ["prod.supabase.co"]
    assert Authority.limits(auth).timeout == "30s"

    # And those resources are live through the transition relation.
    assert {:allow_tool, {:tools, "storage.read"}} =
             Transition.step(auth, :call, {:tool, %{tool: "storage", action: "read"}})
  end

  test "no @ingress edge, no root authority — even with other edges present" do
    {:ok, blob} =
      Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @catalyst => %{
            "limits" => Fixtures.limits_map(),
            "edges" => %{@catalyst => %{"tools" => ["storage.read"]}}
          }
        }
      })

    assert {:error, {:missing_ingress, @catalyst}} =
             Authority.root(
               Fixtures.profile(%{source_ref: @catalyst, activation: %{@catalyst => "sha256:c"}}),
               blob
             )
  end
end
