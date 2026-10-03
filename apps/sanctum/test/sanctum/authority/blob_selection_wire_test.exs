# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Authority.BlobSelectionWireTest do
  @moduledoc """
  A vault resource bound to an entry or selected from a profile of the
  edge's target travels the wire unchanged, both identities of a resolved
  selection included: the borrower's binding key where it sits and the
  lender's profile, consent and binding key.
  """

  use ExUnit.Case, async: false

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Prima.Test.AuthorityFixtures, as: Fixtures

  @formula "formula:local.assistant"
  @catalyst "catalyst:local.claude"

  defp graph(vault) do
    %{
      "canonical" => "jcs-1",
      "nodes" => %{
        @formula => %{
          "limits" => Fixtures.limits_map(),
          "edges" => %{
            "@ingress" => %{},
            @catalyst => %{"vault" => vault, "egress" => %{"domains" => ["api.anthropic.com"]}}
          }
        },
        @catalyst => %{"limits" => Fixtures.limits_map(), "edges" => %{}}
      }
    }
  end

  test "an authority whose edge selects a vault survives the wire" do
    {:ok, blob} = Blob.parse(graph(%{"via" => %{"label" => "default"}}))

    profile = %{
      profile_id: "prof-aqua",
      consent_id: "consent-aqua",
      source_ref: @formula,
      kind: :owner,
      invoke_mode: :open_inert,
      activation: %{@formula => "sha256:f", @catalyst => "sha256:c"}
    }

    {:ok, root} =
      Authority.root(profile, blob, ceiling: Sanctum.Policy.Ceiling.platform_ceiling())

    {:ok, edge} = Blob.lookup_edge(root.policy, @formula, @catalyst, "")
    child = Authority.bound_child(root, @catalyst, edge)

    assert {:ok, back} = Authority.from_wire(Authority.to_wire(child))

    assert back.resources.vault == %{
             via: %{label: "default", binding_digest: nil},
             projection: nil
           }

    assert back.policy == root.policy
  end

  test "a bound vault's lender survives parse, encode and the wire" do
    lender = %{
      "profile_id" => "prof-claude",
      "consent_id" => "consent-claude",
      "binding_key" => Blob.binding_key(@catalyst, "@ingress", nil)
    }

    bound =
      Fixtures.bound_vault(@formula, @catalyst, "vault-1", "sha256:key",
        destination: Fixtures.destination_map(["api.anthropic.com"]),
        attach: %{"in" => "header", "name" => "x-api-key", "template" => "{value}"},
        projection: %{"fields" => ["ANTHROPIC_API_KEY"]},
        lender: lender
      )

    assert {:ok, blob} = Blob.parse(graph(bound))
    assert {:ok, edge} = Blob.lookup_edge(blob, @formula, @catalyst, "")

    assert %{
             entry_id: "vault-1",
             binding_digest: "sha256:key",
             scope: "athanor",
             binding_key: "formula:local.assistant|catalyst:local.claude|default",
             attach: %{in: "header", name: "x-api-key", template: "{value}"},
             projection: %{fields: ["ANTHROPIC_API_KEY"], scopes: []},
             lender: %{
               profile_id: "prof-claude",
               consent_id: "consent-claude",
               binding_key: "catalyst:local.claude|@ingress|default"
             }
           } = edge.vault

    assert Blob.parse(Blob.to_map(blob)) == {:ok, blob}

    profile = %{
      profile_id: "prof-aqua",
      consent_id: "consent-aqua",
      source_ref: @formula,
      kind: :owner,
      invoke_mode: :open_inert,
      activation: %{@formula => "sha256:f", @catalyst => "sha256:c"}
    }

    {:ok, root} =
      Authority.root(profile, blob, ceiling: Sanctum.Policy.Ceiling.platform_ceiling())

    {:ok, edge} = Blob.lookup_edge(root.policy, @formula, @catalyst, "")
    child = Authority.bound_child(root, @catalyst, edge)
    assert {:ok, back} = Authority.from_wire(Authority.to_wire(child))

    assert back.resources.vault.lender == %{
             profile_id: "prof-claude",
             consent_id: "consent-claude",
             binding_key: "catalyst:local.claude|@ingress|default"
           }

    assert back.resources.vault.binding_key == edge.vault.binding_key
  end
end
