# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PasskeysTest do
  @moduledoc """
  A person's passkeys at this relying home, through a real software
  authenticator (`Sanctum.TestContext.Authenticator`) and `wax_`'s real
  verification: registration and its first-method rule, the platform
  administrator's recovery, an assertion as the fresh proof of one
  pending confirmation, and the passkey door.

  A first passkey rests on a recent local sign-in only while no fresh
  method exists or has ever existed: never on a CYFR sign-in, never after
  the first method was used, whatever was revoked since, and never past a
  fresh method the person already holds (a verified email a code can
  reach, a linked door this home re-authenticates), which confirms it
  however recent the sign-in. Every other registration is confirmed by a
  fresh method, or waits for the administrator. An assertion proves
  exactly one record's digest, at this home's origin and RP ID, with user
  verification, by the record's own person, once.

  A person whose keys are at another home initializes no method from any
  sign-in: their first passkey waits for the administrator, whose
  authorization names their current `key_epoch` and `recovery_epoch`. It
  is bound to their recovery epoch, read fresh from their directory: it
  survives an ordinary rotation and a holder-adding recover, signing in
  under the new key epoch, and a recovery that replaces the live key
  retires it. A rotation or a recovery landing between a passkey's
  verification and the session it mints signs no one in: the sign-in
  pauses, and the retry verifies against the new head. Once they hold a
  fresh method here, a passkey here or a verified email a code can reach,
  they confirm their next passkey themselves, as anyone does.

  After a declared restore a suspended passkey signs no one in, proves no
  confirmation and is no fresh method. Its person re-enables it on an
  emailed code or a door's re-authentication, or with their recovery kit,
  never on a confirmation a passkey or device gave; that closes their
  restore and no one else's, as the administrator's recovery does, and a
  revoked passkey is never revived. An unenrolled administrator with no
  door, every method suspended and no pending registration has no way
  back in through any of these.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{Passkey, PendingConfirmation, PersonIdentity}
  alias Sanctum.Consent.Authz
  alias Sanctum.{Context, Passkeys, TestContext}
  alias Sanctum.TestContext.Authenticator
  alias Sanctum.Tenancy.Athanors
  alias Sanctum.Test.DirectoryServer

  setup tags do
    Arca.Cache.init()
    Arca.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A person admitted through a local door, with their own athanor and a
  # group, and the context a new session of theirs establishes there. Their
  # email is unverified unless `verified: true`: a verified one is a fresh
  # method wherever a code transport is configured. The door is GitHub
  # unless `provider:` and `key:` name another.
  defp person!(opts \\ []) do
    n = System.unique_integer([:positive])
    provider = Keyword.get(opts, :provider, "github")
    key = Keyword.get(opts, :key, "github|https://github.com|passkeys-#{n}")

    {:ok, user} =
      Sanctum.SignIn.admitted(
        %{
          id: key,
          provider: provider,
          email: "passkeys#{n}@example.com",
          verified: Keyword.get(opts, :verified, false),
          name: "Passkeys #{n}"
        },
        :allowed
      )

    {:ok, athanor} = Athanors.create_group(user.id, "Passkeys #{n}")
    %{user: user, athanor: athanor, key: key, ctx: session_ctx(user, athanor, opts)}
  end

  defp session_ctx(user, athanor, opts \\ []) do
    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: Keyword.get(opts, :provider, "github"),
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)
    ctx
  end

  defp authenticator, do: Authenticator.new("passkeys-#{System.unique_integer([:positive])}")

  defp credential(ctx, auth, opts \\ []) do
    {:ok, options} = Passkeys.register(ctx, %{})
    Authenticator.registration(auth, options, opts)
  end

  # A first passkey, under the local first-method rule.
  defp registered!(ctx, auth \\ authenticator()) do
    assert {:ok, %{status: "active", passkey: passkey}} =
             Passkeys.register(ctx, %{credential: credential(ctx, auth)})

    {auth, passkey}
  end

  # A first passkey of a person whose verified email a code can reach: that
  # email is a fresh method, so the registration asks for a confirmation,
  # which the code mailed to them proves.
  defp registered_by_code!(ctx, auth \\ authenticator()) do
    answer = credential(ctx, auth)

    assert {:error, {:confirmation_required, %{id: id, operation: "passkey.register"}}} =
             Passkeys.register(ctx, %{credential: answer})

    ref = Prima.Confirmation.ref(id)
    assert {:ok, %{method: "email"}} = Sanctum.Auth.EmailVerification.send_code(ctx, ref)
    assert_receive {:confirmation_code_mail, mail}

    assert {:ok, %{state: "confirmed"}} =
             Sanctum.Auth.EmailVerification.verify_code(ctx, ref, TestContext.MailSink.code(mail))

    assert {:ok, %{status: "active", passkey: passkey}} =
             Passkeys.register(%{ctx | confirmation_id: id}, %{credential: answer})

    {auth, passkey}
  end

  # Run `fun` under `ctx`; when it asks for a confirmation, prove it with
  # `auth` and run it again naming the record.
  defp confirming(ctx, auth, fun) do
    assert {:error, {:confirmation_required, %{id: id}}} = fun.(ctx)
    TestContext.prove!(ctx, id, auth)
    fun.(%{ctx | confirmation_id: id})
  end

  # Confirm the record the signal `id` answered with a fresh
  # re-authentication from a session that names no client: a confirmation
  # no passkey and no paired client gave. Answers the confirmed row.
  defp reauthenticated!(ctx, id) do
    assert {:ok, %{state: "confirmed"} = row} =
             Arca.PendingConfirmations.confirm(
               Context.actor(ctx),
               Prima.Confirmation.ref(id),
               %{proof: "oidc_reauth"}
             )

    assert {row.confirmed_passkey_id, row.confirmed_client_id} == {nil, nil}
    row
  end

  # A person admitted through an OpenID Connect door this home
  # re-authenticates, so a re-authentication is a fresh method of theirs.
  defp oidc_person! do
    issuer = oidc_issuer!()
    subject = "passkeys-#{System.unique_integer([:positive])}"
    person!(provider: "oidcc", key: Sanctum.Auth.Identity.key(:oidcc, issuer, subject))
  end

  # A passkey registered on a confirmation the person's re-authentication
  # gave, with `auth`: answers the register's answer.
  defp register_reauthenticated(ctx, auth) do
    answer = credential(ctx, auth)

    assert {:error, {:confirmation_required, %{id: id, operation: "passkey.register"}}} =
             Passkeys.register(ctx, %{credential: answer})

    reauthenticated!(ctx, id)
    {id, Passkeys.register(%{ctx | confirmation_id: id}, %{credential: answer})}
  end

  defp change(name \\ "prod-key", secret \\ "sk-secret") do
    %{
      operation: "vault.create",
      arguments: %{name: name, kind: "api_key", fields: %{"KEY" => secret}},
      resource: name
    }
  end

  defp opened!(ctx, change \\ change()) do
    assert {:error, {:confirmation_required, %{id: id}}} =
             Authz.check(ctx, :credential_entry, change)

    {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), Prima.Confirmation.ref(id))
    row
  end

  defp challenge(%{digest: "sha256:" <> hex}), do: Base.decode16!(hex, case: :lower)

  defp first_method_at(user_id) do
    Arca.Repo.one(
      from(p in PersonIdentity, where: p.user_id == ^user_id, select: p.first_method_at)
    )
  end

  defp passkeys(user_id), do: Arca.Repo.all(from(p in Passkey, where: p.user_id == ^user_id))

  defp sessions(user_id),
    do: Arca.Repo.all(from(s in Arca.Schemas.Session, where: s.user_id == ^user_id))

  # A code transport, so a verified email is a fresh method: set here, not
  # taken from whichever configuration runs the suite, and restored after.
  defp code_transport! do
    prior = Application.fetch_env(:sanctum, :confirmation_code_transport)
    on_exit(fn -> restore_env(:sanctum, :confirmation_code_transport, prior) end)
    Application.put_env(:sanctum, :confirmation_code_transport, TestContext.MailSink)
  end

  # This home signs people in through an OpenID Connect issuer, so a door
  # of that issuer linked to a person is one it re-authenticates
  # (`Sanctum.Auth.OIDC.reauth_available?/1`). Set here and restored
  # after; answers the issuer.
  defp oidc_issuer! do
    issuer = "https://idp.example.com"
    prior_issuer = Application.fetch_env(:sanctum, :oidc_issuer)
    prior_ueberauth = Application.fetch_env(:ueberauth, Ueberauth)

    on_exit(fn ->
      restore_env(:sanctum, :oidc_issuer, prior_issuer)
      restore_env(:ueberauth, Ueberauth, prior_ueberauth)
    end)

    Application.put_env(:sanctum, :oidc_issuer, issuer)

    Application.put_env(:ueberauth, Ueberauth,
      providers: [
        oidcc:
          {Ueberauth.Strategy.Oidcc, issuer: :cyfr_oidc, client_id: "cid", client_secret: "csec"}
      ]
    )

    issuer
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)

  defp age_sessions!(user_id, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    Arca.Repo.update_all(from(s in Arca.Schemas.Session, where: s.user_id == ^user_id),
      set: [inserted_at: at]
    )
  end

  # A denial of `user` that commits after a registration read the person's
  # session and before its own write: at the nonce claim, the first
  # statement the write makes outside its transaction. Answers the
  # handler's id, to detach once the registration answered.
  defp deny_in_the_window!(user) do
    test = self()
    id = {__MODULE__, :deny, make_ref()}

    :telemetry.attach(
      id,
      [:arca, :repo, :query],
      fn _event, _measurements, meta, _ ->
        if self() == test and meta[:source] == "request_rate_windows" and
             Process.get(:denied_in_window) == nil do
          Process.put(:denied_in_window, true)
          {:ok, _} = Sanctum.Tenancy.Users.deny(user)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    id
  end

  defp capture(events) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      events,
      fn event, measurements, meta, _ -> send(test, {:announced, event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  # A declared restore: its marker written, then consumed as the boot
  # consumes it. Answers the restore's id.
  defp restored! do
    {:ok, _marked} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
    assert {:ok, %{restore_id: restore_id}} = Arca.SecurityTransitions.restore(slot: :none)
    restore_id
  end

  defp restore_open(user_id) do
    {:ok, restore_id} = Arca.SecurityTransitions.restore_open(Prima.Actor.system(), user_id)
    restore_id
  end

  defp state(passkey_id),
    do: Arca.Repo.one(from(p in Passkey, where: p.id == ^passkey_id, select: p.state))

  # A kit credential the kit ingress would issue for the person's open
  # restore: its challenge held, then redeemed. Answers the credential's
  # digest.
  defp kit_credential!(user_id, restore_id) do
    expires_at = DateTime.add(DateTime.utc_now(), 600, :second)
    challenge = Prima.Digest.sha256(:crypto.strong_rand_bytes(32))
    credential = Prima.Digest.sha256(:crypto.strong_rand_bytes(32))
    system = Prima.Actor.system()

    :ok =
      Arca.SecurityTransitions.put_kit_challenge(
        system,
        user_id,
        restore_id,
        challenge,
        expires_at
      )

    :ok =
      Arca.SecurityTransitions.redeem_kit_challenge(
        system,
        user_id,
        restore_id,
        challenge,
        credential,
        expires_at
      )

    credential
  end

  # The confirmed record `id` attributed to the passkey `passkey_id`, as no
  # confirmation path writes it for a suspended one.
  defp attributed!(ctx, id, passkey_id) do
    ref = Prima.Confirmation.ref(id)

    {1, _} =
      Arca.Repo.update_all(
        from(c in PendingConfirmation, where: c.athanor_id == ^ctx.athanor_id and c.ref == ^ref),
        set: [confirmed_passkey_id: passkey_id]
      )
  end

  # The code mailed for the record `id`, proving it.
  defp code_confirmed!(ctx, id) do
    ref = Prima.Confirmation.ref(id)
    assert {:ok, %{method: "email"}} = Sanctum.Auth.EmailVerification.send_code(ctx, ref)
    assert_receive {:confirmation_code_mail, mail}

    assert {:ok, %{state: "confirmed"}} =
             Sanctum.Auth.EmailVerification.verify_code(ctx, ref, TestContext.MailSink.code(mail))
  end

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  describe "registration" do
    test "the options ask for a discoverable credential with user verification, and carry a token" do
      %{ctx: ctx} = person!()

      assert {:ok, %{public_key: options, registration: token, expires_at: %DateTime{}}} =
               Passkeys.register(ctx, %{})

      assert options["rp"]["id"] == Passkeys.rp_id()
      assert options["authenticatorSelection"]["userVerification"] == "required"
      assert options["authenticatorSelection"]["residentKey"] == "required"
      assert options["attestation"] == "none"
      assert byte_size(Base.url_decode64!(options["challenge"], padding: false)) == 32
      assert is_binary(token) and token != ""
      refute options["user"]["id"] == Base.url_encode64(ctx.user_id, padding: false)
    end

    test "a first passkey is confirmed by a verified email a code can reach, however recent the local sign-in" do
      code_transport!()
      %{ctx: ctx, user: user} = person!(verified: true)
      assert first_method_at(user.id) == nil
      assert Passkeys.fresh_method?(ctx)

      # The session is seconds old and from a local door: the exception's
      # ground, which a method that can confirm the registration closes.
      assert {:error, {:confirmation_required, %{operation: "passkey.register"}}} =
               Passkeys.register(ctx, %{credential: credential(ctx, authenticator())})

      assert passkeys(user.id) == []
      assert first_method_at(user.id) == nil

      # The code mailed to the person proves it, and the passkey lands
      # active, as their first method.
      assert {_auth, %{state: "active"}} = registered_by_code!(ctx)
      assert %DateTime{} = first_method_at(user.id)
    end

    test "a first passkey is confirmed by a linked door this home re-authenticates, however recent the sign-in" do
      issuer = oidc_issuer!()
      subject = "passkeys-#{System.unique_integer([:positive])}"

      %{ctx: ctx, user: user} =
        person!(provider: "oidcc", key: Sanctum.Auth.Identity.key(:oidcc, issuer, subject))

      assert first_method_at(user.id) == nil
      assert Sanctum.Auth.OIDC.reauth_available?(user.id)
      refute Sanctum.Auth.EmailVerification.code_available?(user.id)

      assert {:error, {:confirmation_required, %{operation: "passkey.register"}}} =
               Passkeys.register(ctx, %{credential: credential(ctx, authenticator())})

      assert passkeys(user.id) == []
      assert first_method_at(user.id) == nil
    end

    test "a local door's recent sign-in registers the first passkey, marks it for good and announces it" do
      %{ctx: ctx, user: user} = person!()
      capture([[:cyfr, :sanctum, :notify]])
      assert first_method_at(user.id) == nil
      # No fresh method here: the exception is the only ground.
      refute Passkeys.fresh_method?(ctx)

      {_auth, passkey} = registered!(ctx)

      assert passkey.state == "active"
      assert passkey.rp_id == Passkeys.rp_id()
      assert %DateTime{} = first_method_at(user.id)

      assert_receive {:announced, [:cyfr, :sanctum, :notify], _,
                      %{kind: :passkey_registered, athanor_id: personal}}

      assert personal == user.personal_athanor_id
    end

    test "a denial committing between the first-method check and the write keeps no passkey" do
      %{ctx: ctx, user: user, key: key} = person!()
      {:ok, _} = Sanctum.Door.Store.allow("user_id", key, "ops")
      auth = authenticator()
      answer = credential(ctx, auth)

      handler = deny_in_the_window!(user)
      assert {:error, reason} = Passkeys.register(ctx, %{credential: answer})
      :telemetry.detach(handler)

      assert Process.get(:denied_in_window)
      assert reason in [:not_standing, :not_authenticated]
      assert {:ok, %{status: "denied"}} = Sanctum.Tenancy.Users.get(user.id)
      assert Arca.Repo.all(from(p in Passkey, where: p.user_id == ^user.id)) == []
      assert first_method_at(user.id) == nil

      # Allowed again, the passkey signs no one in: none was kept.
      {:ok, denied} = Sanctum.Tenancy.Users.get(user.id)
      {:ok, _} = Sanctum.Tenancy.Users.allow(denied)
      held = Passkeys.sign_in_challenge()

      assert Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge)) ==
               {:error, :assertion_refused}
    end

    test "a denial committing before a pending registration's write keeps no pending passkey" do
      %{ctx: ctx, user: user, athanor: athanor} = person!()
      {auth, passkey} = registered!(ctx)
      {:ok, _} = confirming(ctx, auth, &Passkeys.revoke(&1, passkey.id))

      lost = session_ctx(user, athanor)
      answer = credential(lost, authenticator())

      handler = deny_in_the_window!(user)
      assert {:error, reason} = Passkeys.register(lost, %{credential: answer})
      :telemetry.detach(handler)

      assert Process.get(:denied_in_window)
      assert reason in [:not_standing, :not_authenticated]

      assert Arca.Repo.all(
               from(p in Passkey, where: p.user_id == ^user.id and p.state != "revoked")
             ) == []
    end

    test "a first passkey from a sign-in older than reauth_seconds is refused: sign in again" do
      %{ctx: ctx, user: user} = person!()
      age_sessions!(user.id, 301)

      assert Passkeys.register(ctx, %{credential: credential(ctx, authenticator())}) ==
               {:error, :reauth_required}

      assert first_method_at(user.id) == nil
      assert Arca.Repo.all(from(p in Passkey, where: p.user_id == ^user.id)) == []
    end

    test "a CYFR sign-in never initializes a method, however recent" do
      %{ctx: ctx, user: user, athanor: athanor} = person!()
      cyfr = session_ctx(user, athanor, provider: "cyfr")
      _ = ctx

      assert Passkeys.register(cyfr, %{credential: credential(cyfr, authenticator())}) ==
               {:error, :reauth_required}
    end

    test "a person holding a fresh method confirms another passkey, consumed with the row it writes" do
      %{ctx: ctx, user: user} = person!()
      {auth, _first} = registered!(ctx)
      capture([[:cyfr, :sanctum, :confirmation, :consumed]])
      second = credential(ctx, authenticator())

      assert {:ok, %{status: "active", passkey: %{state: "active"}}} =
               confirming(ctx, auth, &Passkeys.register(&1, %{credential: second}))

      assert_receive {:announced, [:cyfr, :sanctum, :confirmation, :consumed], _, meta}
      assert meta.operation == "passkey.register"
      assert Enum.sort(Map.keys(meta)) == [:athanor_id, :expires_at, :operation, :ref, :user_id]

      assert length(Arca.Repo.all(from(p in Passkey, where: p.user_id == ^user.id))) == 2
    end

    test "with a passkey held, a re-authentication no passkey or device gave adds no passkey; the passkey's own assertion does" do
      %{ctx: ctx, user: user} = person!()
      {auth, first} = registered!(ctx)
      assert %DateTime{} = first_method_at(user.id)

      assert {id, refused} = register_reauthenticated(ctx, authenticator())
      assert refused == {:error, Sanctum.Pairing.addition_refusal()}

      # Nothing is stored and the confirmation is not spent.
      assert Enum.map(passkeys(user.id), & &1.id) == [first.id]

      assert {:ok, %{state: "confirmed"}} =
               Arca.PendingConfirmations.get(Context.actor(ctx), Prima.Confirmation.ref(id))

      # The same addition confirmed by the passkey they hold lands active.
      third = credential(ctx, authenticator())

      assert {:ok, %{status: "active", passkey: %{state: "active"}}} =
               confirming(ctx, auth, &Passkeys.register(&1, %{credential: third}))

      assert length(passkeys(user.id)) == 2
    end

    test "before any passkey or device, a re-authentication registers the first passkey and sets the latch" do
      %{ctx: ctx, user: user} = oidc_person!()
      assert first_method_at(user.id) == nil
      assert Passkeys.fresh_method?(ctx)

      assert {_id, {:ok, %{status: "active", passkey: %{state: "active"}}}} =
               register_reauthenticated(ctx, authenticator())

      assert %DateTime{} = first_method_at(user.id)
    end

    test "revoking every passkey never reopens the latch: a re-authentication still adds none" do
      %{ctx: ctx, user: user, athanor: athanor} = oidc_person!()
      auth = authenticator()

      assert {_id, {:ok, %{status: "active", passkey: passkey}}} =
               register_reauthenticated(ctx, auth)

      assert {:ok, %{state: "revoked"}} = confirming(ctx, auth, &Passkeys.revoke(&1, passkey.id))
      latched = first_method_at(user.id)
      assert %DateTime{} = latched

      # A new session of theirs: the door it came through still
      # re-authenticates, and no passkey stands.
      later = session_ctx(user, athanor, provider: "oidcc")
      assert Passkeys.fresh_method?(later)

      assert {_id, refused} = register_reauthenticated(later, authenticator())
      assert refused == {:error, Sanctum.Pairing.addition_refusal()}

      assert Enum.filter(passkeys(user.id), &(&1.state != "revoked")) == []
      assert first_method_at(user.id) == latched
    end

    test "the last active passkey of a person with no linked door is their way in, and stays" do
      %{ctx: ctx, user: user} = person!()
      {auth, first} = registered!(ctx)
      second = credential(ctx, authenticator())

      Arca.Repo.delete_all(from(i in Arca.Schemas.ExternalIdentity, where: i.user_id == ^user.id))

      # Refused before any proof is asked; the passkey stands.
      assert {:error, {:conflict, message}} = Passkeys.revoke(ctx, first.id)
      assert message =~ "only way to sign in"
      assert message =~ "link a door"
      assert {:ok, %{state: "active"}} = Arca.Passkeys.get(Prima.Actor.system(), first.id)

      # With another active passkey, the first goes; the other is then the last.
      assert {:ok, %{passkey: %{id: second_id, state: "active"}}} =
               confirming(ctx, auth, &Passkeys.register(&1, %{credential: second}))

      assert {:ok, %{state: "revoked"}} = confirming(ctx, auth, &Passkeys.revoke(&1, first.id))
      assert {:error, {:conflict, _}} = Passkeys.revoke(ctx, second_id)
      assert {:ok, %{state: "active"}} = Arca.Passkeys.get(Prima.Actor.system(), second_id)
    end

    test "revoking the last passkey never reopens the exception: a recent session waits for the administrator" do
      %{ctx: ctx, user: user, athanor: athanor} = person!()
      {auth, passkey} = registered!(ctx)

      assert {:ok, %{state: "revoked"}} =
               confirming(ctx, auth, &Passkeys.revoke(&1, passkey.id))

      # A stolen, recent session: no fresh method is left, and the mark stays.
      stolen = session_ctx(user, athanor)
      replacement = credential(stolen, authenticator())

      assert {:ok,
              %{
                status: "awaiting_administrator",
                passkey_id: pending,
                registration_digest: digest
              }} =
               Passkeys.register(stolen, %{credential: replacement})

      assert "sha256:" <> _ = digest
      assert {:ok, %{state: "pending"}} = Arca.Passkeys.get(Prima.Actor.system(), pending)

      assert Arca.Repo.all(
               from(c in PendingConfirmation,
                 where: c.user_id == ^user.id and c.operation == "passkey.register"
               )
             ) == []
    end

    test "a ceremony that does not verify registers nothing" do
      %{ctx: ctx, user: user} = person!()
      auth = authenticator()
      {:ok, options} = Passkeys.register(ctx, %{})

      for opts <- [
            [uv: false],
            [origin: "https://evil.example"],
            [rp_id: "evil.example"],
            [challenge: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)]
          ] do
        bad = Authenticator.registration(auth, options, opts)

        assert Passkeys.register(ctx, %{credential: bad}) == {:error, :registration_refused},
               inspect(opts)
      end

      garbled =
        put_in(Authenticator.registration(auth, options)["response"]["clientDataJSON"], "!!")

      assert Passkeys.register(ctx, %{credential: garbled}) == {:error, :registration_refused}

      another_token = put_in(Authenticator.registration(auth, options)["registration"], "e30")

      assert Passkeys.register(ctx, %{credential: another_token}) ==
               {:error, :registration_refused}

      assert Arca.Repo.all(from(p in Passkey, where: p.user_id == ^user.id)) == []
    end

    test "one ceremony registers at most one passkey: its token is spent" do
      %{ctx: ctx} = person!()
      auth = authenticator()
      answer = credential(ctx, auth)

      assert {:ok, %{status: "active", passkey: passkey}} =
               Passkeys.register(ctx, %{credential: answer})

      assert {:ok, _revoked} = confirming(ctx, auth, &Passkeys.revoke(&1, passkey.id))

      assert Passkeys.register(ctx, %{credential: answer}) == {:error, :registration_refused}
    end

    test "a key, a guest and an anonymous caller register nothing" do
      %{ctx: ctx} = person!()

      assert Passkeys.register(%{ctx | auth_method: :api_key}, %{}) ==
               {:error, {:surface_not_permitted, :api_key}}

      assert Passkeys.register(Context.enter_guest(ctx), %{}) == {:error, :guest_plane}

      assert Passkeys.register(Context.build(%{authenticated: false}), %{}) ==
               {:error, :unauthenticated}
    end
  end

  # ---------------------------------------------------------------------------
  # A person whose keys are at another home
  # ---------------------------------------------------------------------------

  describe "a person whose keys are at another home" do
    setup do
      tls = DirectoryServer.tls()
      DirectoryServer.listen!()
      DirectoryServer.seam!(tls)

      on_exit(fn ->
        Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
      end)

      directory = DirectoryServer.start!(tls)
      identity = DirectoryServer.identity!(directory.dir, directory.url)
      key = Sanctum.Auth.Identity.cyfr_key(identity.url, identity.identifier)

      # Admitted through the `cyfr` door: a remote person, judged by the
      # identifier, with a group to work in here and no athanor of their own.
      {:ok, _} = Sanctum.Door.Store.allow("identifier", identity.identifier, "ops")

      {:ok, user} =
        Sanctum.SignIn.admitted(
          %{
            id: key,
            provider: "cyfr",
            email: nil,
            verified: :unknown,
            name: nil,
            remote: %{identifier: identity.identifier, directory_url: identity.url}
          },
          :allowed
        )

      # Their head cached, as the door caches it when it admits them.
      DirectoryServer.cached!(identity)

      {:ok, athanor} =
        Athanors.create_group(user.id, "Remote #{System.unique_integer([:positive])}")

      %{ctx: admin_ctx} = person!()
      {admin_auth, _} = registered!(admin_ctx)

      %{
        dir: directory.dir,
        server: directory.server,
        identity: identity,
        user: user,
        athanor: athanor,
        ctx: session_ctx(user, athanor, provider: "cyfr"),
        admin: %{admin_ctx | platform_admin: true},
        admin_auth: admin_auth
      }
    end

    defp pending!(ctx, auth) do
      assert {:ok, %{status: "awaiting_administrator"} = pending} =
               Passkeys.register(ctx, %{credential: credential(ctx, auth)})

      pending
    end

    defp recovery_args(user, pending) do
      %{
        user_id: user.id,
        passkey_id: pending.passkey_id,
        registration_digest: pending.registration_digest
      }
    end

    # The person's pending passkey, authorized by the administrator.
    defp authorized!(context, auth) do
      pending = pending!(context.ctx, auth)

      assert {:ok, %{status: "active"}} =
               confirming(
                 context.admin,
                 context.admin_auth,
                 &Passkeys.recover_admin(&1, recovery_args(context.user, pending))
               )

      pending
    end

    defp signed_in(auth) do
      held = Passkeys.sign_in_challenge()

      Passkeys.sign_in(
        Map.take(held, [:challenge, :expires_at]),
        Authenticator.assertion(auth, held.challenge)
      )
    end

    defp session_epoch(token) do
      {:ok, %{identity_key_epoch: epoch}} =
        Arca.SessionStorage.get_session(Sanctum.Session.token_hash(token))

      epoch
    end

    test "a sign-in, however recent, initializes no method: the credential waits for the administrator, bound to the recovery epoch",
         %{ctx: ctx, user: user, identity: identity, athanor: athanor} do
      pending = pending!(ctx, authenticator())

      assert {:ok, %{state: "pending", identity_recovery_epoch: epoch}} =
               Arca.Passkeys.get(Prima.Actor.system(), pending.passkey_id)

      assert epoch == DirectoryServer.recovery_epoch(identity)
      assert is_nil(first_method_at(user.id))

      # A door linked here is no local first method for them either.
      linked = session_ctx(user, athanor, provider: "github")

      assert {:ok, %{status: "awaiting_administrator"}} =
               Passkeys.register(linked, %{credential: credential(linked, authenticator())})

      # Nor does a session alone confirm a sensitive change for them.
      assert {:error, {:confirmation_required, _}} =
               Authz.check(ctx, :credential_entry, change())
    end

    test "the administrator activates exactly the pending registration, under their own proof",
         context do
      pending = authorized!(context, authenticator())

      assert {:ok, %{state: "active", identity_recovery_epoch: epoch}} =
               Arca.Passkeys.get(Prima.Actor.system(), pending.passkey_id)

      assert epoch == DirectoryServer.recovery_epoch(context.identity)
    end

    test "an authorization made before an ordinary rotation is asked again; the registration stays",
         %{admin: admin, admin_auth: admin_auth, user: user} = context do
      pending = pending!(context.ctx, authenticator())
      args = recovery_args(user, pending)

      assert {:error, {:confirmation_required, %{id: id}}} = Passkeys.recover_admin(admin, args)
      TestContext.prove!(admin, id, admin_auth)

      DirectoryServer.rotate!(context.dir, context.identity)

      # The authorization named the key epoch the rotation replaced.
      assert {:error, {:confirmation_required, %{id: again}}} =
               Passkeys.recover_admin(%{admin | confirmation_id: id}, args)

      assert again != id

      assert {:ok, %{state: "pending"}} =
               Arca.Passkeys.get(Prima.Actor.system(), pending.passkey_id)

      assert {:ok, %{status: "active"}} =
               confirming(admin, admin_auth, &Passkeys.recover_admin(&1, args))
    end

    test "an authorization made before a recovery activates nothing after it: the registration is gone with its epoch",
         %{admin: admin, admin_auth: admin_auth, user: user} = context do
      pending = pending!(context.ctx, authenticator())
      args = recovery_args(user, pending)

      assert {:error, {:confirmation_required, %{id: id}}} = Passkeys.recover_admin(admin, args)
      TestContext.prove!(admin, id, admin_auth)

      DirectoryServer.recover!(context.dir, context.identity)

      assert {:error, {:not_found, "pending passkey", _}} =
               Passkeys.recover_admin(%{admin | confirmation_id: id}, args)

      assert {:ok, %{state: "revoked"}} =
               Arca.Passkeys.get(Prima.Actor.system(), pending.passkey_id)

      # The administrator's proof was never spent on it.
      assert {:ok, %{state: "confirmed"}} =
               Arca.PendingConfirmations.get(Context.actor(admin), Prima.Confirmation.ref(id))
    end

    test "a pending credential revoked or substituted after the administrator's preview is not the one activated",
         %{admin: admin, admin_auth: admin_auth, user: user} = context do
      first = pending!(context.ctx, authenticator())
      args = recovery_args(user, first)

      assert {:error, {:confirmation_required, %{id: id}}} = Passkeys.recover_admin(admin, args)
      TestContext.prove!(admin, id, admin_auth)

      # The person's pending credential is replaced by another.
      {:ok, _} = Arca.Passkeys.revoke(Prima.Actor.system(), first.passkey_id)
      second = pending!(context.ctx, authenticator())

      assert {:error, {:not_found, "pending passkey", _}} =
               Passkeys.recover_admin(%{admin | confirmation_id: id}, args)

      # Named by the substitute's id with the previewed digest, it is not
      # the registration the administrator saw.
      assert {:error, _refused} =
               Passkeys.recover_admin(%{admin | confirmation_id: id}, %{
                 args
                 | passkey_id: second.passkey_id
               })

      assert {:ok, %{state: "pending"}} =
               Arca.Passkeys.get(Prima.Actor.system(), second.passkey_id)
    end

    # Run `move` once, in the sign-in's own process, at the door's read of
    # the person's linked identities: after their passkey was verified
    # against a fresh head, and before their session is minted. Its answer
    # is kept under `:moved_in_window`. Answers the handler's id, to
    # detach once the sign-in answered.
    defp between_verification_and_mint!(move) do
      test = self()
      id = {__MODULE__, :between_verification_and_mint, make_ref()}

      :telemetry.attach(
        id,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, _ ->
          if self() == test and meta[:source] == "external_identities" and
               Process.get(:moved_in_window) == nil do
            Process.put(:moved_in_window, move.())
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
      id
    end

    test "a recovery landing between a passkey's verification and the mint signs no one in, and the retry finds the passkey retired",
         %{user: user} = context do
      auth = authenticator()
      pending = authorized!(context, auth)

      handler =
        between_verification_and_mint!(fn ->
          DirectoryServer.recover!(context.dir, context.identity)
        end)

      assert signed_in(auth) == {:error, :identity_stale}
      :telemetry.detach(handler)
      assert %{} = recovered = Process.get(:moved_in_window)

      # The mint's own fresh read took the recovery in: the passkey went
      # with the recovery epoch, the setup's session with the key epoch,
      # and no session was minted under either epoch.
      assert {:ok, %{key_epoch: epoch}} =
               Arca.DirectoryHeads.get(Prima.Actor.system(), context.identity.identifier)

      assert epoch == DirectoryServer.key_epoch(recovered)

      assert {:ok, %{state: "revoked"}} =
               Arca.Passkeys.get(Prima.Actor.system(), pending.passkey_id)

      assert sessions(user.id) == []

      # The retry verifies against the new head, which retired the passkey.
      assert signed_in(auth) == {:error, :assertion_refused}
      assert sessions(user.id) == []
    end

    test "an ordinary rotation landing between a passkey's verification and the mint pauses the sign-in, and the retry signs in under the new key epoch",
         %{user: user} = context do
      auth = authenticator()
      pending = authorized!(context, auth)

      handler =
        between_verification_and_mint!(fn ->
          DirectoryServer.rotate!(context.dir, context.identity)
        end)

      assert signed_in(auth) == {:error, :identity_stale}
      :telemetry.detach(handler)
      assert %{} = rotated = Process.get(:moved_in_window)

      # Nothing was minted under the epoch the passkey was verified under
      # nor the one the rotation introduced; the passkey stays.
      assert sessions(user.id) == []

      assert {:ok, %{state: "active"}} =
               Arca.Passkeys.get(Prima.Actor.system(), pending.passkey_id)

      assert {:ok, %{session_token: token}} = signed_in(auth)
      assert session_epoch(token) == DirectoryServer.key_epoch(rotated)
      assert [%{provider: "passkey"}] = sessions(user.id)
    end

    test "an active passkey survives an ordinary rotation and a holder-adding recover, signing in under the new key epoch, and a recovery retires it",
         context do
      auth = authenticator()
      pending = authorized!(context, auth)
      assert {:ok, %{session_token: before}} = signed_in(auth)
      assert session_epoch(before) == DirectoryServer.key_epoch(context.identity)

      # The rotation retires the session at this home's next fresh head;
      # the passkey stays, and its next sign-in binds the new key epoch.
      rotated = DirectoryServer.rotate!(context.dir, context.identity)
      {:ok, _} = Sanctum.IdentityFreshness.fresh!(context.identity.identifier)

      assert {:error, :not_found} =
               Arca.SessionStorage.get_session(Sanctum.Session.token_hash(before))

      assert {:ok, %{session_token: token}} = signed_in(auth)
      assert session_epoch(token) == DirectoryServer.key_epoch(rotated)

      holder = DirectoryServer.recover!(context.dir, rotated, keep_live: true)
      assert {:ok, %{session_token: token}} = signed_in(auth)
      assert session_epoch(token) == DirectoryServer.key_epoch(holder)

      # The earlier session was bound to the key epoch the recover replaced.
      assert {:ok, %{state: "active"}} =
               Arca.Passkeys.get(Prima.Actor.system(), pending.passkey_id)

      DirectoryServer.recover!(context.dir, holder)
      assert {:error, :assertion_refused} = signed_in(auth)

      assert {:ok, %{state: "revoked"}} =
               Arca.Passkeys.get(Prima.Actor.system(), pending.passkey_id)
    end

    test "proves a confirmation here with that passkey, the head read fresh first", context do
      auth = authenticator()
      authorized!(context, auth)
      ctx = session_ctx(context.user, context.athanor, provider: "cyfr")

      assert {:error, {:confirmation_required, %{id: id}}} =
               Authz.check(ctx, :credential_entry, change())

      TestContext.prove!(ctx, id, auth)
      assert :ok = Authz.confirm(%{ctx | confirmation_id: id}, :credential_entry, change())

      # An open confirmation is bound to the key epoch it was asked under:
      # a rotation voids it.
      assert {:error, {:confirmation_required, %{id: open}}} =
               Authz.check(ctx, :credential_entry, change("other-key"))

      DirectoryServer.rotate!(context.dir, context.identity)
      {:ok, _} = Sanctum.IdentityFreshness.fresh!(context.identity.identifier)

      assert {:ok, %{state: "voided"}} =
               Arca.PendingConfirmations.get(Context.actor(ctx), Prima.Confirmation.ref(open))
    end

    test "with a passkey here, their next passkey is theirs to confirm by an assertion of it, and lands active",
         %{ctx: ctx, user: user, admin: admin, admin_auth: admin_auth} = context do
      auth = authenticator()

      # With no fresh method here, the registration waits for the
      # administrator, who authorizes it.
      refute Passkeys.fresh_method?(ctx)

      assert {:ok, %{status: "awaiting_administrator"} = first} =
               Passkeys.register(ctx, %{credential: credential(ctx, auth)})

      assert {:ok, %{status: "active"}} =
               confirming(
                 admin,
                 admin_auth,
                 &Passkeys.recover_admin(&1, recovery_args(user, first))
               )

      # That passkey is a fresh method here: the next registration asks the
      # person, who proves it with an assertion of the first.
      assert Passkeys.fresh_method?(ctx)
      second = credential(ctx, authenticator())

      assert {:ok, %{status: "active", passkey: %{id: id, state: "active"}}} =
               confirming(ctx, auth, &Passkeys.register(&1, %{credential: second}))

      assert {:ok, %{state: "active", identity_recovery_epoch: epoch}} =
               Arca.Passkeys.get(Prima.Actor.system(), id)

      assert epoch == DirectoryServer.recovery_epoch(context.identity)
    end

    test "with a verified email a code can reach, their next passkey is theirs to confirm by that code, and lands active",
         %{ctx: ctx, user: user} = context do
      # The email method needs a code transport. Set here, not taken from
      # whichever configuration runs the suite, and restored after.
      prior = Application.fetch_env(:sanctum, :confirmation_code_transport)

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:sanctum, :confirmation_code_transport, value)
          :error -> Application.delete_env(:sanctum, :confirmation_code_transport)
        end
      end)

      Application.put_env(:sanctum, :confirmation_code_transport, TestContext.MailSink)

      # The `cyfr` door admitted them with no email: no fresh method, and
      # the registration waits for the administrator.
      refute Passkeys.fresh_method?(ctx)

      assert {:ok, %{status: "awaiting_administrator"}} =
               Passkeys.register(ctx, %{credential: credential(ctx, authenticator())})

      email = "remote#{System.unique_integer([:positive])}@example.com"

      {:ok, _} =
        Arca.Users.update(Prima.Actor.system(), user.id, %{email: email, email_verified: true})

      # A verified email is no fresh method where no code can be sent…
      Application.delete_env(:sanctum, :confirmation_code_transport)
      refute Passkeys.fresh_method?(ctx)

      assert {:ok, %{status: "awaiting_administrator"}} =
               Passkeys.register(ctx, %{credential: credential(ctx, authenticator())})

      # …and is one where a code can: the registration asks the person, and
      # the code mailed to them proves it.
      Application.put_env(:sanctum, :confirmation_code_transport, TestContext.MailSink)
      assert Passkeys.fresh_method?(ctx)
      registration = credential(ctx, authenticator())

      assert {:error,
              {:confirmation_required, %{id: confirmation, operation: "passkey.register"}}} =
               Passkeys.register(ctx, %{credential: registration})

      ref = Prima.Confirmation.ref(confirmation)
      assert {:ok, %{method: "email"}} = Sanctum.Auth.EmailVerification.send_code(ctx, ref)
      assert_receive {:confirmation_code_mail, %{to: ^email} = mail}

      assert {:ok, %{state: "confirmed"}} =
               Sanctum.Auth.EmailVerification.verify_code(
                 ctx,
                 ref,
                 TestContext.MailSink.code(mail)
               )

      assert {:ok, %{status: "active", passkey: %{id: id, state: "active"}}} =
               Passkeys.register(%{ctx | confirmation_id: confirmation}, %{
                 credential: registration
               })

      assert {:ok, %{state: "active", identity_recovery_epoch: epoch}} =
               Arca.Passkeys.get(Prima.Actor.system(), id)

      assert epoch == DirectoryServer.recovery_epoch(context.identity)

      assert {:ok, %{state: "consumed"}} =
               Arca.PendingConfirmations.get(Context.actor(ctx), ref)
    end

    test "a directory that cannot be read pauses the person's registration and sensitive changes",
         %{ctx: ctx} = context do
      credential = credential(ctx, authenticator())
      DirectoryServer.Server.stop(context.server)

      assert {:error, :identity_stale} = Passkeys.register(ctx, %{credential: credential})
      assert {:error, :identity_stale} = Authz.check(ctx, :credential_entry, change())
    end
  end

  # ---------------------------------------------------------------------------
  # The administrator's recovery
  # ---------------------------------------------------------------------------

  describe "the administrator's recovery" do
    setup do
      %{ctx: ctx, user: user, athanor: athanor} = person!()
      {auth, passkey} = registered!(ctx)
      {:ok, _} = confirming(ctx, auth, &Passkeys.revoke(&1, passkey.id))

      lost = session_ctx(user, athanor)
      {:ok, pending} = Passkeys.register(lost, %{credential: credential(lost, authenticator())})

      %{ctx: admin_ctx} = admin = person!()
      {admin_auth, _} = registered!(admin_ctx)

      %{
        person: user,
        person_athanor: athanor,
        pending: pending,
        admin: %{admin_ctx | platform_admin: true},
        admin_auth: admin_auth,
        admin_athanor: admin.athanor
      }
    end

    test "authorizes the exact pending registration under the administrator's own proof, and announces it",
         %{person: person, pending: pending, admin: admin, admin_auth: admin_auth} = context do
      capture([[:cyfr, :sanctum, :notify]])

      args = %{
        user_id: person.id,
        passkey_id: pending.passkey_id,
        registration_digest: pending.registration_digest
      }

      assert {:ok, %{status: "active", passkey: %{id: id, state: "active"}}} =
               confirming(admin, admin_auth, &Passkeys.recover_admin(&1, args))

      assert id == pending.passkey_id

      assert {:ok, %{admin_confirmation_id: confirmation}} =
               Arca.Passkeys.get(Prima.Actor.system(), id)

      # The passkey records the administrator's confirmation by its ref,
      # never the secret their request presented.
      assert Prima.Confirmation.ref?(confirmation)

      assert {:ok, %{state: "consumed", user_id: admin_user}} =
               Arca.PendingConfirmations.get(Context.actor(admin), confirmation)

      assert admin_user == admin.user_id

      # The person's own clients hear of the new passkey, and they and the
      # members of every athanor they belong to hear of the recovery; the
      # administrator's athanor hears of neither.
      assert_receive {:announced, [:cyfr, :sanctum, :notify], _,
                      %{kind: :passkey_registered, athanor_id: registered}}

      assert registered == person.personal_athanor_id

      recovered =
        for _ <- 1..2 do
          assert_receive {:announced, [:cyfr, :sanctum, :notify], _,
                          %{kind: :passkey_recovered} = meta}

          meta.athanor_id
        end

      assert Enum.sort(recovered) ==
               Enum.sort([person.personal_athanor_id, context.person_athanor.id])

      admin_athanor = context.admin_athanor.id

      refute_received {:announced, [:cyfr, :sanctum, :notify], _,
                       %{kind: :passkey_recovered, athanor_id: ^admin_athanor}}

      refute_received {:announced, [:cyfr, :sanctum, :notify], _,
                       %{kind: :passkey_registered, athanor_id: ^admin_athanor}}
    end

    test "after a declared restore, the administrator's activation closes the person's restore alone",
         %{person: person, pending: pending, admin: admin, admin_athanor: admin_athanor} do
      restore_id = restored!()

      # Every session went with the restore, and the administrator's own
      # passkey is suspended: they confirm through a door.
      admin = %{
        session_ctx(%{id: admin.user_id, email: admin.email}, admin_athanor)
        | platform_admin: true
      }

      args = %{
        user_id: person.id,
        passkey_id: pending.passkey_id,
        registration_digest: pending.registration_digest
      }

      assert {:error, {:confirmation_required, %{id: id}}} = Passkeys.recover_admin(admin, args)
      reauthenticated!(admin, id)

      assert {:ok, %{status: "active", recovery_closed: true}} =
               Passkeys.recover_admin(%{admin | confirmation_id: id}, args)

      assert restore_open(person.id) == nil
      assert restore_open(admin.user_id) == restore_id
    end

    test "a person who no longer stands gains no passkey, and the administrator's proof is kept",
         %{person: person, pending: pending, admin: admin, admin_auth: admin_auth} do
      args = %{
        user_id: person.id,
        passkey_id: pending.passkey_id,
        registration_digest: pending.registration_digest
      }

      assert {:error, {:confirmation_required, %{id: id}}} = Passkeys.recover_admin(admin, args)
      TestContext.prove!(admin, id, admin_auth)

      # The person's row reads denied in the activation's transaction, as a
      # denial committing just before it leaves it; the pending credential
      # itself is left in place, so the refusal is the standing check's.
      Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^person.id),
        set: [status: "denied"]
      )

      assert {:error, {:conflict, message}} =
               Passkeys.recover_admin(%{admin | confirmation_id: id}, args)

      assert message =~ "no longer stands"

      assert {:ok, %{state: "pending"}} =
               Arca.Passkeys.get(Prima.Actor.system(), pending.passkey_id)

      # Rolled back with the activation, the administrator's confirmation
      # still stands proven.
      assert {:ok, %{state: "confirmed"}} =
               Arca.PendingConfirmations.get(Context.actor(admin), Prima.Confirmation.ref(id))
    end

    test "another digest, an ordinary member, or a session alone activates nothing",
         %{person: person, pending: pending, admin: admin, admin_auth: admin_auth} do
      wrong = %{
        user_id: person.id,
        passkey_id: pending.passkey_id,
        registration_digest: "sha256:" <> String.duplicate("0", 64)
      }

      assert {:error, {:conflict, _}} =
               confirming(admin, admin_auth, &Passkeys.recover_admin(&1, wrong))

      right = %{wrong | registration_digest: pending.registration_digest}

      assert Passkeys.recover_admin(%{admin | platform_admin: false}, right) ==
               {:error, :platform_admin_required}

      assert {:error, {:confirmation_required, _}} = Passkeys.recover_admin(admin, right)

      assert {:ok, %{state: "pending"}} =
               Arca.Passkeys.get(Prima.Actor.system(), pending.passkey_id)
    end
  end

  # ---------------------------------------------------------------------------
  # The proof of one pending confirmation
  # ---------------------------------------------------------------------------

  describe "assert/3" do
    setup do
      %{ctx: ctx} = fixture = person!()
      {auth, passkey} = registered!(ctx)
      Map.merge(fixture, %{auth: auth, passkey: passkey})
    end

    test "an assertion over the record's digest, with user verification, confirms it once",
         %{ctx: ctx, auth: auth, passkey: passkey} do
      capture([[:cyfr, :sanctum, :confirmation, :confirmed]])
      row = opened!(ctx)
      assertion = Authenticator.assertion(auth, challenge(row))

      assert {:ok, %{ref: ref, state: "confirmed"} = answer} =
               Passkeys.assert(ctx, row.ref, assertion)

      assert ref == row.ref
      refute Map.has_key?(answer, :id)

      assert {:ok, %{proof: "passkey", confirmed_passkey_id: confirmed_by}} =
               Arca.PendingConfirmations.get(Context.actor(ctx), row.ref)

      assert confirmed_by == passkey.id

      assert_receive {:announced, [:cyfr, :sanctum, :confirmation, :confirmed], _, meta}
      assert meta.ref == row.ref and meta.operation == "vault.create"
      refute inspect(meta) =~ "sk-secret"

      # The same assertion again, the zero counter unchanged: the record is
      # single-use.
      assert Passkeys.assert(ctx, row.ref, assertion) == {:error, :not_pending}
    end

    test "an assertion over a different digest is refused", %{ctx: ctx, auth: auth} do
      row = opened!(ctx)
      other = opened!(ctx, change("other-key"))

      assert Passkeys.assert(ctx, row.ref, Authenticator.assertion(auth, challenge(other))) ==
               {:error, :assertion_refused}
    end

    test "an assertion without user verification is refused", %{ctx: ctx, auth: auth} do
      row = opened!(ctx)

      assert Passkeys.assert(
               ctx,
               row.ref,
               Authenticator.assertion(auth, challenge(row), uv: false)
             ) ==
               {:error, :assertion_refused}
    end

    test "an assertion from another origin or RP ID, an A-scoped passkey for B, is refused",
         %{ctx: ctx, auth: auth} do
      row = opened!(ctx)

      for opts <- [
            [origin: "https://a.example"],
            [rp_id: "a.example"],
            [origin: "https://a.example", rp_id: "a.example"],
            [type: "webauthn.create"]
          ] do
        assert Passkeys.assert(ctx, row.ref, Authenticator.assertion(auth, challenge(row), opts)) ==
                 {:error, :assertion_refused},
               inspect(opts)
      end

      # A credential this home never registered.
      stranger = authenticator()

      assert Passkeys.assert(ctx, row.ref, Authenticator.assertion(stranger, challenge(row))) ==
               {:error, :assertion_refused}
    end

    test "a proof from another member is refused", %{ctx: ctx, athanor: athanor} do
      row = opened!(ctx)

      %{user: other_user} = other = person!()
      {other_auth, _} = registered!(other.ctx)

      {:ok, _seat} =
        Sanctum.Tenancy.Members.ensure(other_user.id, scope: "athanor", athanor_id: athanor.id)

      other_here = session_ctx(other_user, athanor)

      # Their own passkey over this record, and this record through their session.
      assert Passkeys.assert(
               other_here,
               row.ref,
               Authenticator.assertion(other_auth, challenge(row))
             ) ==
               {:error, {:not_found, "confirmation", row.ref}}

      assert Passkeys.assert(ctx, row.ref, Authenticator.assertion(other_auth, challenge(row))) ==
               {:error, :assertion_refused}
    end

    test "a counter that did not rise after a non-zero count is refused", %{ctx: ctx, auth: auth} do
      first = opened!(ctx)

      assert {:ok, _} =
               Passkeys.assert(
                 ctx,
                 first.ref,
                 Authenticator.assertion(auth, challenge(first), count: 5)
               )

      again = opened!(ctx, change("again"))

      assert Passkeys.assert(
               ctx,
               again.ref,
               Authenticator.assertion(auth, challenge(again), count: 5)
             ) ==
               {:error, :assertion_refused}

      assert Passkeys.assert(
               ctx,
               again.ref,
               Authenticator.assertion(auth, challenge(again), count: 0)
             ) ==
               {:error, :assertion_refused}

      assert {:ok, _} =
               Passkeys.assert(
                 ctx,
                 again.ref,
                 Authenticator.assertion(auth, challenge(again), count: 6)
               )
    end

    test "an authenticator that always reports zero is accepted on every record", %{
      ctx: ctx,
      auth: auth
    } do
      for name <- ~w(one two three) do
        row = opened!(ctx, change(name))

        assert {:ok, _} =
                 Passkeys.assert(ctx, row.ref, Authenticator.assertion(auth, challenge(row)))
      end
    end

    test "a stale assertion, for a record past its expiry, is refused", %{ctx: ctx, auth: auth} do
      row = opened!(ctx)

      # The record as it would stand had it opened long enough ago: its
      # expiry passed, and the digest it binds over that expiry.
      past = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:millisecond)
      {:ok, record} = Arca.PendingConfirmations.confirmation(%{row | expires_at: past})
      digest = Prima.Confirmation.digest(record)

      Arca.Repo.update_all(from(c in PendingConfirmation, where: c.ref == ^row.ref),
        set: [expires_at: past, digest: digest]
      )

      stale = %{row | digest: digest}

      assert Passkeys.assert(ctx, row.ref, Authenticator.assertion(auth, challenge(stale))) ==
               {:error, :expired}
    end

    test "a revoked passkey proves nothing", %{ctx: ctx, auth: auth, passkey: passkey} do
      second_auth = authenticator()
      second = credential(ctx, second_auth)
      {:ok, _} = confirming(ctx, auth, &Passkeys.register(&1, %{credential: second}))
      {:ok, _} = confirming(ctx, second_auth, &Passkeys.revoke(&1, passkey.id))

      row = opened!(ctx)

      assert Passkeys.assert(ctx, row.ref, Authenticator.assertion(auth, challenge(row))) ==
               {:error, :assertion_refused}
    end
  end

  # ---------------------------------------------------------------------------
  # After a declared restore
  # ---------------------------------------------------------------------------

  describe "after a declared restore" do
    # Two people with a verified email a code reaches, each with a passkey
    # the door admits them by, and a second passkey of the first.
    setup do
      code_transport!()
      %{ctx: ctx, user: user, athanor: athanor, key: key} = person!(verified: true)
      {auth, passkey} = registered_by_code!(ctx)
      second_auth = authenticator()
      answer = credential(ctx, second_auth)

      {:ok, %{passkey: second}} =
        confirming(ctx, auth, &Passkeys.register(&1, %{credential: answer}))

      {:ok, _} = Sanctum.Door.Store.allow("user_id", key, "ops")

      %{ctx: other_ctx, user: other} = person!(verified: true)
      {_other_auth, _other_passkey} = registered_by_code!(other_ctx)

      held = Passkeys.sign_in_challenge()
      assert {:ok, _} = Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge))

      restore_id = restored!()

      %{
        user: user,
        athanor: athanor,
        auth: auth,
        passkey: passkey,
        second: second,
        other: other,
        restore_id: restore_id,
        session: session_ctx(user, athanor)
      }
    end

    test "a suspended passkey signs no one in and proves no confirmation", %{
      session: session,
      auth: auth,
      passkey: passkey
    } do
      assert state(passkey.id) == "suspended"

      held = Passkeys.sign_in_challenge()

      assert Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge)) ==
               {:error, :assertion_refused}

      row = opened!(session)

      assert Passkeys.assert(session, row.ref, Authenticator.assertion(auth, challenge(row))) ==
               {:error, :assertion_refused}

      assert {:ok, %{state: "pending"}} =
               Arca.PendingConfirmations.get(Context.actor(session), row.ref)

      # The person reads it as suspended.
      assert {:ok, listed} = Passkeys.list(session)
      assert Enum.find(listed, &(&1.id == passkey.id)).state == "suspended"
    end

    test "an emailed code re-enables a passkey, closing its person's restore alone; it proves again",
         %{
           session: session,
           user: user,
           auth: auth,
           passkey: passkey,
           other: other,
           restore_id: restore_id
         } do
      assert {:error, {:confirmation_required, %{id: id, operation: "passkey.reenable"}}} =
               Passkeys.reenable(session, passkey.id, :confirmation)

      code_confirmed!(session, id)
      passkey_id = passkey.id

      assert {:ok, %{passkey: %{id: ^passkey_id, state: "active"}, recovery_closed: true}} =
               Passkeys.reenable(%{session | confirmation_id: id}, passkey_id, :confirmation)

      assert restore_open(user.id) == nil
      assert restore_open(other.id) == restore_id

      row = opened!(session)

      assert {:ok, %{state: "confirmed"}} =
               Passkeys.assert(session, row.ref, Authenticator.assertion(auth, challenge(row)))

      held = Passkeys.sign_in_challenge()
      assert {:ok, _} = Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge))

      # Nothing is left to re-enable on it.
      assert {:error, %Prima.Refusal{reason: :not_suspended, class: :conflict}} =
               Passkeys.reenable(session, passkey_id, :confirmation)
    end

    test "a suspended passkey never approves its own return", %{
      session: session,
      user: user,
      auth: auth,
      passkey: passkey,
      restore_id: restore_id
    } do
      assert {:error, {:confirmation_required, %{id: id}}} =
               Passkeys.reenable(session, passkey.id, :confirmation)

      ref = Prima.Confirmation.ref(id)
      {:ok, row} = Arca.PendingConfirmations.get(Context.actor(session), ref)

      # Its own assertion over the record proves nothing, and no proof of
      # its can be recorded.
      assert Passkeys.assert(session, ref, Authenticator.assertion(auth, challenge(row))) ==
               {:error, :assertion_refused}

      assert {:error, :revoked} =
               Arca.PendingConfirmations.confirm(Context.actor(session), ref, %{
                 proof: "passkey",
                 passkey_id: passkey.id
               })

      # A record attributed to it is refused while the person's restore is
      # open, whatever let it be recorded.
      code_confirmed!(session, id)
      attributed!(session, id, passkey.id)

      assert Passkeys.reenable(%{session | confirmation_id: id}, passkey.id, :confirmation) ==
               {:error, Sanctum.Pairing.restore_source_refusal()}

      assert state(passkey.id) == "suspended"
      assert restore_open(user.id) == restore_id
    end

    test "a revoked passkey is never revived, by a confirmation or by the kit", %{
      session: session,
      user: user,
      passkey: passkey,
      restore_id: restore_id
    } do
      {:ok, _} = Arca.Passkeys.revoke(Prima.Actor.system(), passkey.id)

      assert {:error, %Prima.Refusal{reason: :revoked, class: :conflict}} =
               Passkeys.reenable(session, passkey.id, :confirmation)

      digest = kit_credential!(user.id, restore_id)

      assert {:error, %Prima.Refusal{reason: :revoked}} =
               Passkeys.reenable(
                 session,
                 passkey.id,
                 {:kit, %{user_id: user.id, credential_digest: digest}}
               )

      assert state(passkey.id) == "revoked"
      assert restore_open(user.id) == restore_id
    end

    test "the kit re-enables a passkey while its person's restore is open, and nothing after", %{
      user: user,
      passkey: passkey,
      second: second,
      other: other,
      restore_id: restore_id
    } do
      digest = kit_credential!(user.id, restore_id)
      kit = fn digest -> {:kit, %{user_id: user.id, credential_digest: digest}} end
      nobody = Context.build(%{authenticated: false})

      assert Passkeys.reenable(nobody, passkey.id, kit.("sha256:" <> String.duplicate("0", 64))) ==
               {:error, Sanctum.Pairing.kit_refusal()}

      # Another person's kit reaches none of theirs.
      other_digest = kit_credential!(other.id, restore_id)

      assert Passkeys.reenable(
               nobody,
               passkey.id,
               {:kit, %{user_id: other.id, credential_digest: other_digest}}
             ) == {:error, {:not_found, "passkey", passkey.id}}

      assert {:ok, %{passkey: %{state: "active"}, recovery_closed: true}} =
               Passkeys.reenable(nobody, passkey.id, kit.(digest))

      assert restore_open(user.id) == nil
      assert restore_open(other.id) == restore_id

      # The credential went with the person's restore.
      assert Passkeys.reenable(nobody, second.id, kit.(digest)) ==
               {:error, Sanctum.Pairing.kit_refusal()}

      assert state(second.id) == "suspended"
    end

    test "an unenrolled administrator with no door, every method suspended and no pending registration, has no way back in" do
      # A local person admitted by a door this home does not re-authenticate,
      # with no verified email: their passkey is their one fresh method.
      %{ctx: ctx, user: user} = person!()
      {:ok, _} = Sanctum.Tenancy.Members.ensure(user.id, scope: "platform")
      {auth, passkey} = registered!(ctx)

      # Their last door removed while they keep the passkey, and the
      # operator admitting them by their own id.
      Arca.Repo.delete_all(from(i in Arca.Schemas.ExternalIdentity, where: i.user_id == ^user.id))

      {:ok, _} = Sanctum.Door.Store.allow("user_id", user.id, "ops")
      held = Passkeys.sign_in_challenge()
      assert {:ok, _} = Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge))

      system = Prima.Actor.system()

      assert {:ok, %{enrollment: "none", identifier: nil}} =
               Arca.PersonIdentities.get(system, user.id)

      assert {:ok, %{scope: "platform"}} = Sanctum.Tenancy.Members.platform_seat(user.id)

      restore_id = restored!()

      # The passkey door is shut, and no other door, re-authentication or
      # code reaches them: they hold no session, and cannot sign in.
      held = Passkeys.sign_in_challenge()

      assert Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge)) ==
               {:error, :assertion_refused}

      assert {:ok, []} = Arca.Users.identities(system, user.id)
      refute Sanctum.Auth.OIDC.reauth_available?(user.id)
      refute Sanctum.Auth.EmailVerification.code_available?(user.id)
      assert sessions(user.id) == []

      refute Passkeys.fresh_method?(
               Context.build(user_id: user.id, athanor_id: ctx.athanor_id, authenticated: true)
             )

      # The administrator's recovery activates only a pending registration,
      # and they have none: the suspended passkey is not one, and making one
      # needs a session they cannot get.
      assert {:ok, []} = Arca.Passkeys.list(system, user.id, state: :pending)
      %{ctx: other_admin, user: other} = person!()
      {:ok, _} = Sanctum.Tenancy.Members.ensure(other.id, scope: "platform")

      assert Passkeys.recover_admin(%{other_admin | platform_admin: true}, %{
               user_id: user.id,
               passkey_id: passkey.id,
               registration_digest: passkey.registration_digest
             }) == {:error, {:not_found, "pending passkey", passkey.id}}

      # The kit ingress is for an enrolled person, and they are not: no kit
      # credential stands for them, so the kit re-enables nothing.
      assert Passkeys.reenable(
               Context.build(%{authenticated: false}),
               passkey.id,
               {:kit, %{user_id: user.id, credential_digest: Prima.Digest.sha256("no kit")}}
             ) == {:error, Sanctum.Pairing.kit_refusal()}

      assert state(passkey.id) == "suspended"
      assert restore_open(user.id) == restore_id
    end
  end

  # ---------------------------------------------------------------------------
  # The passkey door
  # ---------------------------------------------------------------------------

  describe "sign-in" do
    # A person with a verified email, which the door may admit them by: a
    # fresh method here, so their first passkey is confirmed by its code.
    setup do
      code_transport!()
      %{ctx: ctx} = fixture = person!(verified: true)
      {auth, passkey} = registered_by_code!(ctx)
      Map.merge(fixture, %{auth: auth, passkey: passkey})
    end

    test "an active passkey signs its person in, when a door of theirs still admits them",
         %{user: user, key: key, auth: auth} do
      {:ok, _} = Sanctum.Door.Store.allow("user_id", key, "ops")
      held = Passkeys.sign_in_challenge()

      assert held.public_key["userVerification"] == "required"
      assert held.public_key["rpId"] == Passkeys.rp_id()

      assert {:ok, %{session_token: token, outcome: {:proceed, _report}}} =
               Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge))

      assert {:ok, %{user_id: user_id, provider: "passkey"}} = Sanctum.Session.get(token)
      assert user_id == user.id
    end

    test "a local person's passkey stands on no head: the sign-in binds no key epoch, and the session records none",
         %{user: user, key: key, auth: auth} do
      {:ok, _} = Sanctum.Door.Store.allow("user_id", key, "ops")
      held = Passkeys.sign_in_challenge()

      assert {:ok, %{session_token: token}} =
               Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge))

      assert {:ok, %{user_id: user_id, provider: "passkey", identity_key_epoch: nil}} =
               Arca.SessionStorage.get_session(Sanctum.Session.token_hash(token))

      assert user_id == user.id
    end

    test "the verified email still admitted admits them too", %{user: user, auth: auth} do
      {:ok, _} = Sanctum.Door.Store.allow("email", user.email, "ops")
      held = Passkeys.sign_in_challenge()
      assert {:ok, _} = Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge))
    end

    test "a person the door no longer admits is refused, as a denied one is",
         %{user: user, key: key, auth: auth} do
      held = Passkeys.sign_in_challenge()

      assert Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge)) ==
               {:error, {:door, :not_allowed}}

      {:ok, _} = Sanctum.Door.Store.allow("user_id", key, "ops")
      {:ok, _} = Sanctum.Door.Store.deny("email", user.email, "ops")
      held = Passkeys.sign_in_challenge()

      assert Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge)) ==
               {:error, {:door, :denied}}
    end

    test "a person with no linked door is asked about by their own id, as a restore names them" do
      # No verified email, so before this rule nothing asked about them at
      # all once their last door was gone.
      %{ctx: ctx, user: user} = person!()
      {auth, _passkey} = registered!(ctx)
      assert {:ok, %{email_verified: false}} = Sanctum.Tenancy.Users.get(user.id)

      Arca.Repo.delete_all(
        Ecto.Query.from(i in Arca.Schemas.ExternalIdentity, where: i.user_id == ^user.id)
      )

      assert {:ok, []} = Arca.Users.identities(Prima.Actor.system(), user.id)

      held = Passkeys.sign_in_challenge()

      assert Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge)) ==
               {:error, {:door, :not_allowed}}

      {:ok, _} = Sanctum.Door.Store.allow("user_id", user.id, "restored")
      held = Passkeys.sign_in_challenge()
      assert {:ok, _} = Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge))

      # The operator's deny still wins.
      {:ok, _} = Sanctum.Door.Store.deny("user_id", user.id, "ops")
      held = Passkeys.sign_in_challenge()

      assert Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge)) ==
               {:error, {:door, :denied}}
    end

    test "another challenge, an expired one, or no user verification signs no one in",
         %{key: key, auth: auth} do
      {:ok, _} = Sanctum.Door.Store.allow("user_id", key, "ops")
      held = Passkeys.sign_in_challenge()

      assert Passkeys.sign_in(held, Authenticator.assertion(auth, :crypto.strong_rand_bytes(32))) ==
               {:error, :assertion_refused}

      assert Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge, uv: false)) ==
               {:error, :assertion_refused}

      expired = %{held | expires_at: System.os_time(:millisecond) - 1}

      assert Passkeys.sign_in(expired, Authenticator.assertion(auth, held.challenge)) ==
               {:error, :expired}
    end
  end
end
