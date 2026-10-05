# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ConsentSetupPlanTest do
  use ExUnit.Case, async: false

  require Ecto.Query

  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Plan
  alias Sanctum.Vault

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "consent_setup_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp publish!(ctx, name) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: name,
        version: "1.0.0",
        type: "reagent"
      })

    component
  end

  @dep "reagent:local.plan-dep"

  @limits %{
    "timeout" => "1m",
    "max_memory_bytes" => 67_108_864,
    "max_request_size" => 1_048_576,
    "max_response_size" => 5_242_880,
    "rate_limit" => %{"requests" => 100, "window" => "1m"},
    "max_concurrent_tasks" => 5,
    "batch_timeout" => "1m"
  }

  defp publish_manifest!(ctx, name, manifest_extra) do
    manifest =
      Map.merge(%{"name" => name, "version" => "1.0.0", "type" => "reagent"}, manifest_extra)

    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    component
  end

  # The consent walk a person makes: plan, preview, commit.
  defp walk!(ctx, decisions) do
    {:ok, plan} = Plan.plan(ctx, Map.take(decisions, [:ref, :label]))
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, committed} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    committed
  end

  # `ref`'s owner head, written as it is stored: a revision whose source
  # node holds `edges` beside its ingress, and `refs` as its rows.
  defp seed!(ctx, ref, edges, refs) do
    nodes = %{ref => %{"limits" => @limits, "edges" => Map.put(edges, "@ingress", %{})}}

    nodes =
      if edges == %{},
        do: nodes,
        else: Map.put(nodes, @dep, %{"limits" => @limits, "edges" => %{}})

    :ok =
      Sanctum.Test.ConsentFixtures.seed_head!(
        ctx,
        %{id: "prof_#{ref}", source_ref: ref, kind: :owner, status: :active},
        %{
          id: "cons_#{ref}",
          revision: 1,
          scope: :versionless,
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          resolved_policy: Jason.encode!(%{"canonical" => "jcs-1", "nodes" => nodes}),
          activation: %{ref => "sha256:act"},
          admitted_origins: [:interactive],
          vault_refs: refs
        }
      )
  end

  # A head whose edge into the dependency selects its profile through
  # `via`, with the borrower's own row for it, pinning what `via` pins.
  defp seed_selection!(ctx, ref, via) do
    seed!(ctx, ref, %{@dep => %{"vault" => %{"via" => via}}}, [
      %{
        binding_key: Prima.Authority.Blob.binding_key(ref, @dep, nil),
        scope: "athanor",
        via_label: via["label"],
        binding_digest: via["binding_digest"]
      }
    ])
  end

  # The dependency's one profile: the lender a selection borrows from.
  defp lender!(ctx) do
    {:ok, [%{id: lender}]} = Sanctum.Consent.profiles(ctx, @dep)
    lender
  end

  # A profile row written as no writer of the table would.
  defp set_profile!(ctx, id, changes) do
    {1, _} =
      Arca.Repo.update_all(
        Ecto.Query.from(p in Arca.Schemas.Profile,
          where: p.athanor_id == ^ctx.athanor_id and p.id == ^id
        ),
        set: changes
      )
  end

  defp revoke!(ctx, profile_id) do
    {:ok, %{status: "revoked"}} =
      Sanctum.Provider.handle("profile", ctx, %{"action" => "revoke", "profile_id" => profile_id})
  end

  # The one need's sentence on `ref`'s setup plan.
  defp detail!(ctx, ref) do
    {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)
    [%{detail: detail}] = plan.consent.needs
    detail
  end

  # `table` stops answering once the borrower's own head rows are read
  # (its `consent_vault_refs`, the last read of that head), before the
  # page resolves the borrower's selection.
  defp away_after_borrower_head!(table, borrower_consent_id) do
    test = self()
    handler = "setup-plan-away-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == test and meta[:source] == "consent_vault_refs" and
               borrower_consent_id in (meta[:params] || []) do
            :telemetry.detach(handler)
            Arca.Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_unavailable")
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp grant!(ctx, ref, bindings) do
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, bindings: bindings}
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, committed} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    committed
  end

  @tag :capture_log
  test "a consent store that cannot answer is not ready, never 'no profile'", %{ctx: ctx} do
    publish!(ctx, "plan-outage")
    Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-outage")

    assert %{profile_status: :unavailable, ready: false} = plan.consent
    assert plan.ready == false
  end

  test "an owner profile that cannot be decoded is reported, not skipped", %{ctx: ctx} do
    publish!(ctx, "plan-damaged")

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "plan-damaged-conn",
        kind: "api_key",
        fields: %{"k" => "v"},
        destination: %{"hosts" => ["api.example.com"]},
        # A manifest declaring no need: the component reads its key.
        disclose: true
      })

    grant!(ctx, "reagent:local.plan-damaged", [%{need: "@ingress", entry_id: entry.id}])

    {:ok, [%{id: profile_id}]} =
      Sanctum.Consent.profiles(ctx, "reagent:local.plan-damaged")

    Arca.Repo.update_all(
      Ecto.Query.from(p in Arca.Schemas.Profile,
        where: p.athanor_id == ^ctx.athanor_id and p.id == ^profile_id
      ),
      set: [kind: "sideways"]
    )

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-damaged")

    assert %{profile_id: ^profile_id, profile_status: :corrupt, ready: false} = plan.consent
    assert plan.ready == false
  end

  test "a component with no profile and no needs is ready", %{ctx: ctx} do
    publish!(ctx, "plan-no-profile")

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-no-profile")

    assert plan.consent == nil
    assert plan.needs == []
    assert plan.ready == true
  end

  test "a granted profile reports ready from its consent", %{ctx: ctx} do
    publish!(ctx, "plan-granted")

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "plan-conn",
        kind: "api_key",
        fields: %{"k" => "v"},
        destination: %{"hosts" => ["api.example.com"]},
        # A manifest declaring no need: the component reads its key.
        disclose: true
      })

    grant!(ctx, "reagent:local.plan-granted", [%{need: "@ingress", entry_id: entry.id}])

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-granted")

    assert plan.consent.revision == 1
    assert plan.consent.profile_kind == :owner
    assert [%{satisfied: true, detail: detail}] = plan.consent.needs
    assert detail =~ "plan-conn"
    assert plan.ready
  end

  test "a rebound connection makes the plan not-ready with an actionable detail",
       %{ctx: ctx} do
    publish!(ctx, "plan-rebound")

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "rebound-conn",
        kind: "api_key",
        fields: %{"k" => "v"},
        destination: %{"hosts" => ["api.example.com"]},
        # A manifest declaring no need: the component reads its key.
        disclose: true
      })

    grant!(ctx, "reagent:local.plan-rebound", [%{need: "@ingress", entry_id: entry.id}])
    {:ok, _} = Vault.rebind(ctx, %{id: entry.id, field_names: ["k", "region"]})

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-rebound")

    assert [%{satisfied: false, detail: detail}] = plan.consent.needs
    assert detail =~ "rebound"
    refute plan.ready
  end

  test "a revoked connection makes the plan not-ready", %{ctx: ctx} do
    publish!(ctx, "plan-revoked")

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "revoked-conn",
        kind: "api_key",
        fields: %{"k" => "v"},
        destination: %{"hosts" => ["api.example.com"]},
        # A manifest declaring no need: the component reads its key.
        disclose: true
      })

    grant!(ctx, "reagent:local.plan-revoked", [%{need: "@ingress", entry_id: entry.id}])
    {:ok, _} = Vault.revoke(ctx, entry.id)

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-revoked")

    assert [%{satisfied: false, detail: detail}] = plan.consent.needs
    assert detail =~ "revoked"
    refute plan.ready
  end

  describe "a borrowed key" do
    # The dependency declares one key and its own profile binds an entry;
    # each source depends on it and selects that profile. A selection
    # resolves under the origin a run carries: here the console's
    # `interactive`, which the lender's grant admits.
    setup %{ctx: ctx} do
      ctx = Sanctum.TestContext.via(ctx, :prism)

      publish_manifest!(ctx, "plan-dep", %{
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:example.com",
            "reason" => "to call the example API",
            "required" => true,
            "fields" => ["KEY"]
          }
        }
      })

      for name <- ~w(plan-borrower plan-loose) do
        publish_manifest!(ctx, name, %{"dependencies" => %{"static" => [%{"ref" => @dep}]}})
      end

      {:ok, entry} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "lent-conn",
          kind: "api_key",
          # The dependency's need is example.com's, and the dependency
          # reads its key itself.
          provider_hint: "example.com",
          fields: %{"KEY" => "k"},
          destination: %{"hosts" => ["api.example.com"]},
          disclose: true
        })

      walk!(ctx, %{ref: @dep, bindings: [%{need: "api_key", entry_id: entry.id}]})
      {:ok, ctx: ctx, entry: entry}
    end

    test "pinned by the walk, reads ready from the lender's entry, and not ready once it moves",
         %{ctx: ctx, entry: entry} do
      ref = "reagent:local.plan-borrower"
      walk!(ctx, %{ref: ref, selections: [%{dep: @dep, label: "default"}]})

      {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

      entry_id = entry.id
      assert [%{entry_id: ^entry_id, satisfied: true, detail: detail}] = plan.consent.needs
      assert detail =~ "lent-conn"
      assert plan.ready

      # The lender's entry is rebound: the lender waits on a new consent,
      # so the selection resolves to nothing, which is said, not raised.
      {:ok, _} = Vault.rebind(ctx, %{id: entry.id, field_names: ["KEY", "ORG"]})

      {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

      assert [%{entry_id: nil, satisfied: false, detail: detail}] = plan.consent.needs
      assert detail =~ "default"
      refute plan.ready
    end

    test "unpinned, resolves as a run resolves it, and a label no profile has is not ready",
         %{ctx: ctx, entry: entry} do
      ref = "reagent:local.plan-loose"

      seed_selection!(ctx, ref, %{"label" => "default"})
      {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

      entry_id = entry.id
      assert [%{entry_id: ^entry_id, satisfied: true, detail: detail}] = plan.consent.needs
      assert detail =~ "lent-conn"
      assert plan.ready

      seed_selection!(ctx, ref, %{"label" => "work"})
      {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

      assert [%{entry_id: nil, satisfied: false, detail: detail}] = plan.consent.needs
      assert detail =~ "work"
      refute plan.ready
    end

    test "a lender with no grant, and one whose head is damaged, each say what to do",
         %{ctx: ctx, entry: entry} do
      ref = "reagent:local.plan-loose"
      seed_selection!(ctx, ref, %{"label" => "default"})
      lender = lender!(ctx)

      {:ok, %{head_consent_id: head}} =
        Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), lender)

      set_profile!(ctx, lender, head_consent_id: nil)

      assert detail!(ctx, ref) ==
               "the default profile it borrows from has no grant — " <>
                 "re-approve that profile to continue"

      set_profile!(ctx, lender, head_consent_id: head)
      :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, lender, scope: "sideways")

      assert detail!(ctx, ref) ==
               "the default profile it borrows from is damaged and cannot lend its key — " <>
                 "revoke profile #{lender} and grant it again"

      # Approving the lender again cannot repair it: the walk reads the
      # head it would revise and refuses the damaged one.
      assert {:error, {:invalid_stored_value, "sideways"}} = Plan.plan(ctx, %{ref: @dep})

      # The remedy the sentence names: the profile revoked, a new grant
      # lends the key.
      revoke!(ctx, lender)
      walk!(ctx, %{ref: @dep, bindings: [%{need: "api_key", entry_id: entry.id}]})

      assert detail!(ctx, ref) =~ "lent-conn"
    end

    test "a damaged lending profile row names the profile to revoke, and approving again " <>
           "does not repair it",
         %{ctx: ctx, entry: entry} do
      ref = "reagent:local.plan-loose"
      seed_selection!(ctx, ref, %{"label" => "default"})
      lender = lender!(ctx)
      set_profile!(ctx, lender, kind: "sideways")

      damaged =
        "the default profile it borrows from is damaged and cannot lend its key — " <>
          "revoke profile #{lender} and grant it again"

      assert detail!(ctx, ref) == damaged

      # The walk never sees the damaged row: it writes a profile beside it,
      # and the damaged row still refuses the selection by label.
      walk!(ctx, %{ref: @dep, bindings: [%{need: "api_key", entry_id: entry.id}]})
      assert detail!(ctx, ref) == damaged

      revoke!(ctx, lender)
      assert detail!(ctx, ref) =~ "lent-conn"
    end

    # The store stops answering right after the borrower's own head is
    # read, so only the lender's read meets the outage.
    @tag :capture_log
    test "a lender the store cannot answer is said to be unreadable, never absent",
         %{ctx: ctx} do
      ref = "reagent:local.plan-loose"
      unreadable = "the default profile it borrows from cannot be read right now — try again"

      for table <- ~w(profiles consents) do
        seed_selection!(ctx, ref, %{"label" => "default"})
        away_after_borrower_head!(table, "cons_#{ref}")

        {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

        assert %{revision: 1, needs: [%{entry_id: nil, satisfied: false, detail: ^unreadable}]} =
                 plan.consent,
               "with #{table} away: #{inspect(plan.consent)}"

        Arca.Repo.query!("ALTER TABLE #{table}_unavailable RENAME TO #{table}")
      end
    end

    test "a row naming an instance entry is read as the person is offered it, at its digest",
         %{ctx: ctx} do
      ref = "reagent:local.plan-loose"
      {ctx, _user} = Sanctum.TestContext.person!(ctx)

      {:ok, instance} =
        Arca.InstanceEntries.put(Arca.Test.Actor.platform(), %{
          name: "instance-#{System.unique_integer([:positive])}",
          kind: "api_key",
          provider_hint: "example.com",
          field_names: ~s(["KEY"]),
          destination:
            ~s({"hosts":["api.example.com"],"methods":["GET"],"paths":["/v1/"],"scheme":"https"}),
          sealed_payload: "sealed",
          binding_digest: "sha256:instance",
          audience: "everyone",
          created_by: "usr_admin"
        })

      seed!(ctx, ref, %{}, [
        %{
          binding_key: Prima.Authority.Blob.binding_key(ref, "@ingress", nil),
          scope: "instance",
          instance_entry_id: instance.id,
          binding_digest: "sha256:instance"
        }
      ])

      {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

      instance_id = instance.id
      assert [%{entry_id: ^instance_id, satisfied: true, detail: detail}] = plan.consent.needs
      assert detail =~ instance.name and detail =~ "instance entry"
      assert plan.ready

      # Rebound since the person approved it: not ready, said as such.
      {:ok, _} =
        Arca.InstanceEntries.move_binding(
          Arca.Test.Actor.platform(),
          instance.id,
          "sha256:instance",
          %{
            destination:
              ~s({"hosts":["api.example.com"],"methods":["GET"],"paths":["/v2/"],"scheme":"https"}),
            binding_digest: "sha256:moved"
          },
          "needs_consent"
        )

      {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)
      assert [%{entry_id: ^instance_id, satisfied: false, detail: detail}] = plan.consent.needs
      assert detail =~ "rebound"
      refute plan.ready

      # Revoked: not ready, said as such.
      {:ok, _} =
        Arca.InstanceEntries.revoke(Arca.Test.Actor.platform(), instance.id, "needs_consent")

      {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)
      assert [%{satisfied: false, detail: detail}] = plan.consent.needs
      assert detail =~ "revoked"
    end
  end

  test "an attach-only entry the component would read itself is not ready, and the remedy " <>
         "is the update or disclosing it",
       %{ctx: ctx} do
    ref = "reagent:local.plan-reads"
    publish!(ctx, "plan-reads")

    {:ok, view} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "attach-only-conn",
        kind: "api_key",
        fields: %{"k" => "v"},
        destination: %{"hosts" => ["api.example.com"]}
      })

    {:ok, row} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), view.id)
    {:ok, digest} = Sanctum.VaultReader.binding_digest(row)
    key = Prima.Authority.Blob.binding_key(ref, "@ingress", nil)

    # A head written before a binding was held to its disclosure: the
    # slot of a manifest declaring no need, bound to an attach-only entry.
    vault = %{
      "entry_id" => view.id,
      "binding_digest" => digest,
      "scope" => "athanor",
      "binding_key" => key,
      "destination" => %{"hosts" => ["api.example.com"], "scheme" => "https"},
      "projection" => %{"fields" => ["k"]}
    }

    :ok =
      Sanctum.Test.ConsentFixtures.seed_head!(
        ctx,
        %{id: "prof_reads", source_ref: ref, kind: :owner, status: :active},
        %{
          id: "cons_reads",
          revision: 1,
          scope: :versionless,
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          resolved_policy:
            Jason.encode!(%{
              "canonical" => "jcs-1",
              "nodes" => %{
                ref => %{"limits" => @limits, "edges" => %{"@ingress" => %{"vault" => vault}}}
              }
            }),
          activation: %{ref => "sha256:act"},
          admitted_origins: [:interactive],
          vault_refs: [
            %{
              binding_key: key,
              scope: "athanor",
              vault_entry_id: view.id,
              binding_digest: digest
            }
          ]
        }
      )

    {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

    assert [%{satisfied: false, detail: detail}] = plan.consent.needs
    assert detail =~ "reads this value itself"
    assert detail =~ "update"
    assert detail =~ "disclose the entry"
    refute plan.ready
  end

  test "a need the app provides is the publisher's, never an unbound need", %{ctx: ctx} do
    publish_manifest!(ctx, "plan-db", %{
      "needs" => %{
        "database" => %{
          "type" => "api_key:supabase.co",
          "reason" => "to reach the database",
          "required" => true,
          "fields" => ["anon_key"],
          "attach" => %{"in" => "header", "name" => "apikey", "template" => "{value}"}
        }
      }
    })

    publish_manifest!(ctx, "plan-app", %{
      "dependencies" => %{"static" => [%{"ref" => "reagent:local.plan-db"}]},
      "provides" => %{
        "reagent:local.plan-db" => %{
          "database" => %{
            "destination" => %{"hosts" => ["abc.supabase.co"]},
            "values" => %{"anon_key" => "eyJ-public"}
          }
        }
      }
    })

    walk!(Sanctum.TestContext.via(ctx, :prism), %{ref: "reagent:local.plan-app"})
    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-app")

    assert plan.consent.needs == []
    assert plan.consent.ready
  end

  test "a consent binding nothing is ready — an egress-only grant is complete",
       %{ctx: ctx} do
    publish!(ctx, "plan-bare")
    grant!(ctx, "reagent:local.plan-bare", [])

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-bare")

    assert plan.consent.needs == []
    assert plan.ready
  end
end
