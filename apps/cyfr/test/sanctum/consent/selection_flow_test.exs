# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.SelectionFlowTest do
  @moduledoc """
  A person's consent selects which of a dependency's profiles lends its
  key: the plan offers the dependency's bound profiles, the commit pins
  the lender's binding digest and the digest covers the choice, the
  loaded authority carries the lender's entry on that edge, and two
  sources selecting two profiles of one dependency run it with two keys.
  """

  use ExUnit.Case, async: false

  alias Prima.Authority.Blob
  alias Prima.Authority.Transition
  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Plan
  alias Sanctum.Providers.Profile
  alias Prima.Test.AuthorityFixtures, as: Fixtures
  alias Sanctum.Vault

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))
  @dep "reagent:local.sel-dep"
  @role_a "reagent:local.sel-role-a"
  @role_b "reagent:local.sel-role-b"
  @root "reagent:local.sel-root"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "consent_selection_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    ctx = Sanctum.TestContext.local()

    # The dependency declares one credential need; each source depends on it.
    publish!(ctx, "sel-dep", %{
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:example.com",
          "reason" => "to call the example API",
          "required" => true,
          "fields" => ["KEY", "ORG"]
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.example.com"]}}
    })

    for name <- ~w(sel-source sel-source-two) do
      publish!(ctx, name, %{"dependencies" => %{"static" => [%{"ref" => @dep}]}})
    end

    {:ok, ctx: ctx}
  end

  defp publish!(ctx, name, manifest_extra) do
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

  defp entry!(ctx, name, fields) do
    {:ok, view} = Vault.create(ctx, %{name: name, kind: "api_key", fields: fields})
    view
  end

  defp walk!(ctx, ref, decisions_over) do
    {:ok, plan} = Plan.plan(ctx, Map.take(Map.merge(%{ref: ref}, decisions_over), [:ref, :label]))
    decisions = Map.merge(%{ref: ref}, decisions_over)
    {:ok, preview} = Commit.preview(ctx, decisions)

    result =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    {result, preview}
  end

  # The dependency's profiles: "default" bound to one key, "work" to another.
  defp lenders!(ctx) do
    home = entry!(ctx, "home key", %{"KEY" => "k-home", "ORG" => "o-home"})
    work = entry!(ctx, "work key", %{"KEY" => "k-work", "ORG" => "o-work"})

    {{:ok, %{profile_id: default}}, _} =
      walk!(ctx, @dep, %{bindings: [%{need: "api_key", entry_id: home.id}]})

    {{:ok, %{profile_id: work_profile}}, _} =
      walk!(ctx, @dep, %{
        label: "work",
        bindings: [%{need: "api_key", entry_id: work.id, fields: ["KEY"]}]
      })

    %{default: default, work: work_profile, home_entry: home, work_entry: work}
  end

  defp edge_vault(ctx, source_ref) do
    {:ok, authority} = Crucible.authority_for(ctx, :default, source_ref)
    {:ok, edge} = Blob.lookup_edge(authority.policy, source_ref, @dep, "")
    edge.vault
  end

  test "the plan offers the dependency's bound profiles as lenders", %{ctx: ctx} do
    lenders = lenders!(ctx)
    {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.sel-source"})

    assert [
             %{from: "reagent:local.sel-source", dep: @dep, needs: [need], candidates: candidates}
           ] = plan.dependency_needs

    assert need.need == "api_key" and need.reason =~ "example API"

    assert Enum.sort_by(candidates, & &1.label) == [
             %{
               profile_id: lenders.default,
               label: "default",
               entry_id: lenders.home_entry.id,
               entry_name: "home key",
               fields: ["KEY", "ORG"]
             },
             %{
               profile_id: lenders.work,
               label: "work",
               entry_id: lenders.work_entry.id,
               entry_name: "work key",
               fields: ["KEY"]
             }
           ]
  end

  test "two sources select two profiles of one dependency and run it with two keys", %{
    ctx: ctx
  } do
    lenders = lenders!(ctx)

    {{:ok, %{profile_id: _}}, preview} =
      walk!(ctx, "reagent:local.sel-source", %{
        selections: [%{dep: @dep, label: "default"}]
      })

    assert Enum.any?(
             preview.summary,
             &(&1 =~ "runs with home key, the key bound on its 'default' profile")
           )

    {{:ok, _}, _} =
      walk!(ctx, "reagent:local.sel-source-two", %{
        selections: [%{dep: @dep, label: "work", fields: ["KEY"]}]
      })

    {:ok, home_row} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), lenders.home_entry.id)
    {:ok, home_digest} = Sanctum.VaultReader.binding_digest(home_row)

    home_id = lenders.home_entry.id
    work_id = lenders.work_entry.id

    assert %{
             entry_id: ^home_id,
             binding_digest: ^home_digest,
             projection: %{fields: ["KEY", "ORG"]}
           } =
             edge_vault(ctx, "reagent:local.sel-source")

    assert %{entry_id: ^work_id, projection: %{fields: ["KEY"], scopes: []}} =
             edge_vault(ctx, "reagent:local.sel-source-two")

    # The stored blob carries the selection, pinned, and references no entry
    # of its own.
    {:ok, [profile]} =
      Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "reagent:local.sel-source")

    {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile.id)
    assert head.vault_refs == []
    {:ok, blob} = Blob.parse(head.resolved_policy)
    {:ok, edge} = Blob.lookup_edge(blob, "reagent:local.sel-source", @dep, "")
    assert %{via: %{label: "default", binding_digest: ^home_digest}} = edge.vault
  end

  test "the commit digest covers the selection", %{ctx: ctx} do
    _lenders = lenders!(ctx)
    {:ok, plain} = Commit.preview(ctx, %{ref: "reagent:local.sel-source"})

    {:ok, selected} =
      Commit.preview(ctx, %{
        ref: "reagent:local.sel-source",
        selections: [%{dep: @dep, label: "default"}]
      })

    {:ok, other} =
      Commit.preview(ctx, %{
        ref: "reagent:local.sel-source",
        selections: [%{dep: @dep, label: "work"}]
      })

    assert plain.commit_digest != selected.commit_digest
    assert selected.commit_digest != other.commit_digest
  end

  test "a selection names a dependency, an active owner profile of it that binds a key, and fields it lends",
       %{ctx: ctx} do
    lenders = lenders!(ctx)
    ref = "reagent:local.sel-source"

    assert {:error, {:selection_target_unknown, "reagent:local.nope"}} =
             Commit.preview(ctx, %{
               ref: ref,
               selections: [%{dep: "reagent:local.nope", label: "default"}]
             })

    assert {:error, {:selection_profile_unavailable, @dep, "nope"}} =
             Commit.preview(ctx, %{ref: ref, selections: [%{dep: @dep, label: "nope"}]})

    # A profile of the dependency that binds nothing lends nothing.
    {{:ok, %{profile_id: _unbound}}, _} = walk!(ctx, @dep, %{label: "empty"})

    assert {:error, {:selection_unbound, @dep, "empty"}} =
             Commit.preview(ctx, %{ref: ref, selections: [%{dep: @dep, label: "empty"}]})

    assert {:error, {:selection_fields_unavailable, @dep, ["ORG"]}} =
             Commit.preview(ctx, %{
               ref: ref,
               selections: [%{dep: @dep, label: "work", fields: ["ORG"]}]
             })

    # A revoked lender is not offered and not accepted.
    :ok = Arca.ProfileStorage.set_status(Sanctum.Context.actor(ctx), lenders.work, "revoked")
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    [%{candidates: candidates}] = plan.dependency_needs
    refute Enum.any?(candidates, &(&1.profile_id == lenders.work))

    assert {:error, {:selection_profile_unavailable, @dep, _}} =
             Commit.preview(ctx, %{ref: ref, selections: [%{dep: @dep, label: "work"}]})
  end

  test "a grant keeps the head's selections, and a revoked lender stops lending", %{ctx: ctx} do
    lenders = lenders!(ctx)
    ref = "reagent:local.sel-source"

    {{:ok, %{profile_id: profile_id}}, _} =
      walk!(ctx, ref, %{selections: [%{dep: @dep, label: "default"}]})

    own = entry!(ctx, "own key", %{"token" => "t"})

    assert {:ok, %{revision: 2}} =
             Commit.grant(ctx, %{
               profile_id: profile_id,
               bindings: [%{need: "@ingress", entry_id: own.id}],
               expected_consent_revision: 1
             })

    home_id = lenders.home_entry.id
    assert %{entry_id: ^home_id} = edge_vault(ctx, ref)

    # Revoking the lender's profile is one act that reaches every source
    # selecting it: the edge stays a selection no run can unseal.
    :ok = Arca.ProfileStorage.set_status(Sanctum.Context.actor(ctx), lenders.default, "revoked")
    assert %{via: %{label: "default"}} = edge_vault(ctx, ref)
  end

  test "the profile tool decodes selections on the wire", %{ctx: ctx} do
    _lenders = lenders!(ctx)
    ref = "reagent:local.sel-source"
    {:ok, plan} = Profile.handle(ctx, %{"action" => "plan", "ref" => ref})

    decisions = %{
      "ref" => ref,
      "selections" => [%{"dep" => @dep, "fields" => ["KEY"]}]
    }

    {:ok, preview} =
      Profile.handle(ctx, %{"action" => "preview", "decisions" => decisions})

    {:ok, %{status: "committed"}} =
      Profile.handle(ctx, %{
        "action" => "commit",
        "decisions" => decisions,
        "plan_token" => plan.plan_token,
        "proof" => preview.proof,
        "commit_digest" => preview.commit_digest,
        "expected_consent_revision" => plan.expected_consent_revision
      })

    assert %{projection: %{fields: ["KEY"]}} = edge_vault(ctx, ref)

    {:ok, with_from} =
      Profile.handle(ctx, %{
        "action" => "preview",
        "decisions" => %{
          "ref" => ref,
          "selections" => [%{"from" => ref, "dep" => @dep, "label" => "default"}]
        }
      })

    assert is_binary(with_from.commit_digest)

    assert {:error, msg} =
             Profile.handle(ctx, %{
               "action" => "preview",
               "decisions" => %{
                 "ref" => ref,
                 "selections" => [%{"dep" => @dep, "label" => "nope"}]
               }
             })

    assert msg =~ "selection_profile_unavailable"
  end

  test "two roles on one catalyst carry two keys under one root", %{ctx: ctx} do
    lenders = lenders!(ctx)
    tree!(ctx)

    {{:ok, _}, preview} =
      walk!(ctx, @root, %{
        selections: [
          %{from: @role_a, dep: @dep, label: "default"},
          %{from: @role_b, dep: @dep, label: "work"}
        ]
      })

    {:ok, same_from_a} =
      Commit.preview(ctx, %{
        ref: @root,
        selections: [%{from: @role_a, dep: @dep, label: "default"}]
      })

    {:ok, same_from_b} =
      Commit.preview(ctx, %{
        ref: @root,
        selections: [%{from: @role_b, dep: @dep, label: "default"}]
      })

    assert preview.commit_digest != same_from_a.commit_digest
    assert same_from_a.commit_digest != same_from_b.commit_digest

    {:ok, plan} = Plan.plan(ctx, %{ref: @root})

    assert [
             %{from: @role_a, dep: @dep},
             %{from: @role_b, dep: @dep}
           ] = Enum.sort_by(plan.dependency_needs, & &1.from)

    home_id = lenders.home_entry.id
    work_id = lenders.work_entry.id

    assert %{entry_id: ^home_id} = root_edge_vault(ctx, @role_a)
    assert %{entry_id: ^work_id} = root_edge_vault(ctx, @role_b)

    {:ok, authority} = Crucible.authority_for(ctx, :default, @root)

    {:child, via_a} =
      authority
      |> Transition.step(:call, Fixtures.invoke(@role_a, need: nil, declared_needs: []))
      |> then(fn {:child, child} ->
        Transition.step(child, :call, Fixtures.invoke(@dep, need: nil, declared_needs: []))
      end)

    {:child, via_b} =
      authority
      |> Transition.step(:call, Fixtures.invoke(@role_b, need: nil, declared_needs: []))
      |> then(fn {:child, child} ->
        Transition.step(child, :call, Fixtures.invoke(@dep, need: nil, declared_needs: []))
      end)

    assert via_a.resources.vault.entry_id == home_id
    assert via_b.resources.vault.entry_id == work_id

    :ok = Arca.ProfileStorage.set_status(Sanctum.Context.actor(ctx), lenders.work, "revoked")
    assert %{entry_id: ^home_id} = root_edge_vault(ctx, @role_a)
    assert %{via: %{label: "work"}} = root_edge_vault(ctx, @role_b)
  end

  test "one key may ride two edges under two projections", %{ctx: ctx} do
    lenders = lenders!(ctx)
    tree!(ctx)

    {{:ok, _}, _} =
      walk!(ctx, @root, %{
        selections: [
          %{from: @role_a, dep: @dep, label: "default", fields: ["KEY"]},
          %{from: @role_b, dep: @dep, label: "default", fields: ["KEY", "ORG"]}
        ]
      })

    home_id = lenders.home_entry.id

    assert %{entry_id: ^home_id, projection: %{fields: ["KEY"]}} =
             root_edge_vault(ctx, @role_a)

    assert %{entry_id: ^home_id, projection: %{fields: ["KEY", "ORG"]}} =
             root_edge_vault(ctx, @role_b)
  end

  defp tree!(ctx) do
    publish!(ctx, "sel-role-a", %{"dependencies" => %{"static" => [%{"ref" => @dep}]}})
    publish!(ctx, "sel-role-b", %{"dependencies" => %{"static" => [%{"ref" => @dep}]}})

    publish!(ctx, "sel-root", %{
      "dependencies" => %{"static" => [%{"ref" => @role_a}, %{"ref" => @role_b}]}
    })
  end

  defp root_edge_vault(ctx, from) do
    {:ok, authority} = Crucible.authority_for(ctx, :default, @root)
    {:ok, edge} = Blob.lookup_edge(authority.policy, from, @dep, "")
    edge.vault
  end
end
