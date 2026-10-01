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
  method has ever existed: never on a CYFR sign-in, never after the
  first method was used, whatever was revoked since. Every other
  registration is confirmed by a fresh method, or waits for the
  administrator. An assertion proves exactly one record's digest, at this
  home's origin and RP ID, with user verification, by the record's own
  person, once.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{Passkey, PendingConfirmation, PersonIdentity}
  alias Sanctum.Consent.Authz
  alias Sanctum.{Context, Passkeys, TestContext}
  alias Sanctum.TestContext.Authenticator
  alias Sanctum.Tenancy.Athanors

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Prima.RateLimiter.reset()
    on_exit(fn -> Prima.RateLimiter.reset() end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A person admitted through a local door, with their own athanor and a
  # group, and the context a new session of theirs establishes there. Their
  # email is unverified unless `verified: true`: a verified one is a fresh
  # method wherever a code transport is configured.
  defp person!(opts \\ []) do
    n = System.unique_integer([:positive])
    key = "github|https://github.com|passkeys-#{n}"

    {:ok, user} =
      Sanctum.SignIn.admitted(
        %{
          id: key,
          provider: "github",
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

  # Run `fun` under `ctx`; when it asks for a confirmation, prove it with
  # `auth` and run it again naming the record.
  defp confirming(ctx, auth, fun) do
    assert {:error, {:confirmation_required, %{id: id}}} = fun.(ctx)
    TestContext.prove!(ctx, id, auth)
    fun.(%{ctx | confirmation_id: id})
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

    test "a local door's recent sign-in registers the first passkey, marks it for good and announces it" do
      %{ctx: ctx, user: user} = person!()
      capture([[:cyfr, :sanctum, :notify]])
      assert first_method_at(user.id) == nil

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

    test "a remote person is refused before any ceremony, and nothing reads a directory" do
      %{ctx: ctx, user: user} = person!()
      Arca.Repo.delete_all(from(p in PersonIdentity, where: p.user_id == ^user.id))

      {:ok, _remote} =
        Arca.PersonIdentities.create(Prima.Actor.system(), %{
          user_id: user.id,
          provenance: "remote",
          identifier: "per_" <> String.duplicate("a", 64),
          directory_url: "https://dir.example"
        })

      assert Passkeys.register(ctx, %{}) == {:error, :remote_identity_unavailable}

      assert Authz.check(ctx, :credential_entry, change()) ==
               {:error, :remote_identity_unavailable}

      assert Arca.Repo.all(Arca.Schemas.DirectoryHead) == []
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
  # The passkey door
  # ---------------------------------------------------------------------------

  describe "sign-in" do
    setup do
      %{ctx: ctx} = fixture = person!(verified: true)
      {auth, passkey} = registered!(ctx)
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
