# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SignInTest do
  @moduledoc """
  Sign-in, confirmation and registry signatures by a request this CYFR
  mints (`Sanctum.SignIn`), against a scripted directory serving the
  account's log. A request is held for its challenge, bound to the
  browser or channel that asked, and spent on the first answer: a
  replayed answer, an answer from another browser and an answer past the
  request's expiry each sign no one in. A passkey's answer signs in the
  person its identifier names, or admits a new one under the setup token,
  an invitation or the door, and the session is bound to the key that
  signed and the head it was verified under. A `confirm` answer confirms
  only the person's own record; a `registry` answer is the signed
  request; a device answers over its channel.
  """

  # The directory seam, the setup token, the public URL and the directory
  # setting are process-wide.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{Session, User}
  alias Prima.SignIn.DeviceAnswer
  alias Sanctum.SignIn
  alias Sanctum.Tenancy.Users
  alias Sanctum.Test.{DirectoryServer, RegistryStub}

  @token String.duplicate("5e", 32)
  @origin "https://cyfr.example"
  @browser {:browser, "csrf-of-this-browser"}

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup %{tls: tls} = tags do
    Arca.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    dir = DirectoryServer.start!(tls)

    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Prima.Test.Env.put_app_env(:sanctum, :public_url, @origin)
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, dir.url)
    Prima.Test.Env.put_app_env(:sanctum, :access_mode, :public)

    # The installation holds no person inside this test's transaction: the
    # first person is setup's question.
    Arca.Repo.delete_all(User)

    account = dir.dir |> DirectoryServer.account!(dir.url) |> passkey!(dir)
    %{dir: dir, account: account}
  end

  defp passkey!(account, dir), do: DirectoryServer.add_passkey!(dir.dir, account)

  defp minted(purpose, binding, opts \\ []) do
    {:ok, %{request: request, url: url}} = SignIn.request(purpose, binding, opts)
    {request, url}
  end

  defp answer(request, account, opts \\ []),
    do: DirectoryServer.passkey_answer(request, account, hd(account.passkeys), opts)

  # The account's first person, made by setup through a sign-in.
  defp first!(account) do
    {request, _url} = minted(:sign_in, @browser, admission: {:setup, @token})
    {:ok, %{user: user}} = SignIn.answer(answer(request, account), @browser)
    user
  end

  # The person's own context, as their session establishes it.
  defp person_context(user, athanor_id, session) do
    Sanctum.Context.build(
      user_id: user.id,
      athanor_id: athanor_id,
      provider: "passkey",
      auth_method: :oidc,
      authenticated: true,
      session_token_hash: session.token_hash,
      permissions: Sanctum.Context.person_permissions()
    )
  end

  defp sessions(user_id),
    do: Arca.Repo.all(from(s in Session, where: s.user_id == ^user_id))

  describe "the request" do
    test "is this CYFR's, returns to its sign-in page, and sends a browser to the account pages",
         %{dir: dir} do
      {request, url} = minted(:sign_in, @browser)

      assert request.purpose == :sign_in
      assert request.audience == @origin
      assert request.return == @origin <> "/login"
      assert byte_size(request.challenge) == 32
      assert url == dir.url <> "/account/sign#" <> Prima.SignIn.fragment(request)

      {new, new_url} = minted(:sign_in, @browser, page: {:new, "mira"})

      assert new_url ==
               dir.url <> "/account/new#name=mira&request=" <> Prima.SignIn.fragment(new)
    end

    test "with no directory to send a browser to, none is minted" do
      Prima.Test.Env.put_app_env(:sanctum, :directory_url, nil)
      assert {:error, :no_directory} = SignIn.request(:sign_in, @browser)
    end

    test "a channel's request names the account it speaks for, and has no page", %{
      account: account
    } do
      assert {:error, {:invalid_argument, _}} = SignIn.request(:sign_in, {:channel, "pcl_1"})

      assert {:ok, %{url: nil}} =
               SignIn.request(:sign_in, {:channel, "pcl_1"}, identifier: account.identifier)
    end
  end

  describe "a sign-in" do
    test "setup's admits the first person, bound to the key and head, and then opens nothing", %{
      account: account
    } do
      user = first!(account)

      assert user.admission == "setup"
      assert user.platform_admin_at
      assert {:ok, identifier} = Users.identifier(user.id)
      assert identifier == account.identifier

      [session] = sessions(user.id)
      assert session.kid == Prima.Identity.Key.kid(hd(account.passkeys).pub)
      assert session.head == DirectoryServer.head(account)

      # The door admits the first account by the allow setup wrote.
      assert {:ok, true} = Sanctum.Door.Store.allowed("identifier", account.identifier)
    end

    test "a person this CYFR holds signs in again by any passkey their log lists", %{
      dir: dir,
      account: account
    } do
      user = first!(account)
      account = passkey!(account, dir)
      second = List.last(account.passkeys)

      {request, _url} = minted(:sign_in, @browser)

      assert {:ok, %{purpose: :sign_in, user: %{id: same}, session_token: token}} =
               SignIn.answer(
                 DirectoryServer.passkey_answer(request, account, second),
                 @browser
               )

      assert same == user.id
      assert is_binary(token)
    end

    test "a new account is admitted by the door's * alone, and refused without it", %{
      dir: dir,
      account: account
    } do
      first = first!(account)
      stranger = dir.dir |> DirectoryServer.account!(dir.url) |> passkey!(dir)

      {request, _url} = minted(:sign_in, @browser)

      assert {:error, {:door, :not_allowed}} =
               SignIn.answer(answer(request, stranger), @browser)

      {:ok, _entry} = Sanctum.Door.Store.allow("wildcard", "*", first.id)
      {request, _url} = minted(:sign_in, @browser)

      assert {:ok, %{user: %{admission: "open"}}} =
               SignIn.answer(answer(request, stranger), @browser)
    end

    test "the setup token admits no second account", %{dir: dir, account: account} do
      _first = first!(account)
      stranger = dir.dir |> DirectoryServer.account!(dir.url) |> passkey!(dir)

      {request, _url} = minted(:sign_in, @browser, admission: {:setup, @token})

      assert {:error, :setup_closed} = SignIn.answer(answer(request, stranger), @browser)
    end
  end

  # Create your account on the setup and invitation pages sends the browser
  # to the new page offered a name; the answer records it as the person's
  # name only once the registry names the answering account by it.
  describe "a name offered at the new page" do
    test "is recorded once the registry names the account that answered by it", %{
      account: account,
      dir: dir
    } do
      RegistryStub.handles!(%{"mira" => account.identifier}, dir.url)

      {request, url} =
        minted(:sign_in, @browser, admission: {:setup, @token}, page: {:new, "mira"})

      assert url =~ "/account/new#name=mira&request="

      assert {:ok, %{purpose: :sign_in, user: %{id: id, namespace: "mira"}}} =
               SignIn.answer(answer(request, account), @browser)

      assert {:ok, %{namespace: "mira"}} = Users.get(id)
      assert_received {:registry_request, %{path: "/v1/handles/mira"}}
    end

    test "records nothing when the registry names another account, none, or does not answer; the sign-in stands",
         %{account: account, dir: dir} do
      first = first!(account)
      {:ok, _entry} = Sanctum.Door.Store.allow("wildcard", "*", first.id)
      stranger = DirectoryServer.account!(dir.dir, dir.url)
      RegistryStub.handles!(%{"taken" => stranger.identifier, "lost" => :close}, dir.url)

      for name <- ["taken", "unheld", "lost"] do
        newcomer = dir.dir |> DirectoryServer.account!(dir.url) |> passkey!(dir)
        {request, _url} = minted(:sign_in, @browser, page: {:new, name})

        assert {:ok, %{purpose: :sign_in, user: user, session_token: token}} =
                 SignIn.answer(answer(request, newcomer), @browser),
               name

        assert is_binary(token)
        assert {:ok, %{namespace: nil}} = Users.get(user.id), name
      end
    end

    test "a sign-in that offered none learns the account's name from the registry, by its identifier",
         %{account: account, dir: dir} do
      RegistryStub.handles!(%{"mira" => account.identifier}, dir.url)
      {request, url} = minted(:sign_in, @browser, admission: {:setup, @token}, page: {:new, nil})
      assert url =~ "/account/new#name=&request="

      assert {:ok, %{purpose: :sign_in, user: %{id: id, namespace: "mira"}}} =
               SignIn.answer(answer(request, account), @browser)

      assert {:ok, %{namespace: "mira"}} = Users.get(id)
      assert_received {:registry_request, %{path: "/v1/identities/" <> rest}}
      assert rest == account.identifier <> "/handle"
      refute_received {:registry_request, %{path: "/v1/handles/" <> _}}

      # Recorded once: the next sign-in asks nothing.
      {again, _url} = minted(:sign_in, @browser)

      assert {:ok, %{user: %{namespace: "mira"}}} =
               SignIn.answer(answer(again, account), @browser)

      refute_received {:registry_request, _}
    end

    test "an account holding no name, or a registry that does not answer, records nothing; the sign-in stands",
         %{account: account, dir: dir} do
      RegistryStub.handles!(%{}, dir.url)
      {request, _url} = minted(:sign_in, @browser, admission: {:setup, @token}, page: {:new, nil})

      assert {:ok, %{purpose: :sign_in, user: user, session_token: token}} =
               SignIn.answer(answer(request, account), @browser)

      assert is_binary(token)
      assert {:ok, %{namespace: nil}} = Users.get(user.id)
      assert_received {:registry_request, %{path: "/v1/identities/" <> _}}

      RegistryStub.start!(fn _ -> :close end)
      {again, _url} = minted(:sign_in, @browser)

      capture_log(fn ->
        assert {:ok, %{user: %{namespace: nil}}} = SignIn.answer(answer(again, account), @browser)
      end)
    end
  end

  describe "an answer" do
    test "replayed, it meets a spent request", %{account: account} do
      _first = first!(account)
      {request, _url} = minted(:sign_in, @browser)
      answered = answer(request, account)

      assert {:ok, _signed_in} = SignIn.answer(answered, @browser)
      assert {:error, :answer_refused} = SignIn.answer(answered, @browser)
    end

    test "from another browser signs no one in, and spends the request", %{account: account} do
      user = first!(account)
      {request, _url} = minted(:sign_in, @browser)
      answered = answer(request, account)
      before = length(sessions(user.id))

      assert {:error, :answer_refused} =
               SignIn.answer(answered, {:browser, "csrf-of-another-browser"})

      assert {:error, :answer_refused} =
               SignIn.answer(answered, {:session, :crypto.strong_rand_bytes(32)})

      assert {:error, :answer_refused} = SignIn.answer(answered, @browser)
      assert length(sessions(user.id)) == before
    end

    test "past its request's expiry signs no one in", %{account: account} do
      user = first!(account)
      {request, _url} = minted(:sign_in, @browser)
      before = length(sessions(user.id))

      assert {:error, :answer_refused} =
               SignIn.answer(answer(request, account), @browser, now: request.expires_at)

      assert length(sessions(user.id)) == before
    end

    test "to a request this CYFR minted for another audience signs no one in", %{
      account: account
    } do
      user = first!(account)
      {request, _url} = minted(:sign_in, @browser)
      before = length(sessions(user.id))

      # The same request held, while this CYFR now answers at another origin:
      # the request's audience is no longer this CYFR's.
      Prima.Test.Env.put_app_env(:sanctum, :public_url, "https://another.example")

      assert {:error, :answer_refused} = SignIn.answer(answer(request, account), @browser)
      assert length(sessions(user.id)) == before
    end

    test "as the fragment the account pages return, in its one spelling", %{account: account} do
      _first = first!(account)
      {request, _url} = minted(:sign_in, @browser)
      fragment = request |> answer(account) |> Prima.SignIn.fragment()

      assert {:error, :answer_refused} = SignIn.answer(fragment <> "=", @browser)
      assert {:ok, %{purpose: :sign_in}} = SignIn.answer(fragment, @browser)
    end

    test "by a passkey at another origin, without user verification, or of another account, is refused",
         %{dir: dir, account: account} do
      _first = first!(account)
      stranger = dir.dir |> DirectoryServer.account!(dir.url) |> passkey!(dir)

      for opts <- [
            [origin: "https://elsewhere.example"],
            [host: "elsewhere.example"],
            [flags: 0x01],
            [identifier: stranger.identifier]
          ] do
        {request, _url} = minted(:sign_in, @browser)

        assert {:error, :answer_refused} =
                 SignIn.answer(answer(request, account, opts), @browser),
               inspect(opts)
      end
    end

    test "of an account gone at its directory is refused gone", %{dir: dir, account: account} do
      _first = first!(account)
      DirectoryServer.tombstone(dir.dir, account.identifier)

      Arca.Repo.update_all(Arca.Schemas.DirectoryHead,
        set: [verified_at: ~U[2000-01-01 00:00:00Z]]
      )

      {request, _url} = minted(:sign_in, @browser)
      assert {:error, :identity_gone} = SignIn.answer(answer(request, account), @browser)
    end
  end

  describe "a confirmation" do
    setup %{account: account} do
      user = first!(account)
      {:ok, %{id: athanor_id}} = Sanctum.Tenancy.Athanors.get_by_owner(user.id)
      [session] = sessions(user.id)

      ctx = person_context(user, athanor_id, session)

      {:ok, record} =
        Prima.Confirmation.new(
          id: Prima.Confirmation.ref("cnf_" <> Base.url_encode64(:crypto.strong_rand_bytes(32))),
          home: @origin,
          rp_id: "cyfr.example",
          athanor: athanor_id,
          person: user.id,
          operation: "vault.create",
          args_digest: Prima.Digest.sha256("args"),
          action: "credential_entry",
          preview: %{home: @origin, athanor: "Home", operation: "vault.create"},
          challenge: :crypto.strong_rand_bytes(32),
          expires_at: System.system_time(:millisecond) + 300_000
        )

      {:ok, row} =
        Arca.PendingConfirmations.open(Sanctum.Context.actor(ctx), %{
          record: record,
          opener: "session:test",
          asker: %{"kind" => "session"}
        })

      %{ctx: ctx, row: row, binding: {:session, session.token_hash}}
    end

    test "names the record's digest, and a passkey of the person confirms it by its key and head",
         %{ctx: ctx, row: row, binding: binding, account: account} do
      {request, _url} = minted(:confirm, binding, ctx: ctx, ref: row.ref, back: "/a/x/vault")
      assert request.subject == row.digest

      assert {:ok, %{purpose: :confirm, ref: ref, back: "/a/x/vault"}} =
               SignIn.answer(answer(request, account), binding)

      assert ref == row.ref

      assert {:ok, %{state: "confirmed", proof: "passkey", kid: kid, head: head}} =
               Arca.PendingConfirmations.get(Sanctum.Context.actor(ctx), row.ref)

      assert kid == Prima.Identity.Key.kid(hd(account.passkeys).pub)
      assert head == DirectoryServer.head(account)
    end

    test "is refused for another person's answer, and the record stays pending", %{
      ctx: ctx,
      row: row,
      binding: binding,
      dir: dir
    } do
      stranger = dir.dir |> DirectoryServer.account!(dir.url) |> passkey!(dir)
      {request, _url} = minted(:confirm, binding, ctx: ctx, ref: row.ref)

      assert {:error, :answer_refused} = SignIn.answer(answer(request, stranger), binding)

      assert {:ok, %{state: "pending"}} =
               Arca.PendingConfirmations.get(Sanctum.Context.actor(ctx), row.ref)
    end

    test "a device of the person confirms over its own channel", %{
      ctx: ctx,
      row: row,
      account: account
    } do
      {pub, priv} = hd(account.devices)
      binding = {:channel, "pcl_device"}

      {request, nil} =
        minted(:confirm, binding, ctx: ctx, ref: row.ref, identifier: account.identifier)

      answer = DeviceAnswer.sign(request, Prima.Identity.Key.kid(pub), priv)

      # The proof names its client, which this test never paired: the store
      # holds a device's proof to its standing client.
      assert {:error, :revoked} = SignIn.answer(answer, binding)
    end

    test "a request names only the context's own pending record", %{binding: binding, ctx: ctx} do
      assert {:error, {:not_found, "confirmation", "cnf_absent"}} =
               SignIn.request(:confirm, binding, ctx: ctx, ref: "cnf_absent")

      assert {:error, :unauthenticated} =
               SignIn.request(:confirm, binding, ctx: %{ctx | athanor_id: nil}, ref: "cnf_absent")
    end
  end

  describe "a registry signature" do
    setup %{account: account} do
      Prima.Test.Env.put_app_env(:sanctum, :registry_url, "registry.example")
      user = first!(account)
      {:ok, %{id: athanor_id}} = Sanctum.Tenancy.Athanors.get_by_owner(user.id)
      [session] = sessions(user.id)

      %{
        user: user,
        ctx: person_context(user, athanor_id, session),
        binding: {:session, session.token_hash},
        channel: {:channel, "pcl_terminal"}
      }
    end

    @accept %{"policy_version" => "2026-09"}

    # A `:registry` request for the policy acceptance, minted for `ctx`.
    defp registry(binding, ctx, opts \\ []) do
      minted(:registry, binding, [ctx: ctx, operation: "policy.accept", body: @accept] ++ opts)
    end

    # The registry request a terminal signs with the device key `device`,
    # as its signed JSON, read back.
    defp signed_by({pub, priv}, registry) do
      {:ok, bytes} =
        Prima.RegistryRequest.sign(%{registry | signer: Prima.Identity.Key.kid(pub)}, priv)

      {:ok, signed} = bytes |> Jason.decode!() |> Prima.RegistryRequest.decode()
      {signed, bytes}
    end

    # The registry's own check of `bytes`, under the account's log at its
    # directory.
    defp registry_verifies(bytes, account) do
      {:ok, state} = Prima.Identity.verify_chain(account.log)

      Prima.RegistryRequest.verify(
        bytes,
        state,
        %{host: "registry.example", directory: account.url},
        System.system_time(:millisecond)
      )
    end

    test "is composed for the caller's account and expires with the request that carries it",
         %{ctx: ctx, binding: binding, account: account, dir: dir} do
      {request, url} = registry(binding, ctx, back: "/a/x/registry")

      assert url == dir.url <> "/account/sign#" <> Prima.SignIn.fragment(request)

      assert %Prima.RegistryRequest{
               registry: "registry.example",
               operation: "policy.accept",
               identifier: identifier,
               signer: nil,
               sig: nil,
               body: @accept,
               nonce: nonce,
               expires_at: expires_at
             } = request.registry_request

      assert identifier == account.identifier
      assert byte_size(nonce) == 16
      assert expires_at <= request.expires_at
      assert request.expires_at - expires_at < 1_000
    end

    test "a passkey of the caller's account signs it, and the registry takes the bytes", %{
      ctx: ctx,
      user: user,
      binding: binding,
      account: account
    } do
      {request, _url} = registry(binding, ctx, back: "/a/x/registry")

      assert {:ok,
              %{
                purpose: :registry,
                user_id: user_id,
                signed: signed,
                back: "/a/x/registry",
                registry_request: registry_request
              }} = SignIn.answer(answer(request, account), binding)

      assert user_id == user.id
      assert registry_request == request.registry_request
      assert {:ok, %{"signer" => signer, "sig" => %{}}} = Jason.decode(signed)
      assert signer == Prima.Identity.Key.kid(hd(account.passkeys).pub)
      assert {:ok, %Prima.RegistryRequest{body: @accept}} = registry_verifies(signed, account)
    end

    test "a terminal answers with the request it signed, found by its nonce, taken once", %{
      ctx: ctx,
      channel: channel,
      account: account
    } do
      {request, nil} = registry(channel, ctx, identifier: account.identifier)
      {signed, bytes} = signed_by(hd(account.devices), request.registry_request)

      assert {:ok, %{purpose: :registry, signed: ^bytes, registry_request: held}} =
               SignIn.answer(signed, channel, operation: "policy.accept", body: @accept)

      assert held == request.registry_request
      assert {:ok, _request} = registry_verifies(bytes, account)

      # Replayed, it meets a spent request.
      assert {:error, :answer_refused} = SignIn.answer(signed, channel)
    end

    test "a terminal's request that is not the one held, or under another channel, or late, is refused and spends it",
         %{ctx: ctx, channel: channel, account: account, dir: dir} do
      stranger = DirectoryServer.account!(dir.dir, dir.url)

      for change <- [
            &%{&1 | identifier: stranger.identifier},
            &%{&1 | body: %{"policy_version" => "2026-10"}},
            &%{&1 | operation: "tokens.mint", body: %{"label" => "laptop"}},
            &%{&1 | expires_at: &1.expires_at + 1}
          ] do
        {request, nil} = registry(channel, ctx, identifier: account.identifier)
        {signed, _bytes} = signed_by(hd(account.devices), change.(request.registry_request))
        assert {:error, :answer_refused} = SignIn.answer(signed, channel)

        # The nonce found the request, which is spent.
        {signed, _bytes} = signed_by(hd(account.devices), request.registry_request)
        assert {:error, :answer_refused} = SignIn.answer(signed, channel)
      end

      {request, nil} = registry(channel, ctx, identifier: account.identifier)
      {signed, _bytes} = signed_by(hd(account.devices), request.registry_request)
      assert {:error, :answer_refused} = SignIn.answer(signed, {:channel, "pcl_another"})
      assert {:error, :answer_refused} = SignIn.answer(signed, channel)

      {request, nil} = registry(channel, ctx, identifier: account.identifier)
      {signed, _bytes} = signed_by(hd(account.devices), request.registry_request)

      assert {:error, :answer_refused} =
               SignIn.answer(signed, channel, now: request.expires_at)
    end

    test "an answer for another operation or body than the caller names does nothing", %{
      ctx: ctx,
      binding: binding,
      channel: channel,
      account: account
    } do
      {request, _url} = registry(binding, ctx)

      assert {:error, :answer_refused} =
               SignIn.answer(answer(request, account), binding,
                 operation: "policy.accept",
                 body: %{"policy_version" => "2026-10"}
               )

      {request, nil} = registry(channel, ctx, identifier: account.identifier)
      {signed, _bytes} = signed_by(hd(account.devices), request.registry_request)

      assert {:error, :answer_refused} =
               SignIn.answer(signed, channel, operation: "tokens.mint", body: @accept)

      # A sign-in's answer is no registry signature.
      {request, _url} = minted(:sign_in, @browser)

      assert {:error, :answer_refused} =
               SignIn.answer(answer(request, account), @browser,
                 operation: "policy.accept",
                 body: @accept
               )
    end

    test "a passkey of another account, under another session, or past the expiry signs nothing",
         %{ctx: ctx, binding: binding, account: account, dir: dir} do
      stranger = dir.dir |> DirectoryServer.account!(dir.url) |> passkey!(dir)

      {request, _url} = registry(binding, ctx)
      assert {:error, :answer_refused} = SignIn.answer(answer(request, stranger), binding)

      {request, _url} = registry(binding, ctx)

      assert {:error, :answer_refused} =
               SignIn.answer(answer(request, account), {:session, :crypto.strong_rand_bytes(32)})

      assert {:error, :answer_refused} = SignIn.answer(answer(request, account), binding)

      {request, _url} = registry(binding, ctx)

      assert {:error, :answer_refused} =
               SignIn.answer(answer(request, account), binding, now: request.expires_at)

      # A device's answer to the request's digest is no registry signature.
      {request, nil} = registry({:channel, "pcl_device"}, ctx, identifier: account.identifier)
      {pub, priv} = hd(account.devices)

      assert {:error, :answer_refused} =
               SignIn.answer(
                 %DeviceAnswer{
                   challenge: request.challenge,
                   kid: Prima.Identity.Key.kid(pub),
                   sig: :crypto.sign(:eddsa, :none, <<0::256>>, [priv, :ed25519])
                 },
                 {:channel, "pcl_device"}
               )
    end

    test "names a registry, an operation the protocol knows and a body it takes", %{
      ctx: ctx,
      binding: binding
    } do
      assert {:error, {:invalid_argument, _}} =
               SignIn.request(:registry, binding,
                 ctx: ctx,
                 operation: "handle.rename",
                 body: %{}
               )

      assert {:error, {:invalid_argument, _}} =
               SignIn.request(:registry, binding,
                 ctx: ctx,
                 operation: "publisher.claim",
                 body: %{"slug" => "no-dot"}
               )

      Prima.Test.Env.put_app_env(:sanctum, :registry_url, "none")

      assert {:error, :no_registry} =
               SignIn.request(:registry, binding,
                 ctx: ctx,
                 operation: "policy.accept",
                 body: @accept
               )
    end

    test "binds a device to its channel and a browser to its session; nothing else asks", %{
      ctx: ctx,
      account: account
    } do
      device = %{ctx | auth_method: :device, client_id: "pcl_1", session_token_hash: nil}
      assert {:ok, {:channel, "pcl_1"}, [identifier: identifier]} = SignIn.binding(device)
      assert identifier == account.identifier

      assert {:ok, {:session, hash}, []} = SignIn.binding(ctx)
      assert hash == ctx.session_token_hash

      assert {:error, :unauthenticated} =
               SignIn.binding(%{ctx | session_token_hash: nil, auth_method: :api_key})

      assert {:error, :unauthenticated} =
               SignIn.binding(%{device | user_id: "usr_" <> String.duplicate("0", 26)})
    end
  end

  test "record_namespace/2 lands the claim on the users row and refuses a slug another identity holds",
       %{dir: dir, account: account} do
    %{id: uid} = first!(account)

    assert {:ok, user} = SignIn.record_namespace(uid, "user6ns")
    assert user.namespace == "user6ns"
    assert {:ok, %{id: ^uid}} = Users.get_by_namespace("user6ns")
    assert Sanctum.Namespace.lookup(uid) == "user6ns"

    # Idempotent; a different slug from the registry keeps the recorded one.
    assert {:ok, %{namespace: "user6ns"}} = SignIn.record_namespace(uid, "user6ns")
    assert {:ok, %{namespace: "user6ns"}} = SignIn.record_namespace(uid, "user6other")

    # Another person cannot take it, and a malformed slug is refused.
    {:ok, _entry} = Sanctum.Door.Store.allow("wildcard", "*", uid)
    other = dir.dir |> DirectoryServer.account!(dir.url) |> passkey!(dir)
    {request, _url} = minted(:sign_in, @browser)
    {:ok, %{user: %{id: jid}}} = SignIn.answer(answer(request, other), @browser)

    assert {:error, :namespace_owned_by_another_identity} =
             SignIn.record_namespace(jid, "user6ns")

    assert {:error, :invalid_slug} = SignIn.record_namespace(jid, "Not A Slug")
    assert {:error, :not_found} = SignIn.record_namespace("usr_ghost", "ghost")
  end
end
