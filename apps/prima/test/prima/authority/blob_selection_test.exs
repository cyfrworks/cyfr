# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Authority.BlobSelectionTest do
  @moduledoc """
  A vault resource is bound to an entry or selected from a profile of the
  edge's target; both forms parse and encode unchanged, and nothing in
  between is a vault.
  """

  use ExUnit.Case, async: true

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
end
