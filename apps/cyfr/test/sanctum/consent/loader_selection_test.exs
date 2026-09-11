# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.LoaderSelectionTest do
  @moduledoc """
  A selected vault resolves at root load to the entry the named profile
  binds on its own ingress — and only then: an inactive profile, a
  profile of another source, a moved binding, a projection the ingress
  cannot satisfy or a tampered target consent leave the selection in
  place, which no run can unseal.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Authority.Transition
  alias Sanctum.Consent.Loader
  alias Sanctum.Consent.Source
  alias Sanctum.Context
  alias Sanctum.JCS
  alias Sanctum.Test.AuthorityFixtures, as: Fixtures

  @formula "formula:local.assistant"
  @catalyst "catalyst:local.claude"
  @activation %{@formula => "sha256:act-f", @catalyst => "sha256:act-c"}
  @key_vault %{
    "entry_id" => "vault-anthropic",
    "binding_digest" => "sha256:anthropic",
    "projection" => %{"fields" => ["ANTHROPIC_API_KEY", "ANTHROPIC_ORG"]}
  }

  setup do
    start_supervised!(Source.Memory)

    ctx = %Context{
      user_id: "loader_selection_user",
      athanor_id: "ath_test",
      scope: :athanor,
      permissions: MapSet.new([:execute])
    }

    {:ok, ctx: ctx}
  end

  # The catalyst's own profile: the person bound their key here.
  defp put_catalyst!(ctx, opts \\ []) do
    status = Keyword.get(opts, :status, :active)
    vault = Keyword.get(opts, :vault, @key_vault)
    source_ref = Keyword.get(opts, :source_ref, @catalyst)

    :ok =
      Source.Memory.put_profile(ctx, %{
        id: "prof-claude",
        kind: Keyword.get(opts, :kind, :owner),
        source_ref: source_ref,
        label: "default",
        status: status
      })

    ingress = if vault, do: %{"vault" => vault}, else: %{}

    policy =
      Jason.encode!(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          source_ref => %{"limits" => Fixtures.limits_map(), "edges" => %{"@ingress" => ingress}}
        }
      })

    refs =
      if vault,
        do: [%{vault_entry_id: vault["entry_id"], binding_digest: vault["binding_digest"]}],
        else: []

    :ok =
      Source.Memory.put_head_consent(ctx, "prof-claude", %{
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
        vault_refs: refs
      })
  end

  # The formula's profile: its edge to the catalyst selects the profile above.
  defp put_formula!(ctx, selection) do
    :ok =
      Source.Memory.put_profile(ctx, %{
        id: "prof-aqua",
        kind: :owner,
        source_ref: @formula,
        label: "default",
        status: :active
      })

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
      Source.Memory.put_head_consent(ctx, "prof-aqua", %{
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
        vault_refs: []
      })

    %{id: "prof-aqua", kind: :owner, source_ref: @formula, label: "default", status: :active}
  end

  defp load!(ctx, profile) do
    {:ok, digest} = JCS.hash(@activation)

    live =
      {:ok,
       %{
         digest: digest,
         graph: @activation,
         nodes: Map.new(@activation, fn {k, d} -> {k, %{release_digest: d, integrity: :ok}} end)
       }}

    {:ok, authority, _stamp} =
      Loader.load_root(ctx, profile, source: Source.Memory, live: live, live_shape_digest: nil)

    authority
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
             projection: %{fields: ["ANTHROPIC_API_KEY", "ANTHROPIC_ORG"], scopes: []},
             lender: %{profile_id: "prof-claude", consent_id: "consent-claude"}
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
             consent_id: "consent-claude"
           }
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

    :ok =
      Source.Memory.put_profile(ctx, %{
        id: "prof-aqua",
        kind: :owner,
        source_ref: @formula,
        label: "default",
        status: :active
      })

    policy =
      Jason.encode!(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @formula => %{
            "limits" => Fixtures.limits_map(),
            "edges" => %{
              "@ingress" => %{},
              @catalyst => %{
                "vault" => %{
                  "entry_id" => "vault-anthropic",
                  "binding_digest" => "sha256:anthropic",
                  "projection" => %{"fields" => ["ANTHROPIC_API_KEY"]}
                }
              }
            }
          },
          role => %{
            "limits" => Fixtures.limits_map(),
            "edges" => %{
              @catalyst => %{
                "vault" => %{
                  "entry_id" => "vault-anthropic",
                  "binding_digest" => "sha256:other",
                  "projection" => %{"fields" => ["ANTHROPIC_API_KEY"]}
                }
              }
            }
          },
          @catalyst => %{"limits" => Fixtures.limits_map(), "edges" => %{}}
        }
      })

    :ok =
      Source.Memory.put_head_consent(ctx, "prof-aqua", %{
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
        vault_refs: [
          %{vault_entry_id: "vault-anthropic", binding_digest: "sha256:anthropic"},
          %{vault_entry_id: "vault-anthropic", binding_digest: "sha256:other"}
        ]
      })

    profile = %{
      id: "prof-aqua",
      kind: :owner,
      source_ref: @formula,
      label: "default",
      status: :active
    }

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
               source: Source.Memory,
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
end
