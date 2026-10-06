# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.LoaderSelectionTest do
  @moduledoc """
  A selected vault resolves at root load to the entry the named profile
  binds on its own ingress — and only then: an inactive profile, a
  profile of another source, a moved binding or a projection the ingress
  cannot satisfy leave the selection in place, which no run can unseal,
  while a lending head whose bytes fail their digest or do not parse is
  damage, refusing the run. A resolved selection carries both
  identities: the borrower's binding key where the selection sits, and
  the lender's profile, consent and binding key. Read row by row
  (`row_binding/3`), a lending profile or head that is absent, damaged or
  unanswered by the store says which.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

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

  # `table` stops answering once the head `consent_id` names is read whole
  # (its `consent_vault_refs`, the last read of that head), before what
  # follows it.
  defp away_after_head!(table, consent_id) do
    test = self()
    handler = "loader-selection-away-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == test and meta[:source] == "consent_vault_refs" and
               consent_id in (meta[:params] || []) do
            :telemetry.detach(handler)
            Arca.Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_unavailable")
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # A profile row written as no writer of the table would: the damage a
  # read must tell apart from an absence.
  defp set_profile!(ctx, id, changes) do
    {1, _} =
      Arca.Repo.update_all(
        from(p in Arca.Schemas.Profile, where: p.athanor_id == ^ctx.athanor_id and p.id == ^id),
        set: changes
      )
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

  # A selection naming an entry binds the dependency's edge directly: no
  # lender stands behind it, and its row is the borrower's own, keyed where
  # it sits. Its lifetime is the binding's, checked where the binding is
  # used, never at load.
  test "an entry bound on the edge itself loads as it stands, whatever its row's lifetime",
       %{ctx: ctx} do
    key = Blob.binding_key(@formula, @catalyst, nil)
    bound = Map.put(@key_vault, "binding_key", key)

    for {kind, expires} <- [
          {"once", nil},
          {"until", DateTime.add(DateTime.utc_now(), 3600, :second)}
        ] do
      profile =
        put_formula!(ctx, bound, [:interactive], [
          %{
            binding_key: key,
            scope: "athanor",
            vault_entry_id: "vault-anthropic",
            binding_digest: "sha256:anthropic",
            lifetime_kind: kind,
            expires_at: expires
          }
        ])

      vault = edge_vault(load!(ctx, profile))

      assert %{entry_id: "vault-anthropic", binding_key: ^key} = vault
      refute Map.has_key?(vault, :lender)
    end
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

  test "a revoked profile, another source's profile and an unbound ingress lend nothing",
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

  describe "a selection row read by row_binding/3" do
    # The borrower's own head is read once, before anything is taken
    # away: each case below breaks only what the lender's side reads.
    setup %{ctx: ctx} do
      put_catalyst!(ctx)
      put_formula!(ctx, %{"via" => %{"label" => "default"}})
      {:ok, consent} = Arca.ConsentStorage.head_consent(Context.actor(ctx), "prof-aqua")
      [row] = consent.vault_refs

      assert {:selection, "default", {:ok, %{entry_id: "vault-anthropic"}}} =
               Loader.row_binding(ctx, consent, row)

      {:ok, consent: consent, row: row}
    end

    @tag :capture_log
    test "tells a damaged lending profile, an absent one and an unanswered store apart",
         %{ctx: ctx, consent: consent, row: row} do
      # Its kind outside the vocabulary, the row's label cannot be read: it
      # may be the lender, so it refuses the selection by label.
      set_profile!(ctx, "prof-claude", kind: "sideways")

      assert {:selection, "default", {:error, {:lender_corrupt, @catalyst, "prof-claude"}}} =
               Loader.row_binding(ctx, consent, row)

      set_profile!(ctx, "prof-claude", kind: "owner", label: "elsewhere")

      assert {:selection, "default", {:error, {:no_such_profile, @catalyst, "default"}}} =
               Loader.row_binding(ctx, consent, row)

      set_profile!(ctx, "prof-claude", label: "default")
      Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")

      assert {:selection, "default", {:error, {:lender_unavailable, @catalyst}}} =
               Loader.row_binding(ctx, consent, row)
    end

    # A lender's head answers as the lender: `head_*` names a root's own
    # head alone.
    @tag :capture_log
    test "tells an absent, a damaged and an unanswered lending head apart",
         %{ctx: ctx, consent: consent, row: row} do
      set_profile!(ctx, "prof-claude", head_consent_id: nil)

      assert {:selection, "default", {:error, {:no_head_consent, "prof-claude"}}} =
               Loader.row_binding(ctx, consent, row)

      set_profile!(ctx, "prof-claude", head_consent_id: "consent-claude")
      :ok = ConsentFixtures.hand_edit_head!(ctx, "prof-claude", scope: "sideways")

      assert {:selection, "default", {:error, {:lender_corrupt, @catalyst, "prof-claude"}}} =
               Loader.row_binding(ctx, consent, row)

      :ok = ConsentFixtures.hand_edit_head!(ctx, "prof-claude", scope: "versionless")
      Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")

      assert {:selection, "default", {:error, {:lender_unavailable, @catalyst}}} =
               Loader.row_binding(ctx, consent, row)
    end

    # A lending head whose bytes fail their digest, or do not parse, is the
    # lender's damage, as a head that does not decode is.
    test "a lending head whose bytes fail their digest or do not parse is damage",
         %{ctx: ctx, consent: consent, row: row} do
      damaged = {:selection, "default", {:error, {:lender_corrupt, @catalyst, "prof-claude"}}}

      :ok = ConsentFixtures.hand_edit_head!(ctx, "prof-claude", blob_digest: "sha256:tampered")
      assert Loader.row_binding(ctx, consent, row) == damaged

      :ok =
        ConsentFixtures.hand_edit_head!(ctx, "prof-claude",
          resolved_policy: "not a blob",
          blob_digest: JCS.hash_binary("not a blob")
        )

      assert Loader.row_binding(ctx, consent, row) == damaged
    end

    test "a damaged profile row of the target refuses the selection, though the lender is whole",
         %{ctx: ctx, consent: consent, row: row} do
      :ok =
        ConsentFixtures.seed_profile!(ctx, %{
          id: "prof-claude-twin",
          kind: :public,
          source_ref: @catalyst,
          label: "default",
          status: :active
        })

      set_profile!(ctx, "prof-claude-twin", status: "sideways")

      assert {:selection, "default", {:error, {:lender_corrupt, @catalyst, "prof-claude-twin"}}} =
               Loader.row_binding(ctx, consent, row)

      # Revoked, the damaged row is no candidate, and the lender lends.
      set_profile!(ctx, "prof-claude-twin", status: "revoked")

      assert {:selection, "default", {:ok, %{entry_id: "vault-anthropic"}}} =
               Loader.row_binding(ctx, consent, row)
    end
  end

  describe "a run's lender, read by load_root/3" do
    setup %{ctx: ctx} do
      put_catalyst!(ctx)
      profile = put_formula!(ctx, %{"via" => %{"label" => "default"}})
      assert %{entry_id: "vault-anthropic"} = edge_vault(load!(ctx, profile))
      {:ok, profile: profile}
    end

    test "a lender that does not decode refuses the run, and an absent one leaves the selection",
         %{ctx: ctx, profile: profile} do
      damaged = {:error, {:lender_corrupt, @catalyst, "prof-claude"}}

      # The lender's profile row, its kind outside the vocabulary.
      set_profile!(ctx, "prof-claude", kind: "sideways")
      assert load(ctx, profile) == damaged

      set_profile!(ctx, "prof-claude", kind: "owner", label: "elsewhere")
      assert %{via: %{label: "default"}} = edge_vault(load!(ctx, profile))

      # The lender's head, its scope outside the vocabulary.
      set_profile!(ctx, "prof-claude", label: "default")
      :ok = ConsentFixtures.hand_edit_head!(ctx, "prof-claude", scope: "sideways")
      assert load(ctx, profile) == damaged

      :ok = ConsentFixtures.hand_edit_head!(ctx, "prof-claude", scope: "versionless")
      set_profile!(ctx, "prof-claude", head_consent_id: nil)
      assert %{via: %{label: "default"}} = edge_vault(load!(ctx, profile))

      set_profile!(ctx, "prof-claude", head_consent_id: "consent-claude")
      assert %{entry_id: "vault-anthropic"} = edge_vault(load!(ctx, profile))
    end

    # The store stops answering once the run's own head is read, so only
    # the lender's read meets the outage.
    @tag :capture_log
    test "a lender the store cannot answer refuses the run", %{ctx: ctx, profile: profile} do
      for table <- ~w(profiles consents) do
        away_after_head!(table, "consent-aqua")
        assert load(ctx, profile) == {:error, {:lender_unavailable, @catalyst}}, table
        Arca.Repo.query!("ALTER TABLE #{table}_unavailable RENAME TO #{table}")
      end

      assert %{entry_id: "vault-anthropic"} = edge_vault(load!(ctx, profile))
    end

    # A lender's head whose bytes fail their digest, or do not parse, is a
    # lender that exists and is damaged, never one that lends nothing: the
    # run is refused as the other damage is.
    test "a lender whose head's bytes fail their digest or do not parse refuses the run",
         %{ctx: ctx, profile: profile} do
      damaged = {:error, {:lender_corrupt, @catalyst, "prof-claude"}}

      put_catalyst!(ctx, blob_digest: "sha256:tampered")
      assert load(ctx, profile) == damaged

      :ok =
        ConsentFixtures.hand_edit_head!(ctx, "prof-claude",
          resolved_policy: "not a blob",
          blob_digest: JCS.hash_binary("not a blob")
        )

      assert load(ctx, profile) == damaged

      put_catalyst!(ctx)
      assert %{entry_id: "vault-anthropic"} = edge_vault(load!(ctx, profile))
    end

    # The run's own head keeps its own answers: a root is not a lender.
    test "the run's own head, damaged, keeps its own answer, never a lender's",
         %{ctx: ctx, profile: profile} do
      :ok = ConsentFixtures.hand_edit_head!(ctx, "prof-aqua", scope: "sideways")
      assert {:error, {:head_corrupt, "prof-aqua"}} = load(ctx, profile)

      :ok = ConsentFixtures.hand_edit_head!(ctx, "prof-aqua", scope: "versionless")
      :ok = ConsentFixtures.hand_edit_head!(ctx, "prof-aqua", blob_digest: "sha256:tampered")
      assert {:error, {:blob_digest_mismatch, "sha256:tampered"}} = load(ctx, profile)

      :ok =
        ConsentFixtures.hand_edit_head!(ctx, "prof-aqua",
          resolved_policy: "not a blob",
          blob_digest: JCS.hash_binary("not a blob")
        )

      assert {:error, {:invalid_blob, _}} = load(ctx, profile)
    end
  end

  # A lender's head that reads and decodes but lends nothing on the
  # target's ingress keeps the answer that says why, and the run keeps
  # the selection in place: none of these is damage.
  test "a lending head that decodes and lends nothing keeps its own answer", %{ctx: ctx} do
    selection = %{"via" => %{"label" => "default"}}

    row_binding = fn profile ->
      {:ok, consent} = Arca.ConsentStorage.head_consent(Context.actor(ctx), profile.id)
      [row] = consent.vault_refs
      Loader.row_binding(ctx, consent, row)
    end

    # No ingress for the target in the lender's head.
    put_catalyst!(ctx)

    bare =
      Jason.encode!(%{
        "canonical" => "jcs-1",
        "nodes" => %{@catalyst => %{"limits" => Fixtures.limits_map(), "edges" => %{}}}
      })

    :ok =
      ConsentFixtures.hand_edit_head!(ctx, "prof-claude",
        resolved_policy: bare,
        blob_digest: JCS.hash_binary(bare)
      )

    profile = put_formula!(ctx, selection)

    assert {:selection, "default", {:error, {:missing_ingress, @catalyst}}} =
             row_binding.(profile)

    assert %{via: _} = edge_vault(load!(ctx, profile))

    # An ingress that binds nothing.
    put_catalyst!(ctx, vault: nil)
    assert {:selection, "default", {:error, :nothing_bound}} = row_binding.(profile)
    assert %{via: _} = edge_vault(load!(ctx, profile))

    # A digest the selection pinned that the lender no longer binds.
    put_catalyst!(ctx)

    pinned =
      put_formula!(ctx, %{"via" => %{"label" => "default", "binding_digest" => "sha256:x"}})

    assert {:selection, "default", {:error, :binding_moved}} = row_binding.(pinned)
    assert %{via: _} = edge_vault(load!(ctx, pinned))

    # A projection the lender's ingress cannot narrow to.
    narrow =
      put_formula!(ctx, %{
        "via" => %{"label" => "default"},
        "projection" => %{"fields" => ["SOMETHING_ELSE"]}
      })

    assert {:selection, "default", {:error, :projection_unsatisfiable}} = row_binding.(narrow)
    assert %{via: _} = edge_vault(load!(ctx, narrow))
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
