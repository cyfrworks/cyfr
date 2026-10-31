# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ConsentSetupPlanTest do
  use ExUnit.Case, async: false

  require Ecto.Query

  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Plan
  alias Sanctum.Vault

  @wasm Cyfr.Test.Guests.wasm(:reagent)

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

    # Said as a head the store cannot answer is: a retry, never a grant.
    assert %{
             profile_status: :unavailable,
             head_state: "unavailable",
             reason: "this component's consent cannot be read right now — try again",
             ready: false
           } = plan.consent

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

    # Said as a damaged head is: the profile to revoke, never a grant.
    assert %{
             profile_id: ^profile_id,
             profile_status: :corrupt,
             head_state: "damaged",
             reason: reason,
             ready: false
           } = plan.consent

    assert reason ==
             "this profile is damaged and cannot be used — " <>
               "revoke profile #{profile_id} and grant it again"

    assert plan.ready == false
  end

  # A head that cannot be given is said as profile.list names it, with
  # what the person can do: a grant for a head never granted, the profile
  # to revoke for a damaged one, and a retry when the store could not
  # answer, never a grant over a consent that exists.
  @tag :capture_log
  test "a profile whose head is missing, damaged or unreadable says which, and what to do",
       %{ctx: ctx} do
    publish!(ctx, "plan-head")
    ref = "reagent:local.plan-head"
    id = "prof_#{ref}"

    section = fn ->
      {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)
      plan.consent
    end

    :ok =
      Sanctum.Test.ConsentFixtures.seed_profile!(ctx, %{
        id: id,
        source_ref: ref,
        kind: :owner,
        label: "default",
        status: :active
      })

    assert %{
             head_state: "missing",
             reason: "this profile has no grant yet — grant it to continue",
             ready: false
           } = section.()

    seed!(ctx, ref, %{}, [])
    present = section.()
    assert %{head_state: "present", revision: 1} = present
    refute Map.has_key?(present, :reason)

    :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, id, scope: "sideways")

    damaged =
      "this profile's consent is damaged and cannot be used — " <>
        "revoke profile #{id} and grant it again"

    assert %{head_state: "damaged", reason: ^damaged, ready: false} = section.()

    :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, id, scope: "versionless")
    Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")

    assert %{
             head_state: "unavailable",
             reason: "this profile's consent cannot be read right now — try again",
             ready: false
           } = section.()
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

  # A grant of `name`'s key with `lifetime`, and its one binding row.
  defp lifetime_grant!(ctx, name, lifetime) do
    publish!(ctx, name)

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "#{name}-conn",
        kind: "api_key",
        fields: %{"k" => "v"},
        destination: %{"hosts" => ["api.example.com"]},
        disclose: true
      })

    _committed =
      grant!(ctx, "reagent:local.#{name}", [
        %{need: "@ingress", entry_id: entry.id, lifetime: lifetime}
      ])

    {:ok, [profile]} = Sanctum.Consent.profiles(ctx, "reagent:local.#{name}")
    {:ok, head} = Sanctum.Consent.head_consent(ctx, profile.id)

    row =
      Ecto.Query.from(r in Arca.Schemas.ConsentVaultRef,
        where: r.athanor_id == ^ctx.athanor_id and r.consent_id == ^head.id
      )

    {"reagent:local.#{name}", row}
  end

  test "a binding whose until has passed makes the plan not ready, as its attach refuses it", %{
    ctx: ctx
  } do
    ahead = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

    {ref, row} =
      lifetime_grant!(ctx, "plan-until", %{kind: "until", until: DateTime.to_iso8601(ahead)})

    assert {:ok, %{ready: true, consent: %{needs: [%{satisfied: true}]}}} =
             Compendium.Component.setup_plan(ctx, ref)

    {1, _} = Arca.Repo.update_all(row, set: [expires_at: DateTime.add(DateTime.utc_now(), -60)])

    assert {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

    assert [%{satisfied: false, detail: "its grant has expired — grant it again"}] =
             plan.consent.needs

    refute plan.consent.ready
    refute plan.ready
  end

  test "a once binding is ready until a run uses it, and reading the plan uses nothing", %{
    ctx: ctx
  } do
    {ref, row} = lifetime_grant!(ctx, "plan-once", %{kind: "once"})

    for _read <- 1..2 do
      assert {:ok, %{ready: true}} = Compendium.Component.setup_plan(ctx, ref)
    end

    assert [%{consumed_by_root: nil}] = Arca.Repo.all(row)

    {1, _} = Arca.Repo.update_all(row, set: [consumed_by_root: "exec_used"])

    assert {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

    assert [%{satisfied: false, detail: "its grant has expired — grant it again"}] =
             plan.consent.needs

    refute plan.ready
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
    # A disclosed field added is its person's to confirm.
    {:ok, _} =
      Sanctum.TestContext.confirming(
        ctx,
        &Vault.rebind(&1, %{id: entry.id, field_names: ["k", "region"]})
      )

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

  # A bound entry the store cannot answer is one to read again: never an
  # entry that no longer exists, nor one the person cannot use.
  @entry_unread "the bound vault entry cannot be read right now — try again"

  @tag :capture_log
  test "an own bound entry the store cannot answer is said as one to read again", %{ctx: ctx} do
    ref = "reagent:local.plan-entry-unread"
    publish!(ctx, "plan-entry-unread")

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "unread-conn",
        kind: "api_key",
        fields: %{"k" => "v"},
        destination: %{"hosts" => ["api.example.com"]},
        # A manifest declaring no need: the component reads its key.
        disclose: true
      })

    grant!(ctx, ref, [%{need: "@ingress", entry_id: entry.id}])
    assert {:ok, %{ready: true}} = Compendium.Component.setup_plan(ctx, ref)

    Arca.Repo.query!("ALTER TABLE vault_entries RENAME TO vault_entries_unavailable")

    {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)
    entry_id = entry.id
    assert [%{entry_id: ^entry_id, satisfied: false, detail: @entry_unread}] = plan.consent.needs
    refute plan.ready
  end

  defp detail_rows!(ctx, ref) do
    {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)
    plan.consent.needs
  end

  describe "a shared key" do
    alias Cyfr.Test.ShareFixtures

    # One need for an openai.com key, which CYFR attaches.
    @shared_need %{
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:openai.com",
          "reason" => "to call the model",
          "required" => true,
          "fields" => ["OPENAI_API_KEY"],
          "hosts" => ["api.openai.com"],
          "attach" => %{
            "in" => "header",
            "name" => "Authorization",
            "template" => "Bearer {value}"
          }
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.openai.com"], "methods" => ["POST"]}}
    }

    setup do
      ShareFixtures.traders!()
    end

    test "after Alice leaves the group Terry shared with, her grant is no longer ready",
         %{alice: alice, traders: traders, share: share} do
      ref = "reagent:local.plan-shared"
      publish_manifest!(alice.ctx, "plan-shared", @shared_need)
      walk!(alice.ctx, %{ref: ref, bindings: [%{need: "api_key", share_id: share.id}]})

      {:ok, plan} = Compendium.Component.setup_plan(alice.ctx, ref)
      assert plan.ready and plan.consent.ready
      share_id = share.id

      assert [%{entry_id: ^share_id, satisfied: true, detail: "bound to a key shared by Terry"}] =
               plan.consent.needs

      :ok = ShareFixtures.leave!(traders, alice)

      {:ok, plan} = Compendium.Component.setup_plan(alice.ctx, ref)
      refute plan.ready
      refute plan.consent.ready

      assert [
               %{
                 entry_id: ^share_id,
                 satisfied: false,
                 detail: "the shared key is no longer offered to you"
               }
             ] = plan.consent.needs
    end

    test "a key its owner rebound since the grant asks to re-approve",
         %{alice: alice, terry: terry, entry: entry, share: share} do
      ref = "reagent:local.plan-shared-rebound"
      publish_manifest!(alice.ctx, "plan-shared-rebound", @shared_need)
      walk!(alice.ctx, %{ref: ref, bindings: [%{need: "api_key", share_id: share.id}]})
      assert {:ok, %{ready: true}} = Compendium.Component.setup_plan(alice.ctx, ref)

      ShareFixtures.rebind!(terry, entry)

      assert detail!(alice.ctx, ref) ==
               "the shared key was rebound since this consent — re-approve to continue"
    end

    test "a key a dependency's profile lends is held as its share, and said as it",
         %{alice: alice, traders: traders, share: share} do
      dep = "reagent:local.plan-shared-dep"
      app = "reagent:local.plan-shared-app"
      publish_manifest!(alice.ctx, "plan-shared-dep", @shared_need)

      publish_manifest!(alice.ctx, "plan-shared-app", %{
        "dependencies" => %{"static" => [%{"ref" => dep}]}
      })

      walk!(alice.ctx, %{ref: dep, bindings: [%{need: "api_key", share_id: share.id}]})
      walk!(alice.ctx, %{ref: app, selections: [%{dep: dep, label: "default"}]})

      assert [%{satisfied: true, detail: "bound to a shared key (lent by its default profile)"}] =
               detail_rows!(alice.ctx, app)

      :ok = ShareFixtures.leave!(traders, alice)

      assert [
               %{
                 entry_id: nil,
                 satisfied: false,
                 detail: "the shared key the default profile lends is no longer offered to you"
               }
             ] = detail_rows!(alice.ctx, app)
    end

    @tag :capture_log
    test "a shared key the store cannot answer is said as one to read again",
         %{alice: alice, share: share} do
      ref = "reagent:local.plan-shared-unread"
      publish_manifest!(alice.ctx, "plan-shared-unread", @shared_need)
      walk!(alice.ctx, %{ref: ref, bindings: [%{need: "api_key", share_id: share.id}]})
      assert {:ok, %{ready: true}} = Compendium.Component.setup_plan(alice.ctx, ref)

      Arca.Repo.query!("ALTER TABLE shares RENAME TO shares_unavailable")

      {:ok, plan} = Compendium.Component.setup_plan(alice.ctx, ref)
      share_id = share.id

      assert [
               %{
                 entry_id: ^share_id,
                 satisfied: false,
                 detail: "the shared key cannot be read right now — try again"
               }
             ] = plan.consent.needs

      refute plan.ready
    end

    # A selection whose lender lends a share the store cannot answer is
    # read again, never a selection that resolves to nothing; one that
    # does resolve to nothing still says so.
    @tag :capture_log
    test "a key a dependency's profile lends that the store cannot answer is said as one to " <>
           "read again",
         %{alice: alice, share: share} do
      dep = "reagent:local.plan-shared-unread-dep"
      app = "reagent:local.plan-shared-unread-app"
      unread = "the shared key the default profile lends cannot be read right now — try again"
      publish_manifest!(alice.ctx, "plan-shared-unread-dep", @shared_need)

      publish_manifest!(alice.ctx, "plan-shared-unread-app", %{
        "dependencies" => %{"static" => [%{"ref" => dep}]}
      })

      walk!(alice.ctx, %{ref: dep, bindings: [%{need: "api_key", share_id: share.id}]})
      walk!(alice.ctx, %{ref: app, selections: [%{dep: dep, label: "default"}]})

      assert [%{satisfied: true, detail: "bound to a shared key (lent by its default profile)"}] =
               detail_rows!(alice.ctx, app)

      Arca.Repo.query!("ALTER TABLE shares RENAME TO shares_unavailable")
      assert [%{entry_id: nil, satisfied: false, detail: ^unread}] = detail_rows!(alice.ctx, app)
      Arca.Repo.query!("ALTER TABLE shares_unavailable RENAME TO shares")

      # A selection the borrower's own head no longer holds as approved
      # resolves to nothing, and says so as before.
      {:ok, [%{id: borrower}]} = Sanctum.Consent.profiles(alice.ctx, app)

      :ok =
        Sanctum.Test.ConsentFixtures.hand_edit_head!(alice.ctx, borrower,
          blob_digest: "sha256:" <> String.duplicate("0", 64)
        )

      assert [
               %{
                 entry_id: nil,
                 satisfied: false,
                 detail: "the selection of the default profile resolves to nothing"
               }
             ] = detail_rows!(alice.ctx, app)
    end
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
            "fields" => ["KEY"],
            "hosts" => ["api.example.com"]
          }
        },
        "caps" => %{"egress" => %{"domains" => ["api.example.com"]}}
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

    test "a lender whose until has passed makes the borrower's grant not ready, as its attach refuses it",
         %{ctx: ctx, entry: entry} do
      ahead = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

      walk!(ctx, %{
        ref: @dep,
        bindings: [
          %{
            need: "api_key",
            entry_id: entry.id,
            lifetime: %{kind: "until", until: DateTime.to_iso8601(ahead)}
          }
        ]
      })

      ref = "reagent:local.plan-borrower"
      walk!(ctx, %{ref: ref, selections: [%{dep: @dep, label: "default"}]})

      {:ok, [borrower]} = Sanctum.Consent.profiles(ctx, ref)
      {:ok, head} = Sanctum.Consent.head_consent(ctx, borrower.id)
      [binding] = head.vault_refs
      {:selection, _, {:ok, resource}} = Sanctum.Consent.row_binding(ctx, head, binding)
      use = %{profile_id: borrower.id, consent_id: head.id}

      # Live on both sides: the run's attach and the plan agree.
      assert :ok = Sanctum.Attach.lifetime(ctx, resource, use)
      assert :ok = Sanctum.Consent.binding_live(ctx, borrower.id, head, binding)
      assert {:ok, %{ready: true}} = Compendium.Component.setup_plan(ctx, ref)

      lender_id = resource.lender.consent_id

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(r in Arca.Schemas.ConsentVaultRef,
            where: r.athanor_id == ^ctx.athanor_id and r.consent_id == ^lender_id
          ),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -60)]
        )

      # The lender's row has passed: the attach refuses, and so does the
      # plan's read of the same binding.
      assert {:error, :grant_expired} = Sanctum.Attach.lifetime(ctx, resource, use)

      assert {:error, :grant_expired} =
               Sanctum.Consent.binding_live(ctx, borrower.id, head, binding)

      {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

      assert [%{satisfied: false, detail: "its grant has expired — grant it again"}] =
               plan.consent.needs

      refute plan.ready
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
      {:ok, _} =
        Sanctum.TestContext.confirming(
          ctx,
          &Vault.rebind(&1, %{id: entry.id, field_names: ["KEY", "ORG"]})
        )

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
      assert {:error, {:corrupt, {:profile, ^lender}}} = Plan.plan(ctx, %{ref: @dep})

      # The remedy the sentence names: the profile revoked, a new grant
      # lends the key.
      revoke!(ctx, lender)
      walk!(ctx, %{ref: @dep, bindings: [%{need: "api_key", entry_id: entry.id}]})

      assert detail!(ctx, ref) =~ "lent-conn"
    end

    # A lender's head whose bytes fail their digest, or do not parse, is
    # damage, as one that does not decode is: never a selection that
    # resolves to nothing, which would send the person to select again.
    test "a lender whose head's bytes fail their digest or do not parse names the profile " <>
           "to revoke",
         %{ctx: ctx, entry: entry} do
      ref = "reagent:local.plan-loose"
      seed_selection!(ctx, ref, %{"label" => "default"})
      lender = lender!(ctx)

      damaged =
        "the default profile it borrows from is damaged and cannot lend its key — " <>
          "revoke profile #{lender} and grant it again"

      :ok =
        Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, lender,
          blob_digest: "sha256:" <> String.duplicate("0", 64)
        )

      assert detail!(ctx, ref) == damaged

      :ok =
        Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, lender,
          resolved_policy: "not a blob",
          blob_digest: Prima.Digest.sha256("not a blob")
        )

      assert detail!(ctx, ref) == damaged

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

    # A head whose slot, of a manifest declaring no need, is bound to an
    # attach-only entry the component reads itself.
    vault = %{
      "entry_id" => view.id,
      "binding_digest" => digest,
      "scope" => "athanor",
      "binding_key" => key,
      "destination" => %{"hosts" => ["api.example.com"], "scheme" => "https"},
      "projection" => %{"fields" => %{"k" => "k"}, "scopes" => []}
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
          "hosts" => ["abc.supabase.co"],
          "attach" => %{"in" => "header", "name" => "apikey", "template" => "{value}"}
        }
      },
      "caps" => %{"egress" => %{"domains" => ["abc.supabase.co"]}}
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

  @tag :capture_log
  test "a stored manifest that does not decode is damage to the setup plan and the inspect",
       %{ctx: ctx} do
    publish!(ctx, "plan-torn")

    Arca.Repo.update_all(
      Ecto.Query.from(c in Arca.Schemas.Component, where: c.name == "plan-torn"),
      set: [manifest: "{not json"]
    )

    damage = {:corrupt, {:manifest, "reagent:local.plan-torn:1.0.0"}}

    assert {:error, ^damage} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-torn")

    assert {:error, ^damage} =
             Compendium.Component.inspect_component(ctx, "reagent:local.plan-torn")
  end

  @tag :capture_log
  test "an installed dependency whose stored manifest does not decode is damage to the inspect",
       %{ctx: ctx} do
    child = "reagent:local.plan-torn-child:1.0.0"
    publish!(ctx, "plan-torn-child")

    publish_manifest!(ctx, "plan-whole-root", %{
      "dependencies" => %{"static" => [%{"ref" => child}]}
    })

    assert {:ok, %{"dependencies" => [%{dependency_ref: ^child}], "all_satisfied" => true}} =
             Compendium.Component.inspect_component(ctx, "reagent:local.plan-whole-root")

    Arca.Repo.update_all(
      Ecto.Query.from(c in Arca.Schemas.Component, where: c.name == "plan-torn-child"),
      set: [manifest: "{not json"]
    )

    assert {:error, {:corrupt, {:manifest, ^child}}} =
             Compendium.Component.inspect_component(ctx, "reagent:local.plan-whole-root")
  end
end
