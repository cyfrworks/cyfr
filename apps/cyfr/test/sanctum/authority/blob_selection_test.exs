# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Authority.BlobSelectionTest do
  @moduledoc """
  A vault resource is bound to an entry or selected from a profile of the
  edge's target; both forms parse, encode and travel the wire unchanged,
  and nothing in between is a vault.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Test.AuthorityFixtures, as: Fixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

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

  test "a selected vault parses, encodes and reads as unbound" do
    selected = %{
      "via" => %{"label" => "default", "binding_digest" => "sha256:key"},
      "projection" => %{"fields" => ["ANTHROPIC_API_KEY"]}
    }

    assert {:ok, blob} = Blob.parse(graph(selected))
    assert {:ok, edge} = Blob.lookup_edge(blob, @formula, @catalyst, "")

    assert edge.vault == %{
             via: %{label: "default", binding_digest: "sha256:key"},
             projection: %{fields: ["ANTHROPIC_API_KEY"], scopes: []}
           }

    refute Blob.bound_vault?(edge.vault)
    assert Blob.bound_vault?(%{entry_id: "e", binding_digest: "d", projection: nil})
    refute Blob.bound_vault?(nil)

    assert Blob.parse(Blob.to_map(blob)) == {:ok, blob}

    # An unpinned selection omits the digest on the way out.
    unpinned = %{"via" => %{"label" => "default"}}
    assert {:ok, blob} = Blob.parse(graph(unpinned))
    assert {:ok, edge} = Blob.lookup_edge(blob, @formula, @catalyst, "")

    assert edge.vault == %{
             via: %{label: "default", binding_digest: nil},
             projection: nil
           }

    assert Blob.edge_to_map(edge)["vault"] == unpinned
  end

  test "a vault is bound or selected, never both and never something else" do
    mixed = %{"entry_id" => "e", "binding_digest" => "d", "via" => %{"profile_id" => "p"}}

    assert {:error, {:invalid_resource, @formula, @catalyst, :vault, _}} =
             Blob.parse(graph(mixed))

    assert {:error, {:invalid_resource, _, _, :vault, _}} =
             Blob.parse(graph(%{"via" => %{"label" => ""}}))

    assert {:error, {:invalid_resource, _, _, :vault, _}} =
             Blob.parse(graph(%{"via" => %{"label" => "p", "extra" => 1}}))

    assert {:error, {:invalid_resource, _, _, :vault, _}} = Blob.parse(graph(%{"via" => "p"}))
  end

  test "edge_target/1 and map_edges/2 walk the graph as the loader does" do
    assert Blob.edge_target("@ingress") == :ingress
    assert Blob.edge_target(@catalyst) == {:ok, @catalyst}
    assert Blob.edge_target(@catalyst <> "|api_key") == {:ok, @catalyst}

    {:ok, blob} = Blob.parse(graph(%{"via" => %{"label" => "default"}}))

    resolved =
      Blob.map_edges(blob, fn _node, _key, edge ->
        case edge.vault do
          %{via: _} -> %{edge | vault: %{entry_id: "e", binding_digest: "d", projection: nil}}
          _ -> edge
        end
      end)

    assert {:ok, %{vault: %{entry_id: "e"}}} = Blob.lookup_edge(resolved, @formula, @catalyst, "")
    assert {:ok, %{vault: nil}} = Blob.ingress(resolved, @formula)
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

    {:ok, root} = Authority.root(profile, blob)
    {:ok, edge} = Blob.lookup_edge(root.policy, @formula, @catalyst, "")
    child = Fixtures.reserve!(Authority.bound_child(root, @catalyst, edge))

    assert {:ok, back} = Authority.from_wire(Authority.to_wire(child))

    assert back.resources.vault == %{
             via: %{label: "default", binding_digest: nil},
             projection: nil
           }

    assert back.policy == root.policy
  end

  test "a bound vault's lender survives parse, encode and the wire" do
    bound = %{
      "entry_id" => "vault-1",
      "binding_digest" => "sha256:key",
      "projection" => %{"fields" => ["ANTHROPIC_API_KEY"]},
      "lender" => %{"profile_id" => "prof-claude", "consent_id" => "consent-claude"}
    }

    assert {:ok, blob} = Blob.parse(graph(bound))
    assert {:ok, edge} = Blob.lookup_edge(blob, @formula, @catalyst, "")

    assert edge.vault == %{
             entry_id: "vault-1",
             binding_digest: "sha256:key",
             projection: %{fields: ["ANTHROPIC_API_KEY"], scopes: []},
             lender: %{profile_id: "prof-claude", consent_id: "consent-claude"}
           }

    assert Blob.parse(Blob.to_map(blob)) == {:ok, blob}

    profile = %{
      profile_id: "prof-aqua",
      consent_id: "consent-aqua",
      source_ref: @formula,
      kind: :owner,
      invoke_mode: :open_inert,
      activation: %{@formula => "sha256:f", @catalyst => "sha256:c"}
    }

    {:ok, root} = Authority.root(profile, blob)
    {:ok, edge} = Blob.lookup_edge(root.policy, @formula, @catalyst, "")
    child = Fixtures.reserve!(Authority.bound_child(root, @catalyst, edge))
    assert {:ok, back} = Authority.from_wire(Authority.to_wire(child))

    assert back.resources.vault.lender == %{
             profile_id: "prof-claude",
             consent_id: "consent-claude"
           }
  end
end
