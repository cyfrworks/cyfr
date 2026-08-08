# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.FlowTest do
  use ExUnit.Case, async: false

  alias Sanctum.Authority
  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Loader
  alias Sanctum.Consent.Plan
  alias Sanctum.Consent.Source
  alias Sanctum.Vault

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "consent_flow_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    original_source = Application.get_env(:cyfr, :consent_source)
    Application.put_env(:cyfr, :consent_source, Source.DB)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)

      if original_source,
        do: Application.put_env(:cyfr, :consent_source, original_source),
        else: Application.delete_env(:cyfr, :consent_source)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp publish!(ctx, name, version \\ "1.0.0", attrs \\ %{}) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(
        ctx,
        @wasm,
        Map.merge(%{name: name, version: version, type: "reagent"}, attrs)
      )

    component
  end

  defp entry!(ctx, over \\ %{}) do
    {:ok, view} =
      Vault.create(
        ctx,
        Map.merge(
          %{
            name: "conn-#{System.unique_integer([:positive])}",
            kind: "api_key",
            fields: %{"url" => "https://db.example", "anon_key" => "anon"}
          },
          over
        )
      )

    view
  end

  defp walk!(ctx, ref, decisions_over \\ %{}) do
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    decisions = Map.merge(%{ref: ref}, decisions_over)
    {:ok, preview} = Commit.preview(ctx, decisions)

    Commit.commit(ctx, %{
      decisions: decisions,
      plan_token: plan.plan_token,
      proof: preview.proof,
      commit_digest: preview.commit_digest,
      expected_consent_revision: plan.expected_consent_revision
    })
  end

  describe "plan → preview → commit" do
    test "mints a loadable first revision with a bound connection", %{ctx: ctx} do
      publish!(ctx, "flow-happy")
      entry = entry!(ctx)

      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.flow-happy"})
      assert plan.expected_consent_revision == 0
      assert plan.profile_id == nil
      assert Enum.any?(plan.candidates, &(&1.id == entry.id))
      assert [%{need: "@ingress"}] = plan.needs

      decisions = %{
        ref: "reagent:local.flow-happy",
        bindings: [%{need: "@ingress", entry_id: entry.id, fields: ["url", "anon_key"]}]
      }

      {:ok, preview} = Commit.preview(ctx, decisions)
      assert Enum.any?(preview.summary, &(&1 =~ "Uses #{entry.name}"))

      {:ok, committed} =
        Commit.commit(ctx, %{
          decisions: decisions,
          plan_token: plan.plan_token,
          proof: preview.proof,
          commit_digest: preview.commit_digest,
          expected_consent_revision: 0
        })

      assert committed.revision == 1

      # The revision loads through the production source into an Authority
      # whose ingress edge carries the bound vault resource, projected.
      {:ok, [profile]} = Source.DB.profiles(ctx, "reagent:local.flow-happy")
      assert profile.status == :active

      {:ok, component} = Compendium.Registry.get_latest(ctx, "flow-happy", "local", "reagent")
      {:ok, live} = Compendium.Activation.resolve_verified(ctx, component)

      assert {:ok, %Authority{} = auth, _stamp} =
               Loader.load_root(ctx, profile, source: Source.DB, live: {:ok, live})

      assert auth.resources.vault.entry_id == entry.id
      assert auth.resources.vault.projection.fields == ["anon_key", "url"]

      {:ok, consent} = Source.DB.head_consent(ctx, profile.id)

      assert consent.vault_refs == [
               %{vault_entry_id: entry.id, binding_digest: auth.resources.vault.binding_digest}
             ]
    end

    test "a second walk writes a delta revision and advances the head", %{ctx: ctx} do
      publish!(ctx, "flow-delta")

      assert {:ok, %{revision: 1}} = walk!(ctx, "reagent:local.flow-delta")

      assert {:ok, %{revision: 2, profile_id: profile_id}} =
               walk!(ctx, "reagent:local.flow-delta")

      {:ok, consent} = Source.DB.head_consent(ctx, profile_id)
      assert consent.revision == 2
    end

    test "granted_via records the interactive class", %{ctx: ctx} do
      publish!(ctx, "flow-via")
      {:ok, %{profile_id: profile_id}} = walk!(ctx, "reagent:local.flow-via")

      {:ok, head, _refs} = Arca.ConsentStorage.get_head(ctx.org_id, profile_id)
      assert head.granted_via == "interactive"
      assert head.granted_by == ctx.user_id
    end
  end

  describe "conflicts" do
    test "a plan staged against a superseded revision is stale", %{ctx: ctx} do
      publish!(ctx, "flow-stale")

      {:ok, stale_plan} = Plan.plan(ctx, %{ref: "reagent:local.flow-stale"})

      # Someone else finishes a walk first.
      {:ok, _} = walk!(ctx, "reagent:local.flow-stale")

      decisions = %{ref: "reagent:local.flow-stale"}
      {:ok, preview} = Commit.preview(ctx, decisions)

      assert {:error, {:consent_conflict, %{cause: :stale_plan, actual_revision: 1}}} =
               Commit.commit(ctx, %{
                 decisions: decisions,
                 plan_token: stale_plan.plan_token,
                 proof: preview.proof,
                 commit_digest: preview.commit_digest,
                 expected_consent_revision: stale_plan.expected_consent_revision
               })
    end

    test "a rebind between preview and commit changes the digest and refuses", %{ctx: ctx} do
      publish!(ctx, "flow-rebind")
      entry = entry!(ctx)

      decisions = %{
        ref: "reagent:local.flow-rebind",
        bindings: [%{need: "@ingress", entry_id: entry.id}]
      }

      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.flow-rebind"})
      {:ok, preview} = Commit.preview(ctx, decisions)

      {:ok, _} =
        Vault.rebind(ctx, %{
          id: entry.id,
          oauth_endpoints: %{"token_url" => "https://elsewhere.example/token"}
        })

      assert {:error, {:consent_conflict, %{cause: :digest_changed}}} =
               Commit.commit(ctx, %{
                 decisions: decisions,
                 plan_token: plan.plan_token,
                 proof: preview.proof,
                 commit_digest: preview.commit_digest,
                 expected_consent_revision: 0
               })
    end

    test "a shape move between plan and commit burns the plan token as digest_changed",
         %{ctx: ctx} do
      publish!(ctx, "flow-shape")
      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.flow-shape"})

      # A new release widens its ask — the live shape moves.
      publish!(ctx, "flow-shape", "1.0.1", %{
        manifest: Jason.encode!(%{"caps" => %{"tools" => ["component.search"]}})
      })

      decisions = %{ref: "reagent:local.flow-shape"}
      {:ok, preview} = Commit.preview(ctx, decisions)

      assert {:error, {:consent_conflict, %{cause: :digest_changed}}} =
               Commit.commit(ctx, %{
                 decisions: decisions,
                 plan_token: plan.plan_token,
                 proof: preview.proof,
                 commit_digest: preview.commit_digest,
                 expected_consent_revision: 0
               })
    end

    test "a committed walk cannot be replayed — the tokens are burned", %{ctx: ctx} do
      publish!(ctx, "flow-replay")

      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.flow-replay"})
      decisions = %{ref: "reagent:local.flow-replay"}
      {:ok, preview} = Commit.preview(ctx, decisions)

      params = %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: 0
      }

      assert {:ok, _} = Commit.commit(ctx, params)

      # Replay: the revision moved AND the tokens are gone; the revision
      # check fires first and reports the conflict honestly.
      assert {:error, {:consent_conflict, %{cause: :stale_plan}}} = Commit.commit(ctx, params)
    end
  end

  describe "authorization" do
    test "an api_key without a capability cannot commit", %{ctx: ctx} do
      publish!(ctx, "flow-key")
      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.flow-key"})
      decisions = %{ref: "reagent:local.flow-key"}
      {:ok, preview} = Commit.preview(ctx, decisions)

      key_ctx = %{ctx | auth_method: :api_key}

      assert {:error, :no_capability} =
               Commit.commit(key_ctx, %{
                 decisions: decisions,
                 plan_token: plan.plan_token,
                 proof: preview.proof,
                 commit_digest: preview.commit_digest,
                 expected_consent_revision: 0
               })
    end

    test "the tincture session surface can neither stage nor commit", %{ctx: ctx} do
      session_ctx = %{ctx | auth_method: :session}

      assert {:error, {:surface_not_permitted, :session}} =
               Plan.plan(session_ctx, %{ref: "reagent:local.anything"})
    end

    test "a guest-planed context is refused at staging", %{ctx: ctx} do
      guest = Sanctum.Context.enter_guest(ctx)

      assert {:error, :guest_plane} = Plan.plan(guest, %{ref: "reagent:local.anything"})
    end
  end

  describe "re-consent" do
    test "a fresh revision reactivates a needs_consent profile", %{ctx: ctx} do
      publish!(ctx, "flow-reauth")
      entry = entry!(ctx)

      {:ok, %{profile_id: profile_id}} =
        walk!(ctx, "reagent:local.flow-reauth", %{
          bindings: [%{need: "@ingress", entry_id: entry.id}]
        })

      # Rebinding the entry blocks the profile.
      {:ok, %{affected: [^profile_id]}} =
        Vault.rebind(ctx, %{id: entry.id, oauth_scopes: ["new.scope"]})

      {:ok, blocked} = Arca.ProfileStorage.get(ctx.org_id, profile_id)
      assert blocked.status == "needs_consent"

      # Re-consenting with the rebound entry unblocks it.
      assert {:ok, %{revision: 2}} =
               walk!(ctx, "reagent:local.flow-reauth", %{
                 bindings: [%{need: "@ingress", entry_id: entry.id}]
               })

      {:ok, unblocked} = Arca.ProfileStorage.get(ctx.org_id, profile_id)
      assert unblocked.status == "active"
    end
  end

  describe "tool-server grants" do
    test "a consent can grant an external server; the digest is resolved live", %{ctx: ctx} do
      publish!(ctx, "flow-mcp")

      {:ok, server} =
        Arca.McpServerStorage.put(ctx, %{
          name: "flowsrv",
          url: "https://127.0.0.1:9/mcp",
          config_json: Jason.encode!(%{"headers" => %{}, "timeout_ms" => 1_000})
        })

      {:ok, expected_digest} = Sanctum.ToolServerDigest.from_server(server)

      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.flow-mcp"})
      assert Enum.any?(plan.tool_server_candidates, &(&1.name == "flowsrv"))

      decisions = %{
        ref: "reagent:local.flow-mcp",
        tool_servers: [%{server_name: "flowsrv", tool_patterns: ["issues.*"]}]
      }

      {:ok, preview} = Commit.preview(ctx, decisions)

      {:ok, %{profile_id: profile_id}} =
        Commit.commit(ctx, %{
          decisions: decisions,
          plan_token: plan.plan_token,
          proof: preview.proof,
          commit_digest: preview.commit_digest,
          expected_consent_revision: 0
        })

      {:ok, head, _refs} = Arca.ConsentStorage.get_head(ctx.org_id, profile_id)
      blob = Jason.decode!(head.resolved_policy)

      [grant] =
        get_in(blob, ["nodes", "reagent:local.flow-mcp", "edges", "@ingress", "tool_servers"])

      assert grant["server_digest"] == expected_digest
      assert grant["server_name"] == "flowsrv"
      assert grant["tool_patterns"] == ["issues.*"]
    end

    test "an unknown server cannot be granted", %{ctx: ctx} do
      publish!(ctx, "flow-mcp-ghost")

      assert {:error, {:tool_server_not_found, "ghost"}} =
               Commit.preview(ctx, %{
                 ref: "reagent:local.flow-mcp-ghost",
                 tool_servers: [%{server_name: "ghost"}]
               })
    end
  end

  describe "publish" do
    defp publish_walk!(ctx, staged) do
      {:ok, preview} = Commit.preview(ctx, staged.decisions)

      Commit.commit(ctx, %{
        decisions: staged.decisions,
        plan_token: staged.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: staged.expected_consent_revision
      })
    end

    test "publishes an attenuated public twin: pinned, edge_only, zero limits, read-only storage",
         %{ctx: ctx} do
      publish!(ctx, "flow-pub")
      entry = entry!(ctx)

      {:ok, %{profile_id: owner_id}} =
        walk!(ctx, "reagent:local.flow-pub", %{
          bindings: [%{need: "@ingress", entry_id: entry.id, fields: ["url"]}]
        })

      {:ok, staged} =
        Commit.stage_publish(ctx, %{profile_id: owner_id, need_ids: ["@ingress"]})

      assert staged.decisions.kind == :public
      assert {:ok, %{profile_id: public_id, revision: 1}} = publish_walk!(ctx, staged)
      refute public_id == owner_id

      {:ok, head, refs} = Arca.ConsentStorage.get_head(ctx.org_id, public_id)
      assert head.scope == "pinned"
      assert head.pinned_version == "1.0.0"
      assert head.invoke_mode == "edge_only"
      # The kept credential rides along, digest-verified live.
      assert [%{vault_entry_id: ref_entry}] = refs
      assert ref_entry == entry.id

      blob = Jason.decode!(head.resolved_policy)
      source = blob["nodes"]["reagent:local.flow-pub"]
      assert source["limits"]["timeout"] == "30s"
      assert source["limits"]["max_concurrent_tasks"] == 1
      assert source["limits"]["max_memory_bytes"] == 67_108_864

      ingress = source["edges"]["@ingress"]
      actions = ingress["storage"]["actions"]
      assert Enum.all?(actions, &(&1 in ["read", "list", "exists"]))
      assert ingress["vault"]["entry_id"] == entry.id

      {:ok, profiles} = Source.DB.profiles(ctx, "reagent:local.flow-pub")
      public = Enum.find(profiles, &(&1.kind == :public))
      assert public.id == public_id
    end

    test "publishing without need_ids exposes no credentials", %{ctx: ctx} do
      publish!(ctx, "flow-pub-bare")
      entry = entry!(ctx)

      {:ok, %{profile_id: owner_id}} =
        walk!(ctx, "reagent:local.flow-pub-bare", %{
          bindings: [%{need: "@ingress", entry_id: entry.id}]
        })

      {:ok, staged} = Commit.stage_publish(ctx, %{profile_id: owner_id})
      {:ok, %{profile_id: public_id}} = publish_walk!(ctx, staged)

      {:ok, head, refs} = Arca.ConsentStorage.get_head(ctx.org_id, public_id)
      assert refs == []

      blob = Jason.decode!(head.resolved_policy)
      refute get_in(blob, ["nodes", "reagent:local.flow-pub-bare", "edges", "@ingress", "vault"])
    end

    test "publish requires a living owner profile", %{ctx: ctx} do
      assert {:error, :not_found} = Commit.stage_publish(ctx, %{profile_id: "prof_missing"})
    end
  end

  describe "decision validation" do
    test "an unknown need fails like §2.7 says", %{ctx: ctx} do
      publish!(ctx, "flow-need")
      entry = entry!(ctx)

      assert {:error, {:unknown_need, "dest"}} =
               Commit.preview(ctx, %{
                 ref: "reagent:local.flow-need",
                 bindings: [%{need: "dest", entry_id: entry.id}]
               })
    end

    test "a revoked entry cannot be bound", %{ctx: ctx} do
      publish!(ctx, "flow-revoked")
      entry = entry!(ctx)
      {:ok, _} = Vault.revoke(ctx, entry.id)

      assert {:error, {:entry_unavailable, _, "revoked"}} =
               Commit.preview(ctx, %{
                 ref: "reagent:local.flow-revoked",
                 bindings: [%{need: "@ingress", entry_id: entry.id}]
               })
    end
  end

  @needs_manifest %{
    "needs" => %{
      "api_key" => %{
        "type" => "api_key:anthropic.com",
        "reason" => "to call the API with your key",
        "fields" => ["ANTHROPIC_API_KEY"]
      }
    },
    "caps" => %{"egress" => %{"domains" => ["api.anthropic.com"]}}
  }

  defp publish_needs!(ctx, name) do
    publish!(ctx, name, "1.0.0", %{
      manifest:
        Jason.encode!(
          Map.merge(%{"name" => name, "version" => "1.0.0", "type" => "reagent"}, @needs_manifest)
        )
    })
  end

  describe "declared needs" do
    test "the plan shows the declared need's reason, never key names", %{ctx: ctx} do
      publish_needs!(ctx, "flow-needs-plan")

      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.flow-needs-plan"})

      assert [need] = plan.needs
      assert need.need == "api_key"
      assert need.reason =~ "to call the API"
      assert need.required
      # The declared ask sources the caps section.
      assert plan.caps["egress"]["domains"] == ["api.anthropic.com"]
      # No api_key connection exists yet — the plan says so up front.
      assert Enum.any?(plan.warnings, &(&1 =~ "api_key"))
    end

    test "binding the declared need mints a loadable revision with the projection",
         %{ctx: ctx} do
      publish_needs!(ctx, "flow-needs-bind")
      entry = entry!(ctx, %{fields: %{"ANTHROPIC_API_KEY" => "sk-1"}})

      assert {:ok, %{revision: 1}} =
               walk!(ctx, "reagent:local.flow-needs-bind", %{
                 bindings: [%{need: "api_key", entry_id: entry.id}]
               })

      {:ok, [profile]} = Source.DB.profiles(ctx, "reagent:local.flow-needs-bind")

      {:ok, component} =
        Compendium.Registry.get_latest(ctx, "flow-needs-bind", "local", "reagent")

      {:ok, live} = Compendium.Activation.resolve_verified(ctx, component)

      assert {:ok, auth, _stamp} =
               Loader.load_root(ctx, profile, source: Source.DB, live: {:ok, live})

      assert auth.resources.vault.entry_id == entry.id
      # The projection defaulted to the need's declared fields.
      assert auth.resources.vault.projection.fields == ["ANTHROPIC_API_KEY"]
      assert auth.resources.egress.domains == ["api.anthropic.com"]
    end

    test "the implicit slot retires when needs are declared (§2.7)", %{ctx: ctx} do
      publish_needs!(ctx, "flow-needs-implicit")
      entry = entry!(ctx)

      assert {:error, {:unknown_need, "@ingress"}} =
               Commit.preview(ctx, %{
                 ref: "reagent:local.flow-needs-implicit",
                 bindings: [%{need: "@ingress", entry_id: entry.id}]
               })

      assert {:error, {:unknown_need, "dest"}} =
               Commit.preview(ctx, %{
                 ref: "reagent:local.flow-needs-implicit",
                 bindings: [%{need: "dest", entry_id: entry.id}]
               })
    end

    test "a second binding has nowhere to ride and is refused", %{ctx: ctx} do
      publish_needs!(ctx, "flow-needs-two")
      a = entry!(ctx)
      b = entry!(ctx)

      assert {:error, :multiple_source_bindings_unrepresentable} =
               Commit.preview(ctx, %{
                 ref: "reagent:local.flow-needs-two",
                 bindings: [
                   %{need: "api_key", entry_id: a.id},
                   %{need: "api_key", entry_id: b.id}
                 ]
               })
    end

    test "setup readiness joins the declared needs", %{ctx: ctx} do
      publish_needs!(ctx, "flow-needs-ready")
      {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)

      # Bootstrapped with nothing bound: the required need is unmet.
      {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.flow-needs-ready")
      refute plan.ready
      assert Enum.any?(plan.consent.needs, &(&1[:need] == "api_key" and not &1.satisfied))

      # Binding through the walk (a delta revision) makes it ready.
      entry = entry!(ctx, %{fields: %{"ANTHROPIC_API_KEY" => "sk-2"}})

      assert {:ok, _} =
               walk!(ctx, "reagent:local.flow-needs-ready", %{
                 bindings: [%{need: "api_key", entry_id: entry.id}]
               })

      {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.flow-needs-ready")
      assert plan.ready
    end
  end
end
