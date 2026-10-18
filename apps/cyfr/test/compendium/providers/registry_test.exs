# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.RegistryTest do
  use ExUnit.Case, async: false

  alias Compendium.Providers.Registry, as: RegistryProvider
  alias Sanctum.Refusals

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # Valid mutation arguments must reach the credential check, not the missing-argument handler.
  describe "gated identity mutations reach their handlers with valid args" do
    test "tokens_revoke", %{ctx: ctx} do
      assert {:error, reason} =
               RegistryProvider.handle(ctx, %{
                 "action" => "tokens_revoke",
                 "slug" => "someslug",
                 "token_id" => "tok_1"
               })

      assert Refusals.render(reason) =~ "no push token"
    end

    test "members_add", %{ctx: ctx} do
      assert {:error, reason} =
               RegistryProvider.handle(ctx, %{
                 "action" => "members_add",
                 "slug" => "someslug",
                 "target_personal_slug" => "bob",
                 "role" => "member"
               })

      assert Refusals.render(reason) =~ "no push token"
    end

    test "members_update", %{ctx: ctx} do
      assert {:error, reason} =
               RegistryProvider.handle(ctx, %{
                 "action" => "members_update",
                 "slug" => "someslug",
                 "target_personal_slug" => "bob",
                 "role" => "admin"
               })

      assert Refusals.render(reason) =~ "no push token"
    end

    test "members_remove", %{ctx: ctx} do
      assert {:error, reason} =
               RegistryProvider.handle(ctx, %{
                 "action" => "members_remove",
                 "slug" => "someslug",
                 "target_personal_slug" => "bob"
               })

      assert Refusals.render(reason) =~ "no push token"
    end
  end

  describe "a push token that cannot be read" do
    @tag :capture_log
    test "a damaged stored token refuses as the damaged credential, not as 'no push token'",
         %{ctx: ctx} do
      registry = Compendium.RegistryHost.canonical_host()
      aad = Sanctum.CipherAAD.registry_token(ctx.user_id, registry, "damagedslug")
      {:ok, ciphertext} = Sanctum.Cipher.encrypt("not json", aad)

      :ok =
        Arca.RegistryTokenStorage.put(%{
          user_id: ctx.user_id,
          registry: registry,
          namespace_slug: "damagedslug",
          credential_ciphertext: ciphertext
        })

      assert {:error, {:corrupt, :registry_credential}} =
               RegistryProvider.handle(ctx, %{"action" => "tokens_list", "slug" => "damagedslug"})
    end

    @tag :capture_log
    test "a damaged row among the caller's tokens refuses the bearer choice, never another token",
         %{ctx: ctx} do
      registry = Compendium.RegistryHost.canonical_host()

      :ok =
        Compendium.Registry.CredentialStore.put_push_token(
          ctx,
          registry,
          "zeta.example",
          "cyfr_pt_usable",
          "personal"
        )

      aad = Sanctum.CipherAAD.registry_token(ctx.user_id, registry, "alice")
      {:ok, ciphertext} = Sanctum.Cipher.encrypt("not json", aad)

      :ok =
        Arca.RegistryTokenStorage.put(%{
          user_id: ctx.user_id,
          registry: registry,
          namespace_slug: "alice",
          credential_ciphertext: ciphertext
        })

      assert {:error, {:corrupt, :registry_credential} = reason} =
               RegistryProvider.handle(ctx, %{"action" => "list_my_reports"})

      assert %Prima.Refusal{class: :corrupt} = Refusals.classify(reason)
      assert Refusals.render(reason) =~ "sign in to the registry again"
    end

    @tag :capture_log
    test "a credential store that cannot answer refuses as unavailable", %{ctx: ctx} do
      Arca.Repo.query!("ALTER TABLE registry_tokens RENAME TO registry_tokens_unavailable")

      assert {:error, {:unavailable, "Registry credentials"}} =
               RegistryProvider.handle(ctx, %{"action" => "tokens_list", "slug" => "someslug"})

      assert {:error, {:unavailable, "Registry credentials"}} =
               RegistryProvider.handle(ctx, %{"action" => "whoami"})
    end
  end

  # A push token outlives the session that asks for it (`ARCHITECTURE.md`
  # §9.3): issuing one waits on a fresh confirmation, whose preview names
  # what is issued and holds no secret. The registry is a Bypass server,
  # which fails the test on any request it expects none of.
  describe "issuing another push token" do
    setup do
      bypass = Bypass.open()
      original_url = Application.get_env(:cyfr, :registry_url)
      original_scheme = Application.get_env(:cyfr, :registry_scheme)

      on_exit(fn ->
        restore_env(:cyfr, :registry_url, original_url)
        restore_env(:cyfr, :registry_scheme, original_scheme)
      end)

      Application.put_env(:cyfr, :registry_url, "127.0.0.1:#{bypass.port}")
      Application.put_env(:cyfr, :registry_scheme, "http")

      {person, _user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
      registry = Compendium.RegistryHost.canonical_host()

      :ok =
        Compendium.Registry.CredentialStore.put_push_token(
          person,
          registry,
          "alice",
          "cyfr_pt_held_bearer",
          "personal"
        )

      {:ok, bypass: bypass, person: person}
    end

    test "asks a fresh confirmation and reaches no registry until it is proven",
         %{person: person} do
      args = %{"action" => "tokens_issue", "slug" => "alice", "label" => "ci-runner"}

      assert {:error, {:confirmation_required, %{id: id, operation: "registry.tokens_issue"}}} =
               RegistryProvider.handle(person, args)

      {:ok, row} =
        Arca.PendingConfirmations.get(
          Sanctum.Context.actor(person),
          Prima.Confirmation.ref(id)
        )

      assert row.action == "credential_issuance"
      preview = Jason.decode!(row.preview)
      assert preview["operation"] == "registry.tokens_issue"
      assert preview["resource"] == "alice"
      assert preview["details"]["label"] == "ci-runner"
      refute inspect(row) =~ "cyfr_pt_"
    end

    test "issues the token once the person proves it", %{bypass: bypass, person: person} do
      Bypass.expect_once(bypass, "POST", "/v1/namespaces/alice/tokens", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == [
                 "Bearer cyfr_pt_held_bearer"
               ]

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"label" => "ci-runner"}

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{"id" => "tok_2", "token" => "cyfr_pt_issued"}))
      end)

      args = %{"action" => "tokens_issue", "slug" => "alice", "label" => "ci-runner"}

      assert {:ok, body} =
               Sanctum.TestContext.confirming(person, &RegistryProvider.handle(&1, args))

      assert inspect(body) =~ "cyfr_pt_issued"
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  describe "gated identity mutations still refuse incomplete args" do
    test "each arg-missing arm answers its own sentence", %{ctx: ctx} do
      for {action, sentence} <- [
            {"tokens_revoke", "requires 'slug' and 'token_id'"},
            {"members_add", "requires 'slug', 'target_personal_slug', and 'role'"},
            {"members_update", "requires 'slug', 'target_personal_slug', and 'role'"},
            {"members_remove", "requires 'slug' and 'target_personal_slug'"}
          ] do
        assert {:error, reason} = RegistryProvider.handle(ctx, %{"action" => action}),
               "expected a refusal for bare #{action}"

        assert Refusals.render(reason) =~ sentence,
               "expected the arg-missing sentence for #{action}, got: #{inspect(reason)}"
      end
    end
  end

  # Each action as its handler reaches the registry
  # (`Compendium.Registry.Client`): a POST or PATCH changes something
  # there, a DELETE deletes it, a GET reads.
  @remote_changes ~w(probe claim_personal claim_publisher verify_publisher tokens_issue
                     members_add members_update report legal_accept appeal)
  @remote_deletes ~w(tokens_revoke members_remove)
  @reads ~w(tokens_list members_list whoami get_namespace list_my_reports legal_page
            legal_version)

  describe "an action that changes the registry" do
    test "is external, or destructive where it deletes, and takes no standing answer; a read stays a read" do
      operations = Map.new(RegistryProvider.definition().operations, &{&1.action, &1})

      assert Enum.sort(Map.keys(operations)) ==
               Enum.sort(@remote_changes ++ @remote_deletes ++ @reads)

      for action <- @remote_changes,
          do: assert(%{kind: :external, standing: false} = operations[action], action)

      for action <- @remote_deletes,
          do: assert(%{kind: :destructive, standing: false} = operations[action], action)

      for action <- @reads, do: assert(%{kind: :read} = operations[action], action)
    end

    test "never runs without a card and takes no standing allow at either scope; a deny stands",
         %{ctx: ctx} do
      for action <- @remote_changes ++ @remote_deletes do
        kind = if action in @remote_deletes, do: :destructive, else: :external
        refute Aqua.Kinds.auto_permitted?("registry", action), action

        for place <- [%{scope: "thread", thread_id: "thr_registry"}, %{scope: "agent"}] do
          grant = Map.merge(place, %{agent_name: "aqua", tool: "registry", action: action})

          assert {:error, {:scope_not_permitted, ^kind}} =
                   Sanctum.ToolGrants.grant_row(ctx, Map.put(grant, :effect, "allow")),
                 action

          assert {:ok, %{effect: "deny"}} =
                   Sanctum.ToolGrants.grant_row(ctx, Map.put(grant, :effect, "deny")),
                 action
        end

        # A row the rule would refuse, read back, is no allow.
        stored = %{
          scope: "thread",
          effect: "allow",
          thread_id: "thr_registry",
          agent_name: "aqua",
          tool: "registry",
          action: action
        }

        assert {:error, {:scope_not_permitted, ^kind}} =
                 Sanctum.ToolGrants.check_standing(stored, DateTime.utc_now()),
               action
      end
    end
  end
end
