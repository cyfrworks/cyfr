# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.LoaderSelectionTest do
  @moduledoc """
  A selected vault resolves at root load to the entry the named profile
  binds on its own ingress — and only then: an inactive profile, a
  profile of another source, a moved binding, a projection the ingress
  cannot satisfy or a tampered target consent leave the selection in
  place, which no run can unseal. A resolved selection carries both
  identities: the borrower's binding key where the selection sits, and
  the lender's profile, consent and binding key.
  """

  use ExUnit.Case, async: false

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Prima.Authority.Transition
  alias Sanctum.Consent.Loader
  alias Sanctum.Context
  alias Sanctum.Test.ConsentFixtures
  alias Prima.JCS
  alias Prima.Test.AuthorityFixtures, as: Fixtures

  @formula "formula:local.assistant"
  @catalyst "catalyst:local.claude"
  @activation %{@formula => "sha256:act-f", @catalyst => "sha256:act-c"}
  @key_vault %{
    "entry_id" => "vault-anthropic",
    "binding_digest" => "sha256:anthropic",
    "scope" => "athanor",
    "destination" => %{"hosts" => ["api.anthropic.com"], "scheme" => "https"},
    "attach" => %{"in" => "header", "name" => "x-api-key", "template" => "{value}"},
    "projection" => %{"fields" => ["ANTHROPIC_API_KEY", "ANTHROPIC_ORG"]}
  }

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    ctx = %Context{
      user_id: "loader_selection_user",
      athanor_id: "ath_test",
      scope: :athanor,
      permissions: MapSet.new([:execute]),
      origin: :interactive
    }

    {:ok, ctx: ctx}
  end

  # The catalyst's own profile: the person bound their key here.
  defp put_catalyst!(ctx, opts \\ []) do
    status = Keyword.get(opts, :status, :active)
    vault = Keyword.get(opts, :vault, @key_vault)
    source_ref = Keyword.get(opts, :source_ref, @catalyst)

    profile = %{
      id: "prof-claude",
      kind: Keyword.get(opts, :kind, :owner),
      source_ref: source_ref,
      label: "default",
      status: status
    }

    # A bound vault's key is its place's: the lender's own ingress.
    ingress =
      if vault,
        do: %{
          "vault" => Map.put(vault, "binding_key", Blob.binding_key(source_ref, "@ingress", nil))
        },
        else: %{}

    policy =
      Jason.encode!(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          source_ref => %{"limits" => Fixtures.limits_map(), "edges" => %{"@ingress" => ingress}}
        }
      })

    refs =
      if vault,
        do: [
          %{
            binding_key: Blob.binding_key(source_ref, "@ingress", nil),
            scope: vault["scope"],
            vault_entry_id: vault["entry_id"],
            binding_digest: vault["binding_digest"]
          }
        ],
        else: []

    :ok =
      ConsentFixtures.seed_head!(ctx, profile, %{
        id: "consent-claude",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-claude",
        commit_digest: "sha256:commit-claude",
        blob_digest: Keyword.get(opts, :blob_digest, JCS.hash_binary(policy)),
        resolved_policy: policy,
        activation: %{source_ref => "sha256:act-c"},
        admitted_origins: Keyword.get(opts, :origins, [:interactive]),
        vault_refs: refs
      })
  end

  # The formula's profile: its edge to the catalyst selects the profile
  # above. Its rows are the selection's own unless `refs` names others.
  defp put_formula!(ctx, selection, origins \\ [:interactive], refs \\ nil) do
    profile = %{
      id: "prof-aqua",
      kind: :owner,
      source_ref: @formula,
      label: "default",
      status: :active
    }

    policy =
      Jason.encode!(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @formula => %{
            "limits" => Fixtures.limits_map(),
            "edges" => %{
              "@ingress" => %{"tools" => ["component.list"]},
              @catalyst => %{
                "vault" => selection,
                "egress" => %{"domains" => ["api.anthropic.com"]}
              }
            }
          },
          @catalyst => %{"limits" => Fixtures.limits_map(), "edges" => %{}}
        }
      })

    :ok =
      ConsentFixtures.seed_head!(ctx, profile, %{
        id: "consent-aqua",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-aqua",
        commit_digest: "sha256:commit-aqua",
        blob_digest: JCS.hash_binary(policy),
        resolved_policy: policy,
        activation: @activation,
        admitted_origins: origins,
        vault_refs: refs || selection_refs(@formula, @catalyst, selection)
      })

    profile
  end

  # The borrower's own row for what its edge holds: a selection names the
  # lender's label and the digest it pinned, if any.
  defp selection_refs(from, edge, %{"via" => via}) do
    [
      %{
        binding_key: Blob.binding_key(from, edge, nil),
        scope: "athanor",
        via_label: via["label"],
        binding_digest: via["binding_digest"]
      }
    ]
  end

  defp selection_refs(_from, _edge, _vault), do: []

  defp load!(ctx, profile) do
    {:ok, authority, _stamp} = load(ctx, profile)
    authority
  end

  defp load(ctx, profile) do
    {:ok, digest} = JCS.hash(@activation)

    live =
      {:ok,
       %{
         digest: digest,
         graph: @activation,
         nodes: Map.new(@activation, fn {k, d} -> {k, %{release_digest: d, integrity: :ok}} end)
       }}

    Loader.load_root(ctx, profile, live: live, live_shape_digest: nil)
  end

  defp edge_vault(authority) do
    {:ok, edge} = Blob.lookup_edge(authority.policy, @formula, @catalyst, "")
    edge.vault
  end

  test "the selection resolves to the catalyst's bound entry, and the child carries it",
       %{ctx: ctx} do
    put_catalyst!(ctx)
    profile = put_formula!(ctx, %{"via" => %{"label" => "default"}})

    authority = load!(ctx, profile)

    assert edge_vault(authority) == %{
             entry_id: "vault-anthropic",
             binding_digest: "sha256:anthropic",
             scope: "athanor",
             # The borrower's binding, where the selection sits.
             binding_key: "#{@formula}|#{@catalyst}|default",
             destination: %Prima.Destination{hosts: ["api.anthropic.com"], scheme: "https"},
             attach: %{in: "header", name: "x-api-key", template: "{value}"},
             projection: %{fields: ["ANTHROPIC_API_KEY", "ANTHROPIC_ORG"], scopes: []},
             # And the lender's: its profile, its consent and its own binding.
             lender: %{
               profile_id: "prof-claude",
               consent_id: "consent-claude",
               binding_key: "#{@catalyst}|@ingress|default"
             }
           }

    # The formula's own ingress lends nothing; its consent references no entry.
    assert authority.resources.vault == nil

    # In-chain the child gets exactly the resolved edge — the same rule as
    # any bound edge, and still never the callee's whole profile.
    {:child, child} =
      Transition.step(authority, :call, Fixtures.invoke(@catalyst, need: nil, declared_needs: []))

    assert child.profile_id == "prof-aqua"
    assert child.resources.vault.entry_id == "vault-anthropic"

    assert child.resources.vault.lender == %{
             profile_id: "prof-claude",
             consent_id: "consent-claude",
             binding_key: "#{@catalyst}|@ingress|default"
           }

    # Both identities cross the wire.
    {:ok, back} = child |> Authority.to_wire() |> Authority.from_wire()
    assert back.resources.vault.lender == child.resources.vault.lender
    assert back.resources.vault.binding_key == "#{@formula}|#{@catalyst}|default"
  end

  test "a lender's named accounts are not lent", %{ctx: ctx} do
    named =
      @key_vault
      |> Map.merge(%{
        "entry_id" => "vault-anthropic-work",
        "binding_key" => Blob.binding_key(@catalyst, "@ingress", "Work")
      })

    put_catalyst!(ctx, vault: Map.put(@key_vault, "named", %{"Work" => named}))
    profile = put_formula!(ctx, %{"via" => %{"label" => "default"}})

    vault = edge_vault(load!(ctx, profile))
    assert vault.entry_id == "vault-anthropic"
    refute Map.has_key?(vault, :named)
  end

  test "a pinned digest resolves only while the binding stands", %{ctx: ctx} do
    put_catalyst!(ctx)

    profile =
      put_formula!(ctx, %{
        "via" => %{"label" => "default", "binding_digest" => "sha256:anthropic"}
      })

    assert %{entry_id: "vault-anthropic"} = edge_vault(load!(ctx, profile))

    # The person rebinds the catalyst to a differently shaped credential.
    put_catalyst!(ctx, vault: Map.put(@key_vault, "binding_digest", "sha256:other"))

    assert %{via: %{label: "default", binding_digest: "sha256:anthropic"}} =
             edge_vault(load!(ctx, profile))
  end

  test "a selection whose row names another label or another pinned digest is refused",
       %{ctx: ctx} do
    put_catalyst!(ctx)
    selection = %{"via" => %{"label" => "default", "binding_digest" => "sha256:anthropic"}}
    [row] = selection_refs(@formula, @catalyst, selection)
    key = row.binding_key

    # The row is the borrower's binding: its label and pin are compared with
    # the blob's as an entry row's entry and digest are, before anything
    # resolves.
    for stale <- [
          %{row | via_label: "work"},
          %{row | binding_digest: "sha256:other"},
          %{row | binding_digest: nil}
        ] do
      profile = put_formula!(ctx, selection, [:interactive], [stale])

      assert {:error, {:blob_refs_mismatch, %{blob_only: blob_only, refs_only: refs_only}}} =
               load(ctx, profile)

      assert blob_only == [{:via, "athanor", key, "default", "sha256:anthropic"}]
      assert refs_only == [{:via, "athanor", key, stale.via_label, stale.binding_digest}]
    end

    # A selection with no row of its own is refused the same way.
    profile = put_formula!(ctx, selection, [:interactive], [])

    assert {:error, {:blob_refs_mismatch, %{blob_only: [{:via, "athanor", ^key, _, _}]}}} =
             load(ctx, profile)
  end

  test "a projection narrows to what both allow, and never widens", %{ctx: ctx} do
    put_catalyst!(ctx)

    selection = %{
      "via" => %{"label" => "default"},
      "projection" => %{"fields" => ["ANTHROPIC_API_KEY"]}
    }

    profile = put_formula!(ctx, selection)

    assert %{projection: %{fields: ["ANTHROPIC_API_KEY"], scopes: []}} =
             edge_vault(load!(ctx, profile))

    # A selection asking for a field the ingress does not grant resolves
    # to nothing at all.
    profile =
      put_formula!(ctx, %{
        "via" => %{"label" => "default"},
        "projection" => %{"fields" => ["SOMETHING_ELSE"]}
      })

    assert %{via: _} = edge_vault(load!(ctx, profile))

    # An ingress with no projection lends the selection's own.
    put_catalyst!(ctx, vault: Map.delete(@key_vault, "projection"))
    profile = put_formula!(ctx, selection)

    assert %{projection: %{fields: ["ANTHROPIC_API_KEY"], scopes: []}} =
             edge_vault(load!(ctx, profile))
  end

  test "a revoked profile, another source's profile, an unbound ingress and a tampered consent lend nothing",
       %{ctx: ctx} do
    selection = %{"via" => %{"label" => "default"}}
    profile = put_formula!(ctx, selection)

    put_catalyst!(ctx, status: :revoked)
    assert %{via: _} = edge_vault(load!(ctx, profile))

    put_catalyst!(ctx, status: :needs_consent)
    assert %{via: _} = edge_vault(load!(ctx, profile))

    # A profile of that label on another component is not the target's.
    put_catalyst!(ctx, source_ref: "catalyst:local.other")
    assert %{via: _} = edge_vault(load!(ctx, profile))

    # A public twin is not a lender.
    put_catalyst!(ctx, kind: :public)
    assert %{via: _} = edge_vault(load!(ctx, profile))

    # The profile is fine but binds nothing yet.
    put_catalyst!(ctx, vault: nil)
    assert %{via: _} = edge_vault(load!(ctx, profile))

    # The target's consent bytes no longer match their digest.
    put_catalyst!(ctx, blob_digest: "sha256:tampered")
    assert %{via: _} = edge_vault(load!(ctx, profile))

    # And once the profile is whole again, the same consent resolves.
    put_catalyst!(ctx)
    assert %{entry_id: "vault-anthropic"} = edge_vault(load!(ctx, profile))
  end

  test "the same entry with two binding digests is refused", %{ctx: ctx} do
    role = "agent:local.web"

    # The catalyst's own profile binds the entry under a digest that is not
    # the one the formula's bound edge carries. The conflict arrives
    # through resolution rather than through the stored refs, which is the
    # only way it can arrive at all: one consent cannot hold two reference
    # rows for one entry.
    put_catalyst!(ctx,
      vault:
        @key_vault
        |> Map.put("binding_digest", "sha256:other")
        |> Map.put("projection", %{"fields" => ["ANTHROPIC_API_KEY"]})
    )

    profile = %{
      id: "prof-aqua",
      kind: :owner,
      source_ref: @formula,
      label: "default",
      status: :active
    }

    policy =
      Jason.encode!(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @formula => %{
            "limits" => Fixtures.limits_map(),
            "edges" => %{
              "@ingress" => %{},
              @catalyst => %{
                "vault" =>
                  @key_vault
                  |> Map.put("projection", %{"fields" => ["ANTHROPIC_API_KEY"]})
                  |> Map.put("binding_key", Blob.binding_key(@formula, @catalyst, nil))
              }
            }
          },
          role => %{
            "limits" => Fixtures.limits_map(),
            "edges" => %{
              @catalyst => %{
                "vault" => %{
                  "via" => %{"label" => "default"},
                  "projection" => %{"fields" => ["ANTHROPIC_API_KEY"]}
                }
              }
            }
          },
          @catalyst => %{"limits" => Fixtures.limits_map(), "edges" => %{}}
        }
      })

    :ok =
      ConsentFixtures.seed_head!(ctx, profile, %{
        id: "consent-aqua",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-aqua",
        commit_digest: "sha256:commit-aqua",
        blob_digest: JCS.hash_binary(policy),
        resolved_policy: policy,
        activation: Map.put(@activation, role, "sha256:act-r"),
        vault_refs:
          [
            %{
              binding_key: Blob.binding_key(@formula, @catalyst, nil),
              scope: "athanor",
              vault_entry_id: "vault-anthropic",
              binding_digest: "sha256:anthropic"
            }
          ] ++ selection_refs(role, @catalyst, %{"via" => %{"label" => "default"}})
      })

    graph = Map.put(@activation, role, "sha256:act-r")
    {:ok, digest} = JCS.hash(graph)

    live =
      {:ok,
       %{
         digest: digest,
         graph: graph,
         nodes: Map.new(graph, fn {k, d} -> {k, %{release_digest: d, integrity: :ok}} end)
       }}

    assert {:error, {:inconsistent_binding_digest, "vault-anthropic"}} =
             Loader.load_root(ctx, profile,
               live: live,
               live_shape_digest: nil
             )
  end

  test "an unresolved selection is a bound child that unseals nothing", %{ctx: ctx} do
    put_catalyst!(ctx, vault: nil)
    profile = put_formula!(ctx, %{"via" => %{"label" => "default"}})
    authority = load!(ctx, profile)

    {:child, child} =
      Transition.step(authority, :call, Fixtures.invoke(@catalyst, need: nil, declared_needs: []))

    assert %Authority{cursor: {:bound, @catalyst}} = child
    assert %{via: %{label: "default"}} = child.resources.vault
    refute Blob.bound_vault?(child.resources.vault)
  end

  test "a lender whose grant does not admit the run's origin refuses the whole load, naming it",
       %{ctx: ctx} do
    # The key's own profile admits interactive alone; the formula borrowing
    # it admits programmatic as well.
    put_catalyst!(ctx, origins: [:interactive])

    profile =
      put_formula!(ctx, %{"via" => %{"label" => "default"}}, [:interactive, :programmatic])

    assert {:error,
            {:consent_required, %{profile_id: "prof-claude", current_revision: 1, shape_diff: []}}} =
             load(%{ctx | origin: :programmatic}, profile)

    # Under an origin both name, the key is lent.
    assert %{entry_id: "vault-anthropic"} = edge_vault(load!(ctx, profile))

    # Once the lender names it too, the programmatic run borrows the key.
    put_catalyst!(ctx, origins: [:interactive, :programmatic])

    assert {:ok, authority, _} = load(%{ctx | origin: :programmatic}, profile)
    assert %{entry_id: "vault-anthropic"} = edge_vault(authority)
  end
end
