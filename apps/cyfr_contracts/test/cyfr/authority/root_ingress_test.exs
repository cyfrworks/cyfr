# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Cyfr.Authority.RootIngressTest do
  use ExUnit.Case, async: true

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob
  alias Cyfr.Authority.Transition
  alias Cyfr.Test.AuthorityFixtures, as: Fixtures

  # Direct catalyst invocation receives resources through the synthetic @ingress edge.

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
        blob,
        ceiling: Fixtures.ceiling()
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
               blob,
               ceiling: Fixtures.ceiling()
             )
  end
end
