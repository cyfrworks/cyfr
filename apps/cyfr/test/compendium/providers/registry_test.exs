# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.RegistryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Compendium.Providers.Registry, as: RegistryProvider
  alias Compendium.Registry.CredentialStore
  alias Sanctum.Refusals
  alias Sanctum.Test.{DirectoryServer, RegistryStub}

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # Valid mutation arguments reach the credential check.
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
      assert Refusals.render(reason) =~ "cyfr registry sync"
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

      on_exit(fn ->
        restore_env(:cyfr, :registry_url, original_url)
      end)

      Application.put_env(:cyfr, :registry_url, "127.0.0.1:#{bypass.port}")

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

  # Every operation a person makes at the registry is a request a key of
  # their account signs (`Prima.RegistryRequest`), in two calls of one
  # action: without an answer it answers the request to sign; with the
  # terminal's signed request, or a passkey's answer from the account
  # pages, it sends it and does what its success does. The registry is a
  # stub that checks each request is the one the device signed, and fails
  # the case on any other.
  describe "the operations a person signs" do
    setup do
      user = RegistryStub.person!()
      device = Sanctum.Test.Devices.paired!(user.id)
      {:ok, ctx} = Sanctum.DeviceCerts.verify_request(device.certificate, device.ctx)
      {:ok, identifier} = Sanctum.Tenancy.Users.identifier(user.id)
      %{user: user, device: device, ctx: ctx, identifier: identifier}
    end

    # The registry: each request checked as the device's signature over its
    # own bytes, and answered by `answer.(request)`.
    defp registry(%{key: {pub, _priv}}, answer) do
      RegistryStub.start!(fn %{body: body} = request ->
        {:ok, signed} = body |> Jason.decode!() |> Prima.RegistryRequest.decode()

        if signed.signer == Prima.Identity.Key.kid(pub) and
             :crypto.verify(
               :eddsa,
               :none,
               Prima.RegistryRequest.signing_bytes(signed),
               signed.sig,
               [pub, :ed25519]
             ),
           do: answer.(Map.put(request, :signed, signed)),
           else: flunk("the registry refused the request: #{inspect(signed)}")
      end)
    end

    # The registry request a call answered, signed by the device as its
    # terminal signs it: the signed request's JSON. `change` alters it
    # first.
    defp signs(%{key: {pub, priv}}, {:ok, %{request: %{"registry_request" => map}}}, change) do
      {:ok, request} = Prima.RegistryRequest.to_sign(map)
      request = change.(%{request | signer: Prima.Identity.Key.kid(pub)})
      {:ok, bytes} = Prima.RegistryRequest.sign(request, priv)
      Jason.decode!(bytes)
    end

    defp signs(device, asked), do: signs(device, asked, & &1)

    # Both calls of `args`: the request, then the device's answer.
    defp signed(ctx, device, args) do
      asked = RegistryProvider.handle(ctx, args)
      RegistryProvider.handle(ctx, Map.put(args, "answer", signs(device, asked)))
    end

    defp namespace(user_id) do
      {:ok, user} = Sanctum.Tenancy.Users.get(user_id)
      user.namespace
    end

    defp push_token(ctx, slug),
      do:
        Compendium.Registry.CredentialStore.get(
          ctx,
          Compendium.RegistryHost.canonical_host(),
          slug
        )

    test "without an answer, each answers the registry request to sign for the caller's account, and sends nothing",
         %{ctx: ctx, device: device, identifier: identifier} do
      registry(device, fn _request -> flunk("nothing is sent before it is signed") end)

      for {args, operation, body} <- [
            {%{"action" => "legal_accept", "policy_version" => "2026-09"}, "policy.accept",
             %{"policy_version" => "2026-09"}},
            {%{
               "action" => "appeal",
               "action_type" => "ban",
               "action_ref" => "per_x",
               "argument" => "mine"
             }, "appeal.file",
             %{"action_type" => "ban", "action_ref" => "per_x", "argument" => "mine"}},
            {%{"action" => "claim_publisher", "slug" => "acme.com"}, "publisher.claim",
             %{"slug" => "acme.com"}},
            {%{"action" => "verify_publisher", "slug" => "acme.com"}, "publisher.verify",
             %{"slug" => "acme.com", "label" => CredentialStore.wire_label()}},
            {%{"action" => "sync"}, "tokens.mint", %{"label" => CredentialStore.wire_label()}}
          ] do
        assert {:ok, %{request: request} = answer} = RegistryProvider.handle(ctx, args)

        # A device's request travels over its channel: no page.
        refute Map.has_key?(answer, :url)
        assert {:ok, %Prima.SignIn{purpose: :registry} = decoded} = Prima.SignIn.decode(request)

        assert %Prima.RegistryRequest{
                 registry: "127.0.0.1",
                 operation: ^operation,
                 identifier: ^identifier,
                 body: ^body,
                 signer: nil
               } = decoded.registry_request
      end

      refute_received {:registry_request, _}
    end

    test "the device's signed request is sent, and a policy acceptance, an appeal and a publisher claim answer the registry",
         %{ctx: ctx, device: device} do
      registry(device, fn %{path: path, signed: signed} ->
        case path do
          "/v1/legal/accept" ->
            assert signed.body == %{"policy_version" => "2026-09"}
            {201, RegistryStub.answer(%{"accepted" => true})}

          "/v1/appeals" ->
            {201, RegistryStub.answer(%{"id" => "apl_1"})}

          "/v1/namespaces/publisher/claim" ->
            assert signed.body == %{"slug" => "acme.com"}
            {201, RegistryStub.answer(%{"slug" => "acme.com", "txt_value" => "cyfr-verify=x"})}
        end
      end)

      assert {:ok, %{"accepted" => true}} =
               signed(ctx, device, %{"action" => "legal_accept", "policy_version" => "2026-09"})

      assert {:ok, %{"id" => "apl_1"}} =
               signed(ctx, device, %{
                 "action" => "appeal",
                 "action_type" => "takedown",
                 "action_ref" => "cmp_1",
                 "argument" => "it was not mine"
               })

      assert {:ok, %{"slug" => "acme.com"}} =
               signed(ctx, device, %{"action" => "claim_publisher", "slug" => "acme.com"})

      # One request each, and no bearer on any.
      for _ <- 1..3 do
        assert_received {:registry_request, %{method: "POST", headers: headers}}
        refute Enum.any?(headers, &String.starts_with?(String.downcase(&1), "authorization"))
      end
    end

    test "a sync mints, records the personal namespace and stores every token, naming none",
         %{ctx: ctx, device: device, user: user} do
      registry(device, fn %{path: "/v1/tokens/mint", signed: signed} ->
        assert signed.body == %{"label" => CredentialStore.wire_label()}

        {200,
         RegistryStub.answer(%{
           "personal_namespace" => %{"slug" => "mint-person", "token" => "cyfr_pt_personal"},
           "memberships" => [
             %{"slug" => "acme.com", "role" => "admin", "token" => "cyfr_pt_acme"}
           ]
         })}
      end)

      assert {:ok, answer} = signed(ctx, device, %{"action" => "sync"})

      assert answer == %{
               personal_namespace: "mint-person",
               memberships: [%{slug: "acme.com", role: "admin"}]
             }

      refute inspect(answer) =~ "cyfr_pt_"
      assert namespace(user.id) == "mint-person"

      assert {:ok, %{token: "cyfr_pt_personal", role: "personal"}} =
               push_token(ctx, "mint-person")

      assert {:ok, %{token: "cyfr_pt_acme", role: "admin"}} = push_token(ctx, "acme.com")
    end

    test "a verification stores the founding token, and a repeat that mints none stores nothing",
         %{ctx: ctx, device: device} do
      {:ok, answers} = Agent.start_link(fn -> [] end)

      registry(device, fn %{path: "/v1/namespaces/publisher/verify"} ->
        Agent.get_and_update(answers, &{hd(&1), tl(&1)})
      end)

      Agent.update(answers, fn _ ->
        [
          {200, RegistryStub.answer(%{"slug" => "acme.com", "token" => "cyfr_pt_founder"})},
          {200, RegistryStub.answer(%{"slug" => "acme.com"})}
        ]
      end)

      args = %{"action" => "verify_publisher", "slug" => "acme.com"}
      assert {:ok, %{slug: "acme.com", token_stored: true}} = signed(ctx, device, args)
      assert {:ok, %{token: "cyfr_pt_founder", role: "admin"}} = push_token(ctx, "acme.com")

      assert {:ok, %{token_stored: false}} = signed(ctx, device, args)
      assert {:ok, %{token: "cyfr_pt_founder"}} = push_token(ctx, "acme.com")
    end

    test "a mint answer outside its shape, or no answer, writes nothing",
         %{ctx: ctx, device: device, user: user} do
      {:ok, answers} = Agent.start_link(fn -> nil end)
      registry(device, fn _request -> Agent.get(answers, & &1) end)

      for answer <- [
            {200, ~s({"personal_namespace":{"slug":"mint-null","token":null},"memberships":[]})},
            {200, ~s({"personal_namespace":null,"memberships":[]})},
            {200,
             ~s({"personal_namespace":{"slug":"mint-ok","token":"cyfr_pt_ok"},"memberships":["acme.com"]})},
            {200, ~s({"personal_namespace":{"slug":"mint-ok","token":"cyfr_pt_ok"}})},
            {503, "Bad Gateway"}
          ] do
        Agent.update(answers, fn _ -> answer end)

        capture_log(fn ->
          assert {:error, reason} = signed(ctx, device, %{"action" => "sync"})
          assert reason in [:malformed_answer, :registry_unavailable], inspect(answer)
        end)

        assert namespace(user.id) == nil
        assert {:error, :not_found} = push_token(ctx, "mint-ok")
        assert {:error, :not_found} = push_token(ctx, "acme.com")
      end
    end

    test "an account the registry does not know, a closed one among them, is refused as one",
         %{ctx: ctx, device: device} do
      registry(device, fn _request -> RegistryStub.refusal(:unknown_identity) end)

      capture_log(fn ->
        assert {:error, :unknown_identity = reason} =
                 signed(ctx, device, %{"action" => "legal_accept", "policy_version" => "2026-09"})

        assert Refusals.render(reason) == "cyfr.run does not know this account."
      end)
    end

    test "an answer is taken once: a replay, another request, another identifier or another channel sends nothing",
         %{ctx: ctx, device: device, user: user} do
      registry(device, fn _request -> {201, RegistryStub.answer(%{"accepted" => true})} end)
      args = %{"action" => "legal_accept", "policy_version" => "2026-09"}

      # Replayed, it meets a spent request.
      answer = signs(device, RegistryProvider.handle(ctx, args))
      assert {:ok, _accepted} = RegistryProvider.handle(ctx, Map.put(args, "answer", answer))
      assert_received {:registry_request, _}

      assert {:error, %Prima.Refusal{reason: :answer_refused}} =
               RegistryProvider.handle(ctx, Map.put(args, "answer", answer))

      # A signed request that is not the one held: another body, or another
      # identifier.
      for change <- [
            &%{&1 | body: %{"policy_version" => "2026-10"}},
            &%{&1 | identifier: "per_" <> String.duplicate("ab", 32)}
          ] do
        answer = signs(device, RegistryProvider.handle(ctx, args), change)

        assert {:error, %Prima.Refusal{reason: :answer_refused}} =
                 RegistryProvider.handle(ctx, Map.put(args, "answer", answer))
      end

      # The completing call names another operation or body than the request.
      answer = signs(device, RegistryProvider.handle(ctx, args))

      assert {:error, %Prima.Refusal{reason: :answer_refused}} =
               RegistryProvider.handle(ctx, %{
                 "action" => "legal_accept",
                 "policy_version" => "2026-10",
                 "answer" => answer
               })

      # Another device of the same person: its channel holds no such request.
      other = Sanctum.Test.Devices.paired!(user.id)
      {:ok, other_ctx} = Sanctum.DeviceCerts.verify_request(other.certificate, other.ctx)
      answer = signs(device, RegistryProvider.handle(ctx, args))

      assert {:error, %Prima.Refusal{reason: :answer_refused}} =
               RegistryProvider.handle(other_ctx, Map.put(args, "answer", answer))

      # A malformed answer is no answer.
      assert {:error, %Prima.Refusal{reason: :answer_refused}} =
               RegistryProvider.handle(ctx, Map.put(args, "answer", %{"not" => "a request"}))

      refute_received {:registry_request, _}
    end

    test "no registry refuses before any request is minted", %{ctx: ctx} do
      Prima.Test.Env.put_app_env(:sanctum, :registry_url, "none")

      for args <- [
            %{"action" => "sync"},
            %{"action" => "verify_publisher", "slug" => "acme.com"},
            %{"action" => "legal_accept", "policy_version" => "2026-09"}
          ] do
        assert {:error, :no_registry} = RegistryProvider.handle(ctx, args), inspect(args)
      end
    end

    test "a caller that is no client of a person's, an API key among them, asks for nothing" do
      key = %{Sanctum.TestContext.local() | auth_method: :api_key}

      assert {:error, {:invalid_argument, message}} =
               RegistryProvider.handle(key, %{"action" => "legal_accept", "policy_version" => "v"})

      assert message =~ "API key"

      # A context with neither a session nor a device's channel.
      for args <- [%{"action" => "sync"}, %{"action" => "claim_publisher", "slug" => "acme.com"}] do
        assert {:error, %Prima.Refusal{reason: :unauthenticated}} =
                 RegistryProvider.handle(Sanctum.TestContext.local(), args)
      end
    end
  end

  # The browser's way: the request is bound to the person's session and
  # names the account pages' sign page, where their passkey signs it; the
  # answer the pages return completes it in the same call.
  describe "a passkey at the account pages" do
    setup %{tls: tls} do
      DirectoryServer.listen!()
      DirectoryServer.seam!(tls)
      dir = DirectoryServer.start!(tls)
      Prima.Test.Env.put_app_env(:sanctum, :directory_url, dir.url)

      user = RegistryStub.person!()
      account = DirectoryServer.add_passkey!(dir.dir, DirectoryServer.account!(dir.dir, dir.url))
      :ok = DirectoryServer.account_person!(user.id, account)
      athanor = Sanctum.Test.People.athanor!(user)

      {:ok, session} =
        Sanctum.TestContext.create_session(
          Sanctum.Context.build(
            user_id: user.id,
            athanor_id: athanor.id,
            provider: "passkey",
            permissions: Sanctum.Context.person_permissions(),
            auth_method: :oidc,
            authenticated: true
          )
        )

      {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)
      %{ctx: ctx, account: account, dir: dir}
    end

    test "signs the request named at the sign page, and the answer completes it",
         %{ctx: ctx, account: account, dir: dir} do
      {:ok, state} = Prima.Identity.verify_chain(account.log)

      RegistryStub.start!(fn %{path: "/v1/legal/accept", body: body} ->
        {:ok, _signed} =
          Prima.RegistryRequest.verify(
            body,
            state,
            %{host: RegistryStub.host(), directory: account.url},
            System.system_time(:millisecond)
          )

        {201, RegistryStub.answer(%{"accepted" => true})}
      end)

      args = %{"action" => "legal_accept", "policy_version" => "2026-09"}
      assert {:ok, %{request: map, url: url}} = RegistryProvider.handle(ctx, args)
      assert url =~ dir.url <> "/account/sign#"
      {:ok, request} = Prima.SignIn.decode(map)

      fragment =
        request
        |> DirectoryServer.passkey_answer(account, hd(account.passkeys))
        |> Prima.SignIn.fragment()

      assert {:ok, %{"accepted" => true}} =
               RegistryProvider.handle(ctx, Map.put(args, "answer", fragment))

      # A passkey of another account signs nothing for this one.
      stranger =
        DirectoryServer.add_passkey!(dir.dir, DirectoryServer.account!(dir.dir, dir.url))

      assert {:ok, %{request: map}} = RegistryProvider.handle(ctx, args)
      {:ok, request} = Prima.SignIn.decode(map)

      fragment =
        request
        |> DirectoryServer.passkey_answer(stranger, hd(stranger.passkeys))
        |> Prima.SignIn.fragment()

      assert {:error, %Prima.Refusal{reason: :answer_refused}} =
               RegistryProvider.handle(ctx, Map.put(args, "answer", fragment))
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  # The gate casts every call against its action's declaration
  # (`Prima.Operation.cast/2`) before the handler runs.
  describe "gated identity mutations refuse incomplete args" do
    test "each required argument missing is refused by the declaration" do
      definition = RegistryProvider.definition()

      complete = %{
        "slug" => "someslug",
        "token_id" => "tok_1",
        "target_personal_slug" => "bob",
        "role" => "member"
      }

      for {action, required} <- [
            {"tokens_revoke", ~w(slug token_id)},
            {"members_add", ~w(slug target_personal_slug role)},
            {"members_update", ~w(slug target_personal_slug role)},
            {"members_remove", ~w(slug target_personal_slug)}
          ] do
        args = complete |> Map.take(required) |> Map.put("action", action)
        assert {:ok, _} = Prima.Operation.cast(definition, args), action

        for field <- required do
          assert {:error, {:invalid_argument, "Missing required field: " <> ^field}} =
                   Prima.Operation.cast(definition, Map.delete(args, field)),
                 "#{action} without #{field}"
        end
      end
    end
  end

  # Each action as its handler reaches the registry
  # (`Compendium.Registry.Client`): a POST or PATCH changes something
  # there, a DELETE deletes it, a GET reads.
  @remote_changes ~w(sync claim_publisher verify_publisher tokens_issue
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
