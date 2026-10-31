# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.RegistryTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  import ExUnit.CaptureLog

  alias Compendium.Providers.Registry, as: RegistryProvider
  alias Sanctum.Refusals
  alias Sanctum.Test.{DirectoryServer, RegistryStub}

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

  # Every operation a person makes at the registry is a request their live
  # key signs (`Prima.RegistryRequest`); the registry is a stub that
  # verifies each one under the person's head as the registry does
  # (`Sanctum.Test.RegistryStub`), and nothing else ever reaches it: no
  # bearer, no identity provider's token.
  describe "the operations a person signs" do
    # A signed-in, enrolled person with no namespace yet, as the context
    # their session establishes, their head and the session's token.
    defp signed_in_person do
      n = System.unique_integer([:positive])

      {:ok, %{id: person_id}} =
        Sanctum.Test.People.linked(%{
          id: "github|https://github.com|claim-op-#{n}",
          provider: "github",
          email: "claim-op#{n}@example.com",
          verified: true
        })

      state = RegistryStub.enroll!(person_id)
      {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(person_id, "Claim op #{n}")

      {:ok, session} =
        Sanctum.TestContext.create_session(
          Sanctum.Context.build(
            user_id: person_id,
            email: "claim-op#{n}@example.com",
            provider: "github",
            athanor_id: athanor.id,
            permissions: [:*],
            auth_method: :oidc,
            origin: :interactive,
            authenticated: true
          )
        )

      {:ok, ctx} = Sanctum.Caller.establish(session.token, refresh: false)
      %{ctx: ctx, state: state, token: session.token, slug: "claimed-op#{n}"}
    end

    # The registry: each request verified under `state`, and answered by
    # `answer.(request)` once it verifies.
    defp registry(state, answer) do
      RegistryStub.start!(fn %{body: body} = request ->
        case RegistryStub.verify(body, state) do
          {:ok, signed} -> answer.(Map.put(request, :signed, signed))
          {:error, reason} -> flunk("the registry refused the request: #{inspect(reason)}")
        end
      end)
    end

    defp accept(ctx, version),
      do: RegistryProvider.handle(ctx, %{"action" => "legal_accept", "policy_version" => version})

    defp namespace(ctx) do
      {:ok, user} = Sanctum.Tenancy.Users.get(ctx.user_id)
      user.namespace
    end

    defp push_token(ctx, slug),
      do:
        Compendium.Registry.CredentialStore.get(
          ctx,
          Compendium.RegistryHost.canonical_host(),
          slug
        )

    test "a head that moved between the signing and the registry's read is signed once more" do
      %{ctx: ctx, state: state} = signed_in_person()
      moved = Prima.Digest.sha256("the rotated head")
      parent = self()

      RegistryStub.start!(fn %{body: body} ->
        {:ok, %{"key_epoch" => epoch}} = Jason.decode(body)
        send(parent, {:signed_under, epoch})

        if epoch == state.key_epoch do
          # The rotation lands while the registry reads the log.
          Arca.Repo.update_all(
            from(p in Arca.Schemas.PersonIdentity, where: p.user_id == ^ctx.user_id),
            set: [head_hash: moved]
          )

          RegistryStub.refusal(:stale_key_epoch)
        else
          {:ok, _} = RegistryStub.verify(body, %{state | key_epoch: moved, head: moved})
          {201, RegistryStub.answer(%{"accepted" => true})}
        end
      end)

      assert {:ok, %{"accepted" => true}} = accept(ctx, "2026-10")
      assert_received {:signed_under, first}
      assert_received {:signed_under, ^moved}
      assert first == state.key_epoch

      assert_received {:registry_request, _}
      assert_received {:registry_request, _}

      # A registry still ahead after the re-sign is answered as it says, once.
      RegistryStub.start!(fn _ -> RegistryStub.refusal(:stale_key_epoch) end)
      capture_log(fn -> assert {:error, :stale_key_epoch} = accept(ctx, "2026-10") end)
      assert_received {:registry_request, _}
      assert_received {:registry_request, _}
      refute_received {:registry_request, _}
    end

    test "a person with no identifier sends nothing" do
      n = System.unique_integer([:positive])

      {person, _user} =
        Sanctum.TestContext.person!(%{
          Sanctum.TestContext.local()
          | user_id: "local|local|unenrolled#{n}"
        })

      RegistryStub.start!(fn _ -> flunk("nothing is sent") end)

      assert {:error, :not_enrolled} = accept(person, "2026-10")
      refute_received {:registry_request, _}
    end

    test "an API key is nobody's registry identity" do
      key = %{Sanctum.TestContext.local() | auth_method: :api_key}

      for args <- [
            %{"action" => "register"},
            %{"action" => "register", "name" => "alice"},
            %{"action" => "legal_accept", "policy_version" => "2026-09"}
          ] do
        assert {:error, {:invalid_argument, message}} = RegistryProvider.handle(key, args)
        assert message =~ "API key"
      end
    end

    test "a policy acceptance and an appeal are the bodies signed for" do
      %{ctx: ctx, state: state} = signed_in_person()

      registry(state, fn %{path: path, signed: signed} ->
        case path do
          "/v1/legal/accept" ->
            assert signed.body == %{"policy_version" => "2026-09"}
            {201, RegistryStub.answer(%{"accepted" => true})}

          "/v1/appeals" ->
            assert signed.body == %{
                     "action_type" => "ban",
                     "action_ref" => state.identifier,
                     "argument" => "it was not me"
                   }

            {201, RegistryStub.answer(%{"id" => "apl_1"})}
        end
      end)

      assert {:ok, %{"accepted" => true}} =
               RegistryProvider.handle(ctx, %{
                 "action" => "legal_accept",
                 "policy_version" => "2026-09"
               })

      assert {:ok, %{"id" => "apl_1"}} =
               RegistryProvider.handle(ctx, %{
                 "action" => "appeal",
                 "action_type" => "ban",
                 "action_ref" => state.identifier,
                 "argument" => "it was not me"
               })
    end

    test "a publisher claim is signed, with no bearer" do
      %{ctx: ctx, state: state} = signed_in_person()

      registry(state, fn %{path: "/v1/namespaces/publisher/claim", signed: signed} ->
        assert signed.body == %{"slug" => "acme.com"}
        {201, RegistryStub.answer(%{"slug" => "acme.com", "txt_record" => "cyfr-verify=x"})}
      end)

      assert {:ok, %{"slug" => "acme.com"}} =
               RegistryProvider.handle(ctx, %{"action" => "claim_publisher", "slug" => "acme.com"})
    end
  end

  # `registry.register` finishes what an admission began: the enrollment
  # it opened is registered at a scripted directory, the registry's policy
  # accepted and the name claimed, each refusal leaving the attempt where
  # the module doc says.
  describe "registering a person's name and identity" do
    setup do
      tls = DirectoryServer.tls()
      DirectoryServer.listen!()
      DirectoryServer.seam!(tls)
      Arca.Cache.init()
      on_exit(fn -> Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable()) end)
      %{directory: DirectoryServer.start!(tls)}
    end

    # A person as an admission leaves them: signed in by a session, their
    # enrollment opened at the scripted directory with `name`, nothing sent.
    defp admitted!(directory, name) do
      n = System.unique_integer([:positive])

      {:ok, %{id: person_id}} =
        Sanctum.Test.People.linked(%{
          id: "github|https://github.com|register-#{n}",
          provider: "github",
          email: "register#{n}@example.com",
          verified: true
        })

      identity = Sanctum.Test.Newcomers.identity(name)
      :ok = Sanctum.Recovery.open_at_admission(person_id, identity, directory.url)
      {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(person_id, "Register #{n}")

      {:ok, session} =
        Sanctum.TestContext.create_session(
          Sanctum.Context.build(
            user_id: person_id,
            email: "register#{n}@example.com",
            provider: "github",
            athanor_id: athanor.id,
            permissions: [:*],
            auth_method: :oidc,
            origin: :interactive,
            authenticated: true
          )
        )

      {:ok, ctx} = Sanctum.Caller.establish(session.token, refresh: false)
      %{ctx: ctx, token: session.token, identity: identity, attempt: attempt(person_id)}
    end

    defp attempt(user_id),
      do: Arca.Repo.get_by!(Arca.Schemas.IdentityAttempt, user_id: user_id, kind: "enrollment")

    defp register(ctx, args \\ %{}),
      do: RegistryProvider.handle(ctx, Map.put(args, "action", "register"))

    # The registry: its current policy version, and every signed request
    # verified as the registry verifies it, under the person's head at the
    # directory their genesis names, before `answer` sees it.
    defp registry(person, directory, answer) do
      {:ok, {recovery, _}} = Prima.Identity.derive_recovery_key(person.identity.recovery_secret)

      RegistryStub.start!(fn
        %{method: "GET"} = request ->
          answer.(request)

        %{body: body} = request ->
          state = %{RegistryStub.state(person.ctx.user_id, [recovery]) | directory: directory.url}
          registry = %{host: RegistryStub.host(), directory: directory.url}

          case Prima.RegistryRequest.verify(body, state, registry, System.os_time(:millisecond)) do
            {:ok, signed} -> answer.(Map.put(request, :signed, signed))
            {:error, reason} -> flunk("the registry refused the request: #{inspect(reason)}")
          end
      end)
    end

    # A registry that names policy `2026-10`, takes its acceptance, and
    # gives the name it is asked for to the identifier that signed.
    defp accepting do
      fn
        %{method: "GET", path: "/v1/legal/version"} ->
          {200, RegistryStub.answer(%{"policy_version" => "2026-10", "policies" => []})}

        %{
          path: "/v1/legal/accept",
          signed: %{operation: "policy.accept", body: %{"policy_version" => "2026-10"}}
        } ->
          {201, RegistryStub.answer(%{"accepted" => true})}

        %{path: "/v1/namespaces/personal/claim", signed: %{operation: "handle.claim"} = signed} ->
          {201,
           RegistryStub.answer(%{
             "handle" => signed.body["handle"],
             "identifier" => signed.identifier
           })}
      end
    end

    # `accepting/0`, but the claim answered by `claim`.
    defp claiming(claim) do
      accepted = accepting()

      fn
        %{path: "/v1/namespaces/personal/claim"} = request -> claim.(request)
        request -> accepted.(request)
      end
    end

    defp registry_requests do
      receive do
        {:registry_request, request} -> [request | registry_requests()]
      after
        0 -> []
      end
    end

    defp next_refusal([]), do: {nil, []}
    defp next_refusal([next | rest]), do: {next, rest}

    defp claim_bodies(requests) do
      for %{path: "/v1/namespaces/personal/claim", body: body} <- requests,
          do: Jason.decode!(body)["body"]
    end

    defp directory_writes, do: Enum.filter(DirectoryServer.requests(), &(&1.method == "POST"))

    # A rename that lands while a claim is in flight: the claimed name is
    # recorded, the attempt follows it, and every answer after names it.
    test "a name edit overlapping a successful claim cannot change the name reported after saving",
         %{directory: directory} do
      person = admitted!(directory, "mira")

      registry(
        person,
        directory,
        claiming(fn request ->
          assert {:ok, %{name: "nova"}} = Sanctum.Recovery.rename(person.ctx, "nova")
          accepting().(request)
        end)
      )

      assert {:ok, %{"name" => "mira"} = first} = register(person.ctx)
      assert namespace(person.ctx) == "mira"

      assert {:ok, %{name: "mira"}} =
               Arca.IdentityAttempts.get(Sanctum.Context.actor(person.ctx), person.attempt.id)

      assert {:error, {:invalid_argument, "Your name is set and cannot be changed."}} =
               Sanctum.Recovery.rename(person.ctx, "nova")

      assert {:ok, %{phase: "completed"}} =
               Sanctum.Recovery.recovery_code_saved(person.ctx, person.attempt.id)

      assert {:ok, ^first} = register(person.ctx)
    end

    test "a staged enrollment, as a crash after the admission leaves it, is registered, its policy accepted and its name claimed and recorded",
         %{directory: directory} do
      person = admitted!(directory, "mira")
      assert person.attempt.phase == "staged"
      registry(person, directory, accepting())

      assert {:ok, answer} = register(person.ctx)

      assert answer == %{
               "attempt_id" => person.attempt.id,
               "identifier" => person.attempt.identifier,
               "name" => "mira"
             }

      assert %{phase: "accepted"} = attempt(person.ctx.user_id)
      assert namespace(person.ctx) == "mira"
      assert [_genesis] = directory_writes()

      assert ["/v1/legal/version", "/v1/legal/accept", "/v1/namespaces/personal/claim"] ==
               Enum.map(registry_requests(), & &1.path)

      # A repeat answers the same: the directory step sends nothing, and the
      # registry answers a repeated claim by the same identifier the same.
      assert {:ok, ^answer} = register(person.ctx)
      assert directory_writes() == []

      # Once the code is saved, it answers at once and sends nothing.
      assert {:ok, %{phase: "completed"}} =
               Sanctum.Recovery.recovery_code_saved(person.ctx, person.attempt.id)

      _ = registry_requests()
      assert {:ok, ^answer} = register(person.ctx)
      assert registry_requests() == []
      assert directory_writes() == []
    end

    test "a silent directory leaves the attempt submitted and nothing asked of the registry; a repeat finishes it",
         %{directory: directory} do
      person = admitted!(directory, "mira")
      DirectoryServer.next(directory.dir, person.attempt.identifier, :drop)
      registry(person, directory, accepting())

      assert {:error, :directory_unavailable} = register(person.ctx)
      assert %{phase: "submitted"} = attempt(person.ctx.user_id)
      assert registry_requests() == []
      assert namespace(person.ctx) == nil

      assert {:ok, %{"name" => "mira"}} = register(person.ctx)
      assert namespace(person.ctx) == "mira"
    end

    test "a directory that refuses the identity ends the attempt refused", %{directory: directory} do
      person = admitted!(directory, "mira")
      DirectoryServer.next(directory.dir, person.attempt.identifier, :refuse)
      registry(person, directory, accepting())

      assert {:error, :directory_refused} = register(person.ctx)
      assert Refusals.classify(:directory_refused).class == :forbidden
      assert %{phase: "refused"} = attempt(person.ctx.user_id)
      assert registry_requests() == []
      assert namespace(person.ctx) == nil
    end

    test "a silent registry, or one whose policy cannot be read, leaves the attempt accepted and no name",
         %{directory: directory} do
      person = admitted!(directory, "mira")
      {:ok, answers} = Agent.start_link(fn -> :close end)
      accepted = accepting()

      registry(person, directory, fn
        %{method: "GET"} = request ->
          case Agent.get(answers, & &1) do
            :pass -> accepted.(request)
            answer -> answer
          end

        request ->
          accepted.(request)
      end)

      for answer <- [
            :close,
            {503, "Bad Gateway"},
            {200, RegistryStub.answer(%{"policies" => []})}
          ] do
        Agent.update(answers, fn _ -> answer end)
        capture_log(fn -> assert {:error, :registry_unavailable} = register(person.ctx) end)
        assert %{phase: "accepted"} = attempt(person.ctx.user_id)
        assert namespace(person.ctx) == nil
      end

      # The claim's own answer unreadable is a registry that did not answer.
      RegistryStub.start!(fn
        %{method: "GET"} -> {200, RegistryStub.answer(%{"policy_version" => "2026-10"})}
        %{path: "/v1/legal/accept"} -> {201, RegistryStub.answer(%{"accepted" => true})}
        %{path: "/v1/namespaces/personal/claim"} -> {201, "not json"}
      end)

      capture_log(fn -> assert {:error, :registry_unavailable} = register(person.ctx) end)
      assert namespace(person.ctx) == nil
    end

    test "a taken or reserved name is refused in the person's words, and another name is claimed in its place",
         %{directory: directory} do
      person = admitted!(directory, "mira")

      {:ok, refusals} =
        Agent.start_link(fn -> [:handle_taken, :handle_reserved, :namespace_reserved] end)

      registry(
        person,
        directory,
        claiming(fn request ->
          case Agent.get_and_update(refusals, &next_refusal/1) do
            nil -> accepting().(request)
            refusal -> RegistryStub.refusal(refusal)
          end
        end)
      )

      assert {:error, :name_taken} = register(person.ctx)

      assert %Prima.Refusal{class: :conflict, message: "Someone holds that name. Choose another."} =
               Refusals.classify(:name_taken)

      for _reserved <- 1..2 do
        assert {:error, :name_reserved} = register(person.ctx)
      end

      assert %Prima.Refusal{class: :invalid_argument} = Refusals.classify(:name_reserved)
      assert %{phase: "accepted", name: "mira"} = attempt(person.ctx.user_id)
      assert namespace(person.ctx) == nil

      # Each refused claim asked for the name chosen at creation.
      assert [%{"handle" => "mira"}, %{"handle" => "mira"}, %{"handle" => "mira"}] =
               claim_bodies(registry_requests())

      assert {:ok, %{"name" => "nova"} = answer} = register(person.ctx, %{"name" => "nova"})
      assert answer["attempt_id"] == person.attempt.id
      assert %{name: "nova"} = attempt(person.ctx.user_id)
      assert namespace(person.ctx) == "nova"

      assert [%{"handle" => "nova"}] = claim_bodies(registry_requests())

      # The name is recorded: it is theirs for life.
      assert {:error, {:invalid_argument, "Your name is set and cannot be changed."}} =
               register(person.ctx, %{"name" => "stella"})
    end

    test "a name that is no name is refused before anything is sent", %{directory: directory} do
      person = admitted!(directory, "mira")
      registry(person, directory, fn _ -> flunk("nothing is sent") end)

      assert {:error, {:invalid_argument, _}} = register(person.ctx, %{"name" => "Not A Name"})
      assert %{phase: "staged", name: "mira"} = attempt(person.ctx.user_id)
      assert directory_writes() == []
    end

    test "with no registry configured, the identity is registered and no name is made",
         %{directory: directory} do
      person = admitted!(directory, "mira")
      for app <- [:sanctum, :cyfr], do: Prima.Test.Env.put_app_env(app, :registry_url, "none")

      assert {:error, :no_registry} = register(person.ctx)
      assert Refusals.classify(:no_registry).class == :setup_required
      assert %{phase: "accepted"} = attempt(person.ctx.user_id)
      assert [_genesis] = directory_writes()
      assert namespace(person.ctx) == nil
    end

    test "a person with no enrollment has nothing to register", %{directory: directory} do
      %{ctx: ctx} = admitted!(directory, "mira")
      %{ctx: bare} = signed_in_person()
      Arca.Repo.delete_all(Arca.Schemas.IdentityAttempt)
      RegistryStub.start!(fn _ -> flunk("nothing is sent") end)

      for ctx <- [ctx, bare] do
        assert {:error, :no_attempt} = register(ctx)
      end

      assert %Prima.Refusal{class: :not_found} = Refusals.classify(:no_attempt)
    end

    test "a session revoked while the registry answered records nothing", %{directory: directory} do
      person = admitted!(directory, "mira")
      hash = Sanctum.Session.token_hash(person.token)

      registry(
        person,
        directory,
        claiming(fn request ->
          Arca.Repo.delete_all(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash))
          accepting().(request)
        end)
      )

      assert {:error, :unauthenticated} = register(person.ctx)
      assert namespace(person.ctx) == nil
    end

    test "a name another person here holds is refused, and nothing is recorded",
         %{directory: directory} do
      person = admitted!(directory, "mira")
      %{ctx: holder} = signed_in_person()
      {:ok, holder_row} = Sanctum.Tenancy.Users.get(holder.user_id)
      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(holder_row, "mira")
      registry(person, directory, accepting())

      assert {:error, {:conflict, message}} = register(person.ctx)

      assert message ==
               "cyfr.run gave you that name, but another person on this CYFR holds it. Ask " <>
                 "whoever runs this CYFR."

      assert namespace(person.ctx) == nil
    end

    test "an answer naming another identifier is one the registry did not give, and nothing is recorded",
         %{directory: directory} do
      person = admitted!(directory, "mira")

      registry(
        person,
        directory,
        claiming(fn _request ->
          {201,
           RegistryStub.answer(%{
             "handle" => "mira",
             "identifier" => "per_" <> String.duplicate("b", 64)
           })}
        end)
      )

      assert {:error, :registry_unavailable} = register(person.ctx)
      assert namespace(person.ctx) == nil
    end

    test "the calling process killed mid-call leaves nothing written", %{directory: directory} do
      person = admitted!(directory, "mira")
      registry(person, directory, claiming(fn _request -> :hang end))

      caller = spawn(fn -> register(person.ctx) end)
      assert_receive {:registry_request, %{path: "/v1/namespaces/personal/claim"}}, 15_000
      Process.exit(caller, :kill)
      refute Process.alive?(caller)
      assert namespace(person.ctx) == nil
      assert %{phase: "accepted"} = attempt(person.ctx.user_id)
    end

    test "a member whose slot is taken while the registry answers a claim records nothing",
         %{directory: directory} do
      person = admitted!(directory, "mira")
      slot = hold_slot()

      registry(
        person,
        directory,
        claiming(fn request ->
          taken_over(slot)
          accepting().(request)
        end)
      )

      assert {:error, :not_owner} = register(person.ctx)
      assert {:error, :not_owner} = Arca.Repo.owned("positive control", fn -> {:ok, :ran} end)
      assert namespace(person.ctx) == nil
    end
  end

  # The operations that mint a push token wait on a fresh confirmation
  # (`credential_issuance`), send nothing until it is proven, and store
  # every token they are answered; the answer they give names no token.
  describe "the operations that mint push tokens" do
    defp minted do
      RegistryStub.answer(%{
        "personal_namespace" => %{"slug" => "mint-person", "token" => "cyfr_pt_personal"},
        "memberships" => [%{"slug" => "acme.com", "role" => "admin", "token" => "cyfr_pt_acme"}]
      })
    end

    test "a sync asks a fresh confirmation and sends nothing until it is proven" do
      %{ctx: ctx, state: state} = signed_in_person()
      registry(state, fn _ -> flunk("nothing is sent before the confirmation") end)

      assert {:error, {:confirmation_required, %{operation: "registry.sync"}}} =
               RegistryProvider.handle(ctx, %{"action" => "sync"})

      refute_received {:registry_request, _}
    end

    test "a confirmed sync mints, stores every token and records the personal namespace" do
      %{ctx: ctx, state: state} = signed_in_person()

      registry(state, fn %{path: "/v1/tokens/mint", signed: signed} ->
        assert %{"label" => label} = signed.body
        assert label == Compendium.Registry.CredentialStore.device_label()
        {200, minted()}
      end)

      assert {:ok, answer} =
               Sanctum.TestContext.confirming(
                 ctx,
                 &RegistryProvider.handle(&1, %{"action" => "sync"})
               )

      assert answer == %{
               personal_namespace: "mint-person",
               memberships: [%{slug: "acme.com", role: "admin"}]
             }

      refute inspect(answer) =~ "cyfr_pt_"
      assert namespace(ctx) == "mint-person"

      assert {:ok, %{token: "cyfr_pt_personal", role: "personal"}} =
               push_token(ctx, "mint-person")

      assert {:ok, %{token: "cyfr_pt_acme", role: "admin"}} = push_token(ctx, "acme.com")
    end

    test "a confirmed sync the registry cannot answer stores nothing" do
      %{ctx: ctx, state: state} = signed_in_person()
      registry(state, fn _ -> {503, "Bad Gateway"} end)

      capture_log(fn ->
        assert {:error, :registry_unavailable} =
                 Sanctum.TestContext.confirming(
                   ctx,
                   &RegistryProvider.handle(&1, %{"action" => "sync"})
                 )
      end)

      assert namespace(ctx) == nil
      assert {:error, :not_found} = push_token(ctx, "mint-person")
    end

    test "a verification asks a fresh confirmation, stores the founding token, and a repeat mints nothing" do
      %{ctx: ctx, state: state} = signed_in_person()
      args = %{"action" => "verify_publisher", "slug" => "acme.com"}
      {:ok, answers} = Agent.start_link(fn -> [] end)

      registry(state, fn %{path: "/v1/namespaces/publisher/verify", signed: signed} ->
        assert %{"slug" => "acme.com", "label" => _} = signed.body
        Agent.get_and_update(answers, &{hd(&1), tl(&1)})
      end)

      assert {:error, {:confirmation_required, %{operation: "registry.verify_publisher"}}} =
               RegistryProvider.handle(ctx, args)

      refute_received {:registry_request, _}

      Agent.update(answers, fn _ ->
        [{200, RegistryStub.answer(%{"slug" => "acme.com", "token" => "cyfr_pt_founder"})}]
      end)

      assert {:ok, %{slug: "acme.com", token_stored: true} = answer} =
               Sanctum.TestContext.confirming(ctx, &RegistryProvider.handle(&1, args))

      refute inspect(answer) =~ "cyfr_pt_"
      assert {:ok, %{token: "cyfr_pt_founder", role: "admin"}} = push_token(ctx, "acme.com")

      # The registry answers a repeat as verified and mints nothing: the
      # stored token stays, and `sync` is what mints another.
      Agent.update(answers, fn _ -> [{200, RegistryStub.answer(%{"slug" => "acme.com"})}] end)

      assert {:ok, %{token_stored: false}} =
               Sanctum.TestContext.confirming(ctx, &RegistryProvider.handle(&1, args))

      assert {:ok, %{token: "cyfr_pt_founder"}} = push_token(ctx, "acme.com")
    end

    test "no registry refuses before any confirmation is asked" do
      %{ctx: ctx} = signed_in_person()
      previous = Application.get_env(:sanctum, :registry_url)
      on_exit(fn -> Application.put_env(:sanctum, :registry_url, previous) end)
      Application.put_env(:sanctum, :registry_url, "none")

      assert {:error, :no_registry} = RegistryProvider.handle(ctx, %{"action" => "sync"})

      assert {:error, :no_registry} =
               RegistryProvider.handle(ctx, %{
                 "action" => "verify_publisher",
                 "slug" => "acme.com"
               })
    end
  end

  # What a registry answer may write, and when: only an answer of the
  # operation's shape, only by the member that still holds its slot, and
  # with a label the protocol takes, whatever the operator configured.
  describe "what an answer writes" do
    # This member's slot, taken as the control plane's claimant takes it;
    # the claim switch and the slot's terms restored on exit, registered
    # before either changes.
    defp hold_slot do
      keys = for k <- [:standing, :generation, :slot], do: {Arca.ControlPlane, k}
      saved = for k <- keys, do: {k, :persistent_term.get(k, :absent)}
      claimed = Application.fetch_env(:arca, :control_plane_claim_enabled)

      on_exit(fn ->
        for {k, v} <- saved do
          if v == :absent, do: :persistent_term.erase(k), else: :persistent_term.put(k, v)
        end

        case claimed do
          {:ok, v} -> Application.put_env(:arca, :control_plane_claim_enabled, v)
          :error -> Application.delete_env(:arca, :control_plane_claim_enabled)
        end
      end)

      Application.put_env(:arca, :control_plane_claim_enabled, true)
      node = "registry-#{System.unique_integer([:positive])}"
      {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot", 60_000)
      slot
    end

    # A successor takes the slot while the registry answers.
    defp taken_over(slot) do
      {1, _} =
        Arca.Repo.update_all(
          from(l in Arca.Schemas.CellLease, where: l.node == ^slot.node),
          set: [owner: "successor", generation: slot.generation + 1]
        )

      :ok
    end

    test "a member whose slot is taken while the registry mints stores nothing" do
      %{ctx: ctx, state: state} = signed_in_person()
      slot = hold_slot()

      registry(state, fn _request ->
        taken_over(slot)

        {200,
         RegistryStub.answer(%{
           "personal_namespace" => %{"slug" => "stale-owner", "token" => "cyfr_pt_stale"},
           "memberships" => [
             %{"slug" => "acme.com", "role" => "admin", "token" => "cyfr_pt_stale_acme"}
           ]
         })}
      end)

      assert {:error, :not_owner} =
               Sanctum.TestContext.confirming(
                 ctx,
                 &RegistryProvider.handle(&1, %{"action" => "sync"})
               )

      assert namespace(ctx) == nil
      assert {:error, :not_found} = push_token(ctx, "stale-owner")
      assert {:error, :not_found} = push_token(ctx, "acme.com")
    end

    test "a member whose slot is taken while the registry verifies stores no founding token" do
      %{ctx: ctx, state: state} = signed_in_person()
      slot = hold_slot()

      registry(state, fn _request ->
        taken_over(slot)
        {200, RegistryStub.answer(%{"slug" => "acme.com", "token" => "cyfr_pt_founder"})}
      end)

      assert {:error, :not_owner} =
               Sanctum.TestContext.confirming(
                 ctx,
                 &RegistryProvider.handle(&1, %{
                   "action" => "verify_publisher",
                   "slug" => "acme.com"
                 })
               )

      assert {:error, :not_found} = push_token(ctx, "acme.com")
    end

    test "a mint answer outside its shape writes nothing" do
      %{ctx: ctx, state: state} = signed_in_person()
      {:ok, answers} = Agent.start_link(fn -> [] end)
      registry(state, fn _request -> Agent.get(answers, & &1) end)

      for body <- [
            ~s({"personal_namespace":{"slug":"mint-null","token":null},"memberships":[]}),
            ~s({"personal_namespace":{"token":"cyfr_pt_x"},"memberships":[]}),
            ~s({"personal_namespace":null,"memberships":[]}),
            ~s({"personal_namespace":{"slug":"mint-ok","token":"cyfr_pt_ok"},"memberships":["acme.com"]}),
            ~s({"personal_namespace":{"slug":"mint-ok","token":"cyfr_pt_ok"},"memberships":[{"slug":"acme.com","role":"admin","token":""}]}),
            ~s({"personal_namespace":{"slug":"mint-ok","token":"cyfr_pt_ok"}})
          ] do
        Agent.update(answers, fn _ -> {200, body} end)

        assert {:error, :malformed_answer} =
                 Sanctum.TestContext.confirming(
                   ctx,
                   &RegistryProvider.handle(&1, %{"action" => "sync"})
                 ),
               body

        assert namespace(ctx) == nil
        assert {:error, :not_found} = push_token(ctx, "mint-ok")
        assert {:error, :not_found} = push_token(ctx, "acme.com")
      end
    end

    test "a verification answer with a null token is malformed; an absent one minted nothing" do
      %{ctx: ctx, state: state} = signed_in_person()
      {:ok, answers} = Agent.start_link(fn -> [] end)
      registry(state, fn _request -> Agent.get(answers, & &1) end)
      args = %{"action" => "verify_publisher", "slug" => "acme.com"}

      Agent.update(answers, fn _ -> {200, ~s({"slug":"acme.com","token":null})} end)

      assert {:error, :malformed_answer} =
               Sanctum.TestContext.confirming(ctx, &RegistryProvider.handle(&1, args))

      Agent.update(answers, fn _ -> {200, ~s({"slug":"other.com","token":"cyfr_pt_x"})} end)

      assert {:error, :malformed_answer} =
               Sanctum.TestContext.confirming(ctx, &RegistryProvider.handle(&1, args))

      assert {:error, :not_found} = push_token(ctx, "acme.com")

      Agent.update(answers, fn _ -> {200, ~s({"slug":"acme.com"})} end)

      assert {:ok, %{token_stored: false}} =
               Sanctum.TestContext.confirming(ctx, &RegistryProvider.handle(&1, args))
    end

    test "a configured label too long for the protocol, or not ASCII, mints under its wire form" do
      %{ctx: ctx, state: state} = signed_in_person()
      parent = self()

      registry(state, fn %{signed: signed} ->
        send(parent, {:label, signed.body["label"]})
        {200, RegistryStub.answer(%{"memberships" => []})}
      end)

      for {configured, wire} <- [
            {String.duplicate("x", 65), String.duplicate("x", 64)},
            {"筆電 laptop", " laptop"},
            {"筆電", nil}
          ] do
        {:ok, entry} = Cyfr.Platform.Settings.Roster.fetch("device_label")
        assert {:ok, ^configured} = entry.validator.(configured)
        Cyfr.Test.Settings.put("device_label", configured)

        assert {:ok, _synced} =
                 Sanctum.TestContext.confirming(
                   ctx,
                   &RegistryProvider.handle(&1, %{"action" => "sync"})
                 )

        assert_receive {:label, label}
        assert label =~ ~r/\A[\x20-\x7E]{1,64}\z/

        if wire,
          do: assert(label == wire),
          else: assert(label == Compendium.Registry.CredentialStore.wire_label())
      end
    end

    test "the registry's typed refusals on 429 and 5xx reach the caller typed" do
      %{ctx: ctx, state: state, slug: slug} = signed_in_person()
      {:ok, answers} = Agent.start_link(fn -> [] end)
      registry(state, fn _request -> Agent.get(answers, & &1) end)

      for refusal <- [:directory_unavailable, :dns_timeout, :rate_limited] do
        Agent.update(answers, fn _ -> RegistryStub.refusal(refusal) end)

        capture_log(fn ->
          assert Compendium.Registry.Client.signed(ctx.user_id, "handle.claim", %{
                   "handle" => slug
                 }) == {:error, refusal}
        end)
      end

      Agent.update(answers, fn _ -> {503, "Bad Gateway"} end)

      capture_log(fn ->
        assert {:error, :registry_unavailable} = accept(ctx, "2026-10")
      end)
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
  @remote_changes ~w(sync register claim_publisher verify_publisher tokens_issue
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
