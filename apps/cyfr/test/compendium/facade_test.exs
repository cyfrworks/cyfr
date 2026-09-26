# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.FacadeTest do
  @moduledoc """
  The component domain's door for callers outside it: an exact roster, so
  an entry added without a roster change fails here; each group of
  delegating entries answers what the internal it names answers; and the
  component facts the assistant reads — the athanor's model catalysts, its
  agent sources and its own formulas — each refused for a caller that may
  not read them and answered `:unavailable`, never empty, when the index
  or the store cannot answer.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path =
      Path.join(System.tmp_dir!(), "compendium_facade_#{System.unique_integer([:positive])}")

    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    # A filled athanor of its own, so a listing starts no fill behind the test.
    n = System.unique_integer([:positive])
    user = "local|idp|facade-#{n}"
    {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(user, "Facade #{n}")
    {:ok, _} = Sanctum.Tenancy.Athanors.mark_provisioned(athanor)
    ctx = %{Sanctum.TestContext.local() | user_id: user, athanor_id: athanor.id}

    {:ok, ctx: ctx}
  end

  defp put_component!(ctx, type, name, version, manifest) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Context.actor(ctx), %{
        id: "facade_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: version,
        component_type: type,
        description: name,
        tags: "[]",
        digest: "sha256:#{name}-#{version}",
        size: 1,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    :ok
  end

  @roster [
    accept_registry_policies: 4,
    acknowledged_projection_epoch: 2,
    acknowledged_projection_epoch: 3,
    agent: 2,
    agent_capability_digest: 1,
    agent_clone_glob: 1,
    agent_file_path: 1,
    agent_role_type: 0,
    agent_row: 2,
    agent_snapshot: 2,
    agent_soul_type: 0,
    agent_source_refs: 1,
    agent_type_of: 1,
    agents: 1,
    claim_personal_namespace: 3,
    complete_sign_in: 4,
    discover_components: 1,
    enabled_agent_roster: 1,
    encode_activation_graph: 1,
    get_blob: 2,
    group_by_component: 1,
    group_search_results: 1,
    inspect_component: 2,
    local_formula_refs: 1,
    manifest_leaves: 1,
    model_catalysts: 1,
    parse_agent: 2,
    parse_agent_frontmatter: 1,
    parse_component_path: 1,
    registry_legal_page: 1,
    registry_legal_version: 0,
    registry_required_version: 1,
    resolve: 2,
    resolve_activation: 2,
    resolve_verified_activation: 2,
    skill_dir: 1,
    skills_index: 2,
    skills_index_limit: 0,
    soul_agent_file?: 1,
    store_push_token: 3,
    sync_seeds: 0,
    tincture_asset_rules: 0,
    tincture_entry: 1,
    tincture_media: 2,
    valid_agent_name?: 1,
    valid_tincture_connect_domain?: 1
  ]

  test "the root answers exactly its roster" do
    exported =
      Compendium.__info__(:functions)
      |> Enum.reject(fn {name, _arity} -> name in [:__info__, :module_info] end)
      |> Enum.sort()

    assert exported == @roster
  end

  describe "delegating entries" do
    test "components: blobs, resolution and activation answer as their internals", %{ctx: ctx} do
      assert Compendium.get_blob(ctx, "sha256:absent") ==
               Compendium.Component.get_blob(ctx, "sha256:absent")

      assert Compendium.resolve(ctx, "catalyst:local.absent") ==
               Compendium.Resolver.resolve(ctx, "catalyst:local.absent")

      graph = %{"catalyst:local.b" => "catalyst:local.b:1.0.0"}

      assert Compendium.encode_activation_graph(graph) ==
               Compendium.Activation.encode_graph(graph)
    end

    test "path grammars answer as Compendium.ComponentPath and Compendium.AquaPath" do
      segments = ["components", "catalysts", "local", "claude", "1.0.0", "cyfr-manifest.json"]

      assert Compendium.parse_component_path(segments) ==
               Compendium.ComponentPath.parse(segments)

      assert {:ok, %{type: "catalyst", name: "claude"}} =
               Compendium.parse_component_path(segments)

      assert Compendium.parse_component_path(["elsewhere"]) == :error

      leaves = [segments, ["components", "catalysts", "local", "claude", "1.0.0", "x.wasm"]]

      assert Compendium.manifest_leaves(leaves) ==
               Compendium.ComponentPath.manifest_leaves(leaves)

      assert Compendium.valid_agent_name?("scout")
      refute Compendium.valid_agent_name?("../scout")
      assert Compendium.agent_file_path("scout") == Compendium.AquaPath.agent_file("scout")
      assert Compendium.skill_dir("summarise") == Compendium.AquaPath.skill_dir("summarise")
      assert Compendium.soul_agent_file?("aqua")
      refute Compendium.soul_agent_file?("scout")
    end

    test "agents and skills answer as Compendium.AquaAgent and Compendium.AquaSkills", %{
      ctx: ctx
    } do
      assert Compendium.agent_role_type() == Compendium.AquaAgent.role_type()
      assert Compendium.agent_soul_type() == Compendium.AquaAgent.soul_type()
      assert Compendium.agent_clone_glob("scout") == "scout.*"
      assert Compendium.skills_index_limit() == Compendium.AquaSkills.index_limit()

      assert Compendium.parse_agent_frontmatter("no frontmatter") ==
               {:error, :frontmatter_missing}

      assert Compendium.agent(ctx, "absent") == Compendium.AquaAgent.get(ctx, "absent")
    end

    test "catalogue grouping answers as Compendium.Catalogue" do
      assert Compendium.group_by_component([]) == Compendium.Catalogue.group_by_component([])
      assert Compendium.group_search_results([]) == Compendium.Catalogue.group_search_results([])
    end

    test "a registry refusal's required policy version is read off its reason" do
      err = %Compendium.OCI.Errors{
        reason: :policy_version_mismatch,
        status: 412,
        detail: %{original_detail: %{"required_version" => "2026-09"}}
      }

      refusal = Compendium.Providers.Shared.refusal(err)

      assert %Prima.Refusal{
               class: :conflict,
               reason: {:registry, :policy_version_mismatch, "2026-09"}
             } = refusal

      assert Grimoire.render(refusal) =~ "policy version 2026-09"
      assert Compendium.registry_required_version(refusal) == "2026-09"

      assert Compendium.registry_required_version(
               Compendium.Providers.Shared.refusal(%{err | detail: nil})
             ) == nil

      assert Compendium.registry_required_version(Grimoire.classify(:busy)) == nil
    end
  end

  describe "claim_personal_namespace/3" do
    setup do
      bypass = Bypass.open()
      original_url = Application.get_env(:cyfr, :registry_url)
      original_scheme = Application.get_env(:cyfr, :registry_scheme)

      Application.put_env(:cyfr, :registry_url, "127.0.0.1:#{bypass.port}")
      Application.put_env(:cyfr, :registry_scheme, "http")

      on_exit(fn ->
        if original_url,
          do: Application.put_env(:cyfr, :registry_url, original_url),
          else: Application.delete_env(:cyfr, :registry_url)

        if original_scheme,
          do: Application.put_env(:cyfr, :registry_scheme, original_scheme),
          else: Application.delete_env(:cyfr, :registry_scheme)
      end)

      {:ok, bypass: bypass}
    end

    defp json_resp(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    test "a claim answers the namespace and its push token, and stores nothing", %{
      bypass: bypass,
      ctx: ctx
    } do
      Bypass.expect_once(bypass, "POST", "/v1/namespaces/personal/claim", fn conn ->
        json_resp(conn, 200, %{"slug" => "alice", "token" => "cyfr_pt_claimed"})
      end)

      assert {:ok, %{slug: "alice", token: "cyfr_pt_claimed"}} =
               Compendium.claim_personal_namespace("alice", :github, "gho_access")

      assert {:error, :not_found} =
               Compendium.Registry.CredentialStore.get(
                 ctx,
                 Compendium.RegistryHost.canonical_host(),
                 "alice"
               )
    end

    test "a policy the person has not accepted is the registry's refusal", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/namespaces/personal/claim", fn conn ->
        json_resp(conn, 412, %{"errors" => [%{"code" => "POLICY_ACCEPTANCE_REQUIRED"}]})
      end)

      assert {:error, %Prima.Refusal{reason: {:registry, :policy_acceptance_required}}} =
               Compendium.claim_personal_namespace("alice", :github, "gho_access")
    end

    test "a spent IdP token and an unreachable registry are refusals too", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/namespaces/personal/claim", fn conn ->
        json_resp(conn, 401, %{"errors" => [%{"code" => "INVALID_ACCESS_TOKEN"}]})
      end)

      assert {:error, %Prima.Refusal{class: :unauthenticated, reason: :invalid_access_token}} =
               Compendium.claim_personal_namespace("alice", :github, "gho_spent")

      Bypass.down(bypass)

      assert {:error, %Prima.Refusal{class: :unavailable, reason: {:registry, _}}} =
               Compendium.claim_personal_namespace("alice", :github, "gho_access")
    end

    test "a policy acceptance the registry refuses is its refusal, with the version it requires",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/legal/accept", fn conn ->
        json_resp(conn, 412, %{
          "errors" => [%{"code" => "POLICY_VERSION_MISMATCH"}],
          "required_version" => "2026-10"
        })
      end)

      assert {:error,
              %Prima.Refusal{
                class: :conflict,
                reason: {:registry, :policy_version_mismatch, "2026-10"}
              } = refusal} =
               Compendium.accept_registry_policies(:github, "gho_access", nil, "2026-09")

      assert Compendium.registry_required_version(refusal) == "2026-10"
      assert Grimoire.render(refusal) =~ "policy version 2026-10"

      Bypass.expect_once(bypass, "POST", "/v1/legal/accept", fn conn ->
        json_resp(conn, 403, %{"errors" => [%{"code" => "IDENTITY_BANNED"}]})
      end)

      assert {:error, %Prima.Refusal{reason: {:registry, :unauthorized}}} =
               Compendium.accept_registry_policies(:github, "gho_access", nil, "2026-09")

      Bypass.down(bypass)

      assert {:error, %Prima.Refusal{class: :unavailable}} = Compendium.registry_legal_version()
      assert {:error, %Prima.Refusal{class: :unavailable}} = Compendium.registry_legal_page("tos")
    end
  end

  describe "store_push_token/3" do
    test "stores the token as the caller's, for this deployment's registry", %{ctx: ctx} do
      registry = Compendium.RegistryHost.canonical_host()

      assert :ok = Compendium.store_push_token(ctx, "alice", "cyfr_pt_stored")

      assert {:ok, %{type: :push_token, token: "cyfr_pt_stored", role: "personal"}} =
               Compendium.Registry.CredentialStore.get(ctx, registry, "alice")

      other = %{ctx | user_id: "local|idp|facade-other-#{System.unique_integer([:positive])}"}
      assert {:error, _} = Compendium.Registry.CredentialStore.get(other, registry, "alice")
    end

    test "a token that is not one is skipped, as the credential store skips it", %{ctx: ctx} do
      assert :skipped = Compendium.store_push_token(ctx, "alice", nil)
      assert :skipped = Compendium.store_push_token(ctx, "alice", "")
    end
  end

  describe "model_catalysts/1" do
    test "every installed catalyst release, with the contracts its manifest declares", %{
      ctx: ctx
    } do
      chat = %{"contracts" => ["model/chat@1"]}
      :ok = put_component!(ctx, "catalyst", "claude", "1.2.0", chat)
      :ok = put_component!(ctx, "catalyst", "claude", "1.10.0", chat)
      :ok = put_component!(ctx, "catalyst", "files", "0.3.0", %{})
      :ok = put_component!(ctx, "formula", "not-a-catalyst", "1.0.0", chat)

      assert {:ok, rows} = Compendium.model_catalysts(ctx)

      assert rows |> Enum.map(&{&1.ref, &1.contracts}) |> Enum.sort() == [
               {"catalyst:local.claude:1.10.0", ["model/chat@1"]},
               {"catalyst:local.claude:1.2.0", ["model/chat@1"]},
               {"catalyst:local.files:0.3.0", []}
             ]

      for row <- rows do
        assert Map.keys(row) |> Enum.sort() ==
                 [:contracts, :name, :node_key, :publisher, :ref, :version]

        assert row.node_key == "catalyst:local.#{row.name}"
      end
    end

    test "refuses a caller that is not an authenticated reader focused on an athanor", %{
      ctx: ctx
    } do
      assert {:error, :forbidden} = Compendium.model_catalysts(%{ctx | authenticated: false})

      assert {:error, :forbidden} =
               Compendium.model_catalysts(%{ctx | athanor_id: nil, scope: :platform})

      assert {:error, :forbidden} = Compendium.model_catalysts(%{ctx | scope: :platform})

      assert {:error, :forbidden} =
               Compendium.model_catalysts(%{ctx | permissions: MapSet.new([:execute])})

      assert {:error, :forbidden} = Compendium.model_catalysts(Context.enter_guest(ctx))
    end

    test "an index behind its tree is unavailable, not an empty athanor", %{ctx: ctx} do
      :ok = put_component!(ctx, "catalyst", "claude", "1.0.0", %{"contracts" => ["model/chat@1"]})
      assert {:ok, [_]} = Compendium.model_catalysts(ctx)

      {:ok, _pending} =
        Arca.StorageProjectionChanges.begin_edit(
          Context.actor(ctx),
          "components",
          "catalysts/local/claude/1.0.0"
        )

      assert {:error, :unavailable} = Compendium.model_catalysts(ctx)
    end
  end

  describe "agent_source_refs/1" do
    test "an athanor that names no athanor is forbidden", %{ctx: ctx} do
      assert {:error, :forbidden} = Compendium.agent_source_refs(%{ctx | athanor_id: nil})
    end

    test "an agent index behind its tree is unavailable, not an empty roster", %{ctx: ctx} do
      assert {:ok, rows} = Compendium.agent_source_refs(ctx)
      assert is_list(rows)

      {:ok, _pending} =
        Arca.StorageProjectionChanges.begin_edit(Context.actor(ctx), "aqua", "roles/scout.md")

      assert {:error, :unavailable} = Compendium.agent_source_refs(ctx)
    end
  end

  describe "local_formula_refs/1" do
    test "the athanor's own formulas as name-level refs, once each", %{ctx: ctx} do
      :ok = put_component!(ctx, "formula", "report", "1.0.0", %{})
      :ok = put_component!(ctx, "formula", "report", "1.1.0", %{})
      :ok = put_component!(ctx, "catalyst", "claude", "1.0.0", %{})

      assert {:ok, ["formula:local.report"]} = Compendium.local_formula_refs(ctx)
    end

    test "an athanor that names no athanor is forbidden", %{ctx: ctx} do
      assert {:error, :forbidden} = Compendium.local_formula_refs(%{ctx | athanor_id: nil})
    end
  end
end
