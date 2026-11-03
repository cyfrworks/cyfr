# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceUnlockTest do
  @moduledoc """
  A protected device (`Sanctum.DeviceUnlock`), through its public entries.

  Setup enrolls the installation's first person with the device's key,
  certificate, first-method mark and recovery in one admission, mints no
  session, and closes setup for every later enrollment, a challenge drawn
  before it committed among them. A lost answer is resumed only by the
  committed key's proof under the setup token. A restored person's first
  device enrolls from the restore's own session inside its window, once.

  An unlock answers a 32-byte ticket that a browser redeems once, for a
  session of the device's person that names the device, expires within 60
  seconds and the certificate whatever `session_ttl_hours` says, which a
  browser's refresh never moves and the device's channel slides without
  reviving. A lock proof needs no freshness, retires exactly its session,
  repeats as a success, never ends a successor, and spent before the
  ticket leaves the ticket redeeming nothing. A revocation or a revoked
  certificate before the redemption refuses it, and after it ends the
  session. A browser's session, a browser key and another device's proof
  unlock nothing.

  A device confirms a pending change of its own person with a proof over
  the record's ref and stored digest, recorded as the device's; the opener
  alone consumes it. A modified digest, another person's record, a
  cancelled one and a device revoked since its proof confirm or consume
  nothing.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Sanctum.Test.Newcomers, only: [identity: 0, identity: 1]

  alias Arca.Schemas.{Membership, PairedClient, PersonIdentity, Session, User}
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Sanctum.{Context, DeviceCerts, DeviceUnlock, Newcomer}

  @token String.duplicate("6d", 32)
  @source "198.51.100.30"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()

    on_exit(fn ->
      Prima.Test.RateLimiter.reset!()
    end)

    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Sanctum.Test.Newcomers.directory!()
    # The installation holds no person inside this test's transaction.
    Arca.Repo.delete_all(User)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp key, do: :crypto.generate_key(:eddsa, :ed25519)
  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
  defp signed(challenge, private), do: Proof.encode(Proof.sign(challenge, private))

  defp reported({public, _private}, request_id, admission \\ "setup") do
    %{
      "admission" => admission,
      "device_key" => b64(public),
      "request_id" => request_id,
      "holder_kind" => "chip",
      "display_name" => "Kitchen box"
    }
  end

  defp challenge!(key, identity) do
    {:ok, %{challenge: challenge}} =
      DeviceUnlock.enrollment_challenge({:setup, @token}, reported(key, identity.request_id))

    challenge
  end

  defp complete(challenge, {_public, private}, identity) do
    DeviceUnlock.enroll({:setup, @token}, %{
      "proof" => signed(challenge, private),
      "name" => identity.name,
      "recovery_secret" => b64(identity.recovery_secret)
    })
  end

  # The box's setup: its key enrolled as the first person's device.
  defp enrolled!(key \\ key()) do
    identity = identity()
    {:ok, answer} = complete(challenge!(key, identity), key, identity)
    Map.merge(answer, %{key: key, identity: identity})
  end

  # The device's channel context, as it is minted from a connect proof.
  defp connected!(%{certificate: certificate, key: {_public, private}}) do
    {:ok, challenge} =
      Challenge.new(
        purpose: :connect,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: certificate.client_id,
        device_key: certificate.device_key,
        nonce: :crypto.strong_rand_bytes(32),
        now: System.system_time(:millisecond)
      )

    {:ok, ctx} =
      DeviceCerts.verify_connect(
        %{client_id: certificate.client_id, certificate: certificate, source: @source},
        Proof.sign(challenge, private),
        challenge
      )

    ctx
  end

  defp unlocked!(ctx, {_public, private}) do
    {:ok, %{challenge: challenge}} = DeviceUnlock.unlock(ctx, %{})
    {:ok, answer} = DeviceUnlock.unlock(ctx, %{"proof" => signed(challenge, private)})
    answer
  end

  defp lock_proof(device, session_id, key \\ nil) do
    {_public, private} = key || device.key
    certificate = device.certificate

    {:ok, challenge} =
      Challenge.new(
        purpose: :lock,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: certificate.client_id,
        device_key: certificate.device_key,
        session_id: session_id
      )

    signed(challenge, private)
  end

  defp session_row(session_id), do: Arca.Repo.get(Session, session_id)
  defp client_row(client_id), do: Arca.Repo.get!(PairedClient, client_id)

  # The client's current certificate revoked through its store, the one
  # revocation statement every transition runs.
  defp revoke_certificate!(athanor_id, client_id) do
    actor = Prima.Actor.in_athanor(athanor_id)
    {:ok, current} = Arca.DeviceCertificates.current(actor, client_id)
    {:ok, _revoked} = Arca.DeviceCertificates.revoke(actor, current.id)
  end

  defp revoke_client!(device) do
    actor = Prima.Actor.in_athanor(device.certificate.athanor)
    {:ok, _row} = Arca.PairedClients.revoke(actor, device.certificate.client_id)
  end

  # ---------------------------------------------------------------------------
  # Enrollment at setup
  # ---------------------------------------------------------------------------

  describe "setup" do
    test "enrolls the first person with their device, certificate, first-method mark and recovery, and mints no session" do
      device = enrolled!()
      certificate = device.certificate

      assert [%User{id: user_id, admission: "setup"}] = Arca.Repo.all(User)
      assert certificate.subject == %{kind: :local, user_id: user_id}
      assert certificate.audience == Sanctum.Person.home()
      assert {:ok, %{id: athanor_id}} = Arca.Athanors.get_by_owner(Prima.Actor.system(), user_id)
      assert certificate.athanor == athanor_id

      client = client_row(certificate.client_id)
      assert client.user_id == user_id
      assert client.holder_kind == "chip"
      assert client.display_name == "Kitchen box"
      assert client.source_id == device.identity.request_id
      assert client.device_public_key == elem(device.key, 0)

      assert %{first_method_at: %DateTime{}} = Arca.Repo.get_by!(PersonIdentity, user_id: user_id)

      assert Arca.Repo.exists?(
               from(m in Membership, where: m.user_id == ^user_id and m.scope == "platform")
             )

      assert %{code: code, name: name} = device.recovery
      assert is_binary(code) and name == device.identity.name
      assert Arca.Repo.all(from(s in Session, where: s.user_id == ^user_id)) == []
    end

    test "closes setup: an enrollment challenged before the first committed is refused, and a new challenge too" do
      first = key()
      second = key()
      first_identity = identity()
      second_identity = identity()
      first_challenge = challenge!(first, first_identity)
      second_challenge = challenge!(second, second_identity)

      assert {:ok, _answer} = complete(first_challenge, first, first_identity)

      assert {:error, :setup_closed} = complete(second_challenge, second, second_identity)
      assert Arca.Repo.aggregate(User, :count) == 1
      assert Arca.Repo.aggregate(PairedClient, :count) == 1

      assert {:error, :setup_closed} =
               DeviceUnlock.enrollment_challenge(
                 {:setup, @token},
                 reported(key(), identity().request_id)
               )

      assert {:error, :setup_closed} = Newcomer.setup_open(@token)
    end

    test "takes only the configured token, the device's own report and a proof by the reported key" do
      assert {:error, :setup_closed} =
               DeviceUnlock.enrollment_challenge(
                 {:setup, String.duplicate("00", 32)},
                 reported(key(), "req_a")
               )

      for {field, value} <- [
            {"holder_kind", "platform"},
            {"display_name", ""},
            {"device_key", b64(:crypto.strong_rand_bytes(31))},
            {"request_id", "not an id"},
            {"admission", "restore"}
          ] do
        assert {:error, :invalid_request} =
                 DeviceUnlock.enrollment_challenge(
                   {:setup, @token},
                   Map.put(reported(key(), "req_b"), field, value)
                 ),
               field
      end

      identity = identity()
      device = key()
      challenge = challenge!(device, identity)
      assert {:error, :proof_refused} = complete(challenge, key(), identity)
      # The challenge was taken by that refusal: the right key now finds none.
      assert {:error, :proof_refused} = complete(challenge, device, identity)
      assert Arca.Repo.aggregate(User, :count) == 0
    end

    test "a proof answers its held challenge once" do
      device = key()
      identity = identity()
      challenge = challenge!(device, identity)
      assert {:ok, _answer} = complete(challenge, device, identity)
      assert {:error, :proof_refused} = complete(challenge, device, identity)
      assert Arca.Repo.aggregate(PairedClient, :count) == 1
    end
  end

  describe "a lost answer" do
    test "is resumed by the committed key's proof under the setup token, and by nothing less" do
      device = enrolled!()
      {public, private} = device.key
      request_id = device.identity.request_id

      ask = %{"admission" => "setup", "device_key" => b64(public), "request_id" => request_id}

      assert {:error, :invalid_token} = DeviceUnlock.resume({:setup, "wrong"}, ask)

      {other, _other_private} = key()

      assert {:error, :not_found} =
               DeviceUnlock.resume({:setup, @token}, %{ask | "device_key" => b64(other)})

      assert {:error, :not_found} =
               DeviceUnlock.resume({:setup, @token}, %{ask | "request_id" => "req_unknown"})

      assert {:ok, %{challenge: challenge}} = DeviceUnlock.resume({:setup, @token}, ask)
      assert challenge.purpose == :enroll
      assert challenge.client_id == device.certificate.client_id
      assert challenge.request_id == request_id

      {_wrong, wrong_private} = key()

      assert {:error, :proof_refused} =
               DeviceUnlock.resume({:setup, @token}, %{
                 "proof" => signed(challenge, wrong_private)
               })

      {:ok, %{challenge: challenge}} = DeviceUnlock.resume({:setup, @token}, ask)

      assert {:ok, %{certificate: certificate, recovery: recovery}} =
               DeviceUnlock.resume({:setup, @token}, %{"proof" => signed(challenge, private)})

      assert certificate == device.certificate
      assert recovery == device.recovery
      assert Arca.Repo.aggregate(User, :count) == 1
      assert Arca.Repo.aggregate(PairedClient, :count) == 1
    end
  end

  describe "a new person by invitation or the open admission" do
    setup do
      admin = enrolled!()
      %{admin: admin, admin_id: admin.certificate.subject.user_id}
    end

    defp invite!(admin_id) do
      ctx = Sanctum.TestContext.session!(admin_id)
      {:ok, %{invitation: invitation, code: code}} = Sanctum.Invitations.create(ctx, nil)
      {invitation.id, code}
    end

    defp new_challenge(admission, key, identity) do
      DeviceUnlock.enrollment_challenge(
        admission,
        reported(key, identity.request_id, admission_name(admission))
      )
    end

    defp admission_name({kind, _credential}), do: Atom.to_string(kind)

    defp new_complete(admission, challenge, {_public, private}, identity) do
      DeviceUnlock.enroll(admission, %{
        "proof" => signed(challenge, private),
        "name" => identity.name,
        "recovery_secret" => b64(identity.recovery_secret)
      })
    end

    defp open! do
      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "ops")
      :ok
    end

    test "an invitation enrolls a new person with the device, certificate, first-method mark and recovery, redeemed by them, and mints no session",
         %{admin_id: admin_id} do
      {id, code} = invite!(admin_id)
      device = key()
      identity = identity("invited")
      {:ok, %{challenge: challenge}} = new_challenge({:invitation, code}, device, identity)
      assert challenge.admission == :invitation

      assert {:ok, %{certificate: certificate, recovery: %{name: "invited", code: "CYFR-" <> _}}} =
               new_complete({:invitation, code}, challenge, device, identity)

      %{user_id: user_id} = certificate.subject
      assert %User{admission: "invitation"} = Arca.Repo.get!(User, user_id)
      assert {:ok, %{id: athanor_id}} = Arca.Athanors.get_by_owner(Prima.Actor.system(), user_id)
      assert certificate.athanor == athanor_id

      client = client_row(certificate.client_id)
      assert {client.user_id, client.holder_kind, client.standing} == {user_id, "chip", "active"}
      assert %{first_method_at: %DateTime{}} = Arca.Repo.get_by!(PersonIdentity, user_id: user_id)
      assert %{redeemed_by: ^user_id} = Arca.Repo.get!(Arca.Schemas.Invitation, id)
      refute Sanctum.Tenancy.platform_admin?(user_id)
      assert Arca.Repo.all(from(s in Session, where: s.user_id == ^user_id)) == []

      # The code is spent: it challenges no other device.
      assert {:error, :invitation_invalid} = new_challenge({:invitation, code}, key(), identity())
    end

    test "an invitation's challenge completes under its own code alone, and a code spent or revoked meanwhile makes no one",
         %{admin_id: admin_id} do
      {_id, code} = invite!(admin_id)
      {other_id, other} = invite!(admin_id)
      people = Arca.Repo.aggregate(User, :count)

      first = key()
      second = key()
      third = key()
      first_identity = identity()
      second_identity = identity()
      third_identity = identity()
      {:ok, %{challenge: a}} = new_challenge({:invitation, code}, first, first_identity)
      {:ok, %{challenge: b}} = new_challenge({:invitation, code}, second, second_identity)
      {:ok, %{challenge: c}} = new_challenge({:invitation, other}, third, third_identity)

      # Another valid code does not complete this code's challenge.
      assert {:error, :proof_refused} =
               new_complete({:invitation, other}, a, first, first_identity)

      {:ok, %{challenge: a}} = new_challenge({:invitation, code}, first, first_identity)

      # Two devices challenged under one code: the first to commit spends it.
      assert {:ok, _answer} = new_complete({:invitation, code}, a, first, first_identity)

      assert {:error, :invitation_invalid} =
               new_complete({:invitation, code}, b, second, second_identity)

      # A code revoked between its challenge and its completion admits no one.
      {:ok, _revoked} = Arca.Invitations.revoke(Prima.Actor.system(), other_id)

      assert {:error, :invitation_invalid} =
               new_complete({:invitation, other}, c, third, third_identity)

      assert Arca.Repo.aggregate(User, :count) == people + 1
      assert Arca.Repo.aggregate(PairedClient, :count) == 2

      assert {:error, :invitation_invalid} =
               new_challenge({:invitation, "nonsense"}, key(), identity())
    end

    test "concurrent completions under one invitation make one person and one device", %{
      admin_id: admin_id
    } do
      {_id, code} = invite!(admin_id)
      people = Arca.Repo.aggregate(User, :count)
      clients = Arca.Repo.aggregate(PairedClient, :count)

      completions =
        for _ <- 1..3 do
          device = key()
          identity = identity()
          {:ok, %{challenge: challenge}} = new_challenge({:invitation, code}, device, identity)
          {challenge, device, identity}
        end

      results =
        completions
        |> Enum.map(fn {challenge, device, identity} ->
          Task.async(fn -> new_complete({:invitation, code}, challenge, device, identity) end)
        end)
        |> Task.await_many(30_000)

      assert [{:ok, %{certificate: _certificate}}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert Enum.count(results, &(&1 == {:error, :invitation_invalid})) == 2
      assert Arca.Repo.aggregate(User, :count) == people + 1
      assert Arca.Repo.aggregate(PairedClient, :count) == clients + 1
    end

    test "the open admission needs the door's *, and enrolls a new person like an invitation" do
      device = key()
      identity = identity("opened")

      assert {:error, {:door, :not_allowed}} = new_challenge({:open, @source}, device, identity)

      open!()
      {:ok, %{challenge: challenge}} = new_challenge({:open, @source}, device, identity)
      assert challenge.admission == :open

      # An open challenge is completed under no other admission.
      assert {:error, :proof_refused} =
               DeviceUnlock.enroll({:setup, @token}, %{
                 "proof" => signed(challenge, elem(device, 1)),
                 "name" => identity.name,
                 "recovery_secret" => b64(identity.recovery_secret)
               })

      {:ok, %{challenge: challenge}} = new_challenge({:open, @source}, device, identity)

      assert {:ok, %{certificate: certificate, recovery: %{name: "opened"}}} =
               new_complete({:open, @source}, challenge, device, identity)

      assert %User{admission: "open"} = Arca.Repo.get!(User, certificate.subject.user_id)
    end

    test "the open admission at a cap writes no person, athanor or device" do
      open!()
      Sanctum.Test.Settings.put("max_athanors", 1)
      device = key()
      identity = identity()
      {:ok, %{challenge: challenge}} = new_challenge({:open, @source}, device, identity)
      before = {Arca.Repo.aggregate(User, :count), Arca.Repo.aggregate(PairedClient, :count)}

      assert {:error, {:limit_reached, :max_athanors, 1}} =
               new_complete({:open, @source}, challenge, device, identity)

      assert {Arca.Repo.aggregate(User, :count), Arca.Repo.aggregate(PairedClient, :count)} ==
               before
    end

    test "the open admission's challenges are counted against their address, and another address keeps its own" do
      open!()

      for _ <- 1..20 do
        assert {:ok, _challenge} = new_challenge({:open, @source}, key(), identity())
      end

      assert {:error, {:rate_limited, seconds}} =
               new_challenge({:open, @source}, key(), identity())

      assert seconds >= 1
      assert {:ok, _challenge} = new_challenge({:open, "203.0.113.9"}, key(), identity())
    end

    test "a lost answer resumes under the redeemed code or, opened, by the committed key's proof alone",
         %{admin_id: admin_id} do
      {_id, code} = invite!(admin_id)
      {_other_id, other} = invite!(admin_id)
      {public, private} = device = key()
      identity = identity()
      {:ok, %{challenge: challenge}} = new_challenge({:invitation, code}, device, identity)
      {:ok, answer} = new_complete({:invitation, code}, challenge, device, identity)

      ask = %{
        "admission" => "invitation",
        "device_key" => b64(public),
        "request_id" => identity.request_id
      }

      assert {:error, :invalid_token} = DeviceUnlock.resume({:invitation, "nonsense"}, ask)
      assert {:error, :not_found} = DeviceUnlock.resume({:invitation, other}, ask)
      assert {:error, :invalid_request} = DeviceUnlock.resume({:open, @source}, ask)
      {:ok, %{challenge: resume}} = DeviceUnlock.resume({:invitation, code}, ask)

      assert {:ok, %{certificate: certificate, recovery: recovery}} =
               DeviceUnlock.resume({:invitation, code}, %{"proof" => signed(resume, private)})

      assert {certificate, recovery} == {answer.certificate, answer.recovery}

      open!()
      {opened_public, opened_private} = opened = key()
      opened_identity = identity()
      {:ok, %{challenge: challenge}} = new_challenge({:open, @source}, opened, opened_identity)
      {:ok, answer} = new_complete({:open, @source}, challenge, opened, opened_identity)

      ask = %{
        "admission" => "open",
        "device_key" => b64(opened_public),
        "request_id" => opened_identity.request_id
      }

      {:ok, %{challenge: resume}} = DeviceUnlock.resume({:open, @source}, ask)
      {_wrong, wrong_private} = key()

      assert {:error, :proof_refused} =
               DeviceUnlock.resume({:open, @source}, %{"proof" => signed(resume, wrong_private)})

      {:ok, %{challenge: resume}} = DeviceUnlock.resume({:open, @source}, ask)

      assert {:ok, %{certificate: certificate}} =
               DeviceUnlock.resume({:open, @source}, %{"proof" => signed(resume, opened_private)})

      assert certificate == answer.certificate
    end
  end

  describe "review S2 admission binding" do
    test "an invitation enrollment cannot resume as an open enrollment" do
      admin = enrolled!()
      admin_id = admin.certificate.subject.user_id
      {_id, code} = invite!(admin_id)
      {public, private} = device = key()
      person = identity()
      {:ok, %{challenge: challenge}} = new_challenge({:invitation, code}, device, person)
      {:ok, _answer} = new_complete({:invitation, code}, challenge, device, person)

      result =
        with {:ok, %{challenge: resumed}} <-
               DeviceUnlock.resume({:open, @source}, %{
                 "admission" => "open",
                 "device_key" => b64(public),
                 "request_id" => person.request_id
               }) do
          DeviceUnlock.resume({:open, @source}, %{"proof" => signed(resumed, private)})
        end

      assert match?({:error, _}, result),
             "invitation-free open resume returned the invitation enrollment"
    end

    test "the installation's tokens resume only the people they admitted: setup's its own person, a restore's one a restore brought back" do
      admin = enrolled!()
      {admin_public, _admin_private} = admin.key

      ask = fn admission, public, request_id ->
        %{"admission" => admission, "device_key" => b64(public), "request_id" => request_id}
      end

      # No restore brought the person setup made back: the restore token
      # finds no enrollment of theirs.
      Prima.Test.Env.put_app_env(:sanctum, :restore_token, String.duplicate("7e", 32))

      assert {:error, :not_found} =
               DeviceUnlock.resume(
                 {:restore, String.duplicate("7e", 32)},
                 ask.("restore", admin_public, admin.identity.request_id)
               )

      # Setup's token does not resume an invited person's enrollment.
      {_id, code} = invite!(admin.certificate.subject.user_id)
      {public, _private} = device = key()
      person = identity()
      {:ok, %{challenge: challenge}} = new_challenge({:invitation, code}, device, person)
      {:ok, _answer} = new_complete({:invitation, code}, challenge, device, person)

      assert {:error, :not_found} =
               DeviceUnlock.resume({:setup, @token}, ask.("setup", public, person.request_id))
    end

    test "an invitation resume proof cannot finish under another invitation code" do
      admin = enrolled!()
      admin_id = admin.certificate.subject.user_id
      {_id, code} = invite!(admin_id)
      {_other_id, other} = invite!(admin_id)
      {public, private} = device = key()
      person = identity()
      {:ok, %{challenge: challenge}} = new_challenge({:invitation, code}, device, person)
      {:ok, _answer} = new_complete({:invitation, code}, challenge, device, person)

      {:ok, %{challenge: resumed}} =
        DeviceUnlock.resume({:invitation, code}, %{
          "admission" => "invitation",
          "device_key" => b64(public),
          "request_id" => person.request_id
        })

      result = DeviceUnlock.resume({:invitation, other}, %{"proof" => signed(resumed, private)})

      assert match?({:error, _}, result),
             "another invitation's header finished the first invitation's resume"
    end
  end

  describe "after a restore" do
    # A local person who holds no first method, as a restore leaves them:
    # made here by a device's setup, the device, its certificate and the
    # first-method mark then taken away.
    setup do
      %{certificate: %{subject: %{user_id: user_id}}} = enrolled!()

      Arca.Repo.delete_all(
        from(c in Arca.Schemas.DeviceCertificate, where: c.user_id == ^user_id)
      )

      Arca.Repo.delete_all(from(c in PairedClient, where: c.user_id == ^user_id))

      {1, _} =
        Arca.Repo.update_all(from(p in PersonIdentity, where: p.user_id == ^user_id),
          set: [first_method_at: nil]
        )

      %{user_id: user_id}
    end

    # The restore's own session, as `Sanctum.Recovery` issues it for the
    # attempt that minted this very person.
    defp restore_session!(user_id) do
      id = Prima.UUID7.generate_id("iat")
      now = DateTime.utc_now()

      {1, _} =
        Arca.Repo.insert_all(Arca.Schemas.IdentityAttempt, [
          %{
            id: id,
            kind: "restore",
            request_id: Prima.UUID7.generate_id("rst"),
            user_id: user_id,
            identifier: "per_" <> String.duplicate("d", 64),
            directory_url: "https://dir.example",
            phase: "completed",
            entry: "recover-request",
            request_digest: Prima.Digest.sha256("recover-#{id}"),
            expected_revision: 0,
            token_digest: Prima.Digest.sha256("token-#{id}"),
            staged_live_public_key: :crypto.strong_rand_bytes(32),
            staged_operational_public_key: :crypto.strong_rand_bytes(32),
            revision: 1,
            inserted_at: now,
            updated_at: now
          }
        ])

      {:ok, %{id: athanor_id}} = Arca.Athanors.get_by_owner(Prima.Actor.system(), user_id)

      built =
        Context.build(
          user_id: user_id,
          provider: "restore",
          athanor_id: athanor_id,
          permissions: Context.person_permissions(),
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, session} =
        Sanctum.Session.create(built,
          generation_snapshot: Sanctum.TestContext.snapshot!(built),
          restore: id
        )

      {:ok, ctx} = Sanctum.Caller.establish(session.token)
      ctx
    end

    defp restore_enroll(ctx, {_public, private} = key, request_id) do
      with {:ok, %{challenge: challenge}} <-
             DeviceUnlock.enrollment_challenge(
               {:restore, ctx},
               reported(key, request_id, "restore")
             ) do
        DeviceUnlock.enroll({:restore, ctx}, %{"proof" => signed(challenge, private)})
      end
    end

    defp aged!(ctx, seconds) do
      at = DateTime.add(DateTime.utc_now(), -seconds, :second)

      from(s in Session, where: s.token_hash == ^ctx.session_token_hash)
      |> Arca.Repo.update_all(set: [inserted_at: at])
    end

    test "the restore's session enrolls the person's first device, once", %{user_id: user_id} do
      ctx = restore_session!(user_id)
      device = key()

      assert {:ok, %{certificate: certificate}} = restore_enroll(ctx, device, "req_restore_a")
      assert certificate.subject == %{kind: :local, user_id: user_id}
      assert %{first_method_at: %DateTime{}} = Arca.Repo.get_by!(PersonIdentity, user_id: user_id)
      assert %{holder_kind: "chip"} = client_row(certificate.client_id)

      assert {:error, :first_method_used} = restore_enroll(ctx, key(), "req_restore_b")

      assert Arca.Repo.aggregate(from(p in PairedClient, where: p.user_id == ^user_id), :count) ==
               1
    end

    test "past its window it enrolls nothing, and the reproof's new session opens it again", %{
      user_id: user_id
    } do
      ctx = restore_session!(user_id)
      aged!(ctx, 3600)
      assert {:error, :not_restored} = restore_enroll(ctx, key(), "req_restore_c")

      assert {:ok, %{certificate: _}} =
               restore_enroll(restore_session!(user_id), key(), "req_restore_d")
    end

    test "a challenge drawn in the window expires with it, and no other session or admission enrolls",
         %{user_id: user_id} do
      ctx = restore_session!(user_id)
      device = key()

      {:ok, %{challenge: challenge}} =
        DeviceUnlock.enrollment_challenge(
          {:restore, ctx},
          reported(device, "req_restore_e", "restore")
        )

      aged!(ctx, 3600)

      assert {:error, :not_restored} =
               DeviceUnlock.enroll({:restore, ctx}, %{
                 "proof" => signed(challenge, elem(device, 1))
               })

      fresh = restore_session!(user_id)

      assert {:error, :invalid_request} =
               DeviceUnlock.enrollment_challenge(
                 {:restore, fresh},
                 reported(key(), "req_restore_f")
               )

      browser = %{fresh | provider: "github"}

      assert {:error, :not_restored} =
               DeviceUnlock.enrollment_challenge(
                 {:restore, browser},
                 reported(key(), "req_restore_g", "restore")
               )

      refute Arca.Repo.exists?(from(p in PairedClient, where: p.user_id == ^user_id))
    end
  end

  # ---------------------------------------------------------------------------
  # Unlock, the ticket and the session
  # ---------------------------------------------------------------------------

  describe "unlock" do
    setup do
      device = enrolled!()
      %{device: device, ctx: connected!(device)}
    end

    test "answers a ticket a browser redeems once for a session bound to the device", %{
      device: device,
      ctx: ctx
    } do
      answer = unlocked!(ctx, device.key)
      assert byte_size(Base.url_decode64!(answer.ticket, padding: false)) == 32
      assert "ses_" <> _ = answer.session_id
      # The unlock reserves the session as a row no token loads; the
      # ticket's redemption activates it.
      assert %Session{provider: "unlock_reserved", token_prefix: nil} =
               session_row(answer.session_id)

      assert {:ok, %{token: token, expires_at: expires_at}} = DeviceUnlock.redeem(answer.ticket)
      assert {:error, :invalid_ticket} = DeviceUnlock.redeem(answer.ticket)

      row = session_row(answer.session_id)
      assert row.client_id == device.certificate.client_id
      assert row.provider == "unlock"
      assert row.user_id == ctx.user_id
      assert DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), 61, :second)) == :lt

      assert {:ok, %Context{} = session_ctx} = Sanctum.Session.load(token)
      assert session_ctx.auth_method == :oidc
      assert session_ctx.client_id == nil
      assert session_ctx.credential_deadline == row.expires_at
    end

    test "a ticket that is not one, or another's, redeems nothing", %{device: device, ctx: ctx} do
      _answer = unlocked!(ctx, device.key)

      for ticket <- [nil, "", "short", b64(:crypto.strong_rand_bytes(32))] do
        assert {:error, :invalid_ticket} = DeviceUnlock.redeem(ticket), inspect(ticket)
      end
    end

    test "a proof answers its unlock challenge once, and a proof of another key or purpose none",
         %{device: device, ctx: ctx} do
      {_public, private} = device.key
      {:ok, %{challenge: challenge}} = DeviceUnlock.unlock(ctx, %{})
      {_other, other_private} = key()

      assert {:error, :proof_refused} =
               DeviceUnlock.unlock(ctx, %{"proof" => signed(challenge, other_private)})

      # Taken by that refusal.
      assert {:error, :proof_refused} =
               DeviceUnlock.unlock(ctx, %{"proof" => signed(challenge, private)})

      {:ok, %{challenge: challenge}} = DeviceUnlock.unlock(ctx, %{})
      lock = lock_proof(device, challenge.session_id)
      assert {:error, :proof_refused} = DeviceUnlock.unlock(ctx, %{"proof" => lock})
      assert {:error, :invalid_request} = DeviceUnlock.unlock(ctx, %{"proof" => lock, "x" => 1})
    end

    test "session_ttl_hours zero lifts no bound off a device's session", %{
      device: device,
      ctx: ctx
    } do
      :ok = Sanctum.Test.Settings.put("session_ttl_hours", 0)
      answer = unlocked!(ctx, device.key)
      {:ok, %{expires_at: expires_at}} = DeviceUnlock.redeem(answer.ticket)
      assert DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), 61, :second)) == :lt

      assert DateTime.compare(session_row(answer.session_id).expires_at, ~U[9999-01-01 00:00:00Z]) ==
               :lt
    end

    test "a browser's refresh never moves a device's session; its channel slides it, never past the certificate and never reviving",
         %{device: device, ctx: ctx} do
      answer = unlocked!(ctx, device.key)
      {:ok, %{token: token}} = DeviceUnlock.redeem(answer.ticket)
      before = session_row(answer.session_id).expires_at

      assert {:error, :invalid_session} = Sanctum.Session.refresh(token)
      assert :ok = Sanctum.Session.refresh_if_stale(token)
      assert {:ok, _ctx} = Sanctum.Caller.establish(token)
      assert session_row(answer.session_id).expires_at == before

      Process.sleep(5)
      assert {:ok, [_slid]} = DeviceUnlock.slide(ctx, [answer.session_id])
      slid = session_row(answer.session_id).expires_at
      assert DateTime.compare(slid, before) == :gt
      assert DateTime.compare(slid, ctx.credential_deadline) != :gt

      # Past its expiry, nothing revives it.
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      from(s in Session, where: s.id == ^answer.session_id)
      |> Arca.Repo.update_all(set: [expires_at: past])

      assert {:ok, []} = DeviceUnlock.slide(ctx, [answer.session_id])
      assert session_row(answer.session_id).expires_at == past
      assert {:error, :invalid_session} = Sanctum.Session.load(token)
    end

    test "a browser's session, a context of no device, and a browser key with no holder unlock nothing",
         %{device: device, ctx: ctx} do
      answer = unlocked!(ctx, device.key)
      {:ok, %{token: token}} = DeviceUnlock.redeem(answer.ticket)
      {:ok, browser} = Sanctum.Session.load(token)

      assert {:error, :not_a_device} = DeviceUnlock.unlock(browser, %{})

      assert {:error, :not_a_device} =
               DeviceUnlock.lock(browser, %{"proof" => lock_proof(device, answer.session_id)})

      assert {:error, :not_a_device} =
               DeviceUnlock.unlock(Context.build(authenticated: false), %{})

      from(p in PairedClient, where: p.id == ^device.certificate.client_id)
      |> Arca.Repo.update_all(set: [holder_kind: nil])

      assert {:error, :no_holder} = DeviceUnlock.unlock(ctx, %{})
    end
  end

  describe "lock" do
    setup do
      device = enrolled!()
      ctx = connected!(device)
      answer = unlocked!(ctx, device.key)
      {:ok, %{token: token}} = DeviceUnlock.redeem(answer.ticket)
      %{device: device, ctx: ctx, session_id: answer.session_id, token: token}
    end

    test "retires exactly its session without freshness, repeats as a success and never ends a successor",
         %{device: device, ctx: ctx, session_id: session_id, token: token} do
      proof = lock_proof(device, session_id)
      successor = unlocked!(ctx, device.key)
      {:ok, %{token: successor_token}} = DeviceUnlock.redeem(successor.ticket)

      assert {:ok, %{locked: true}} = DeviceUnlock.lock(ctx, %{"proof" => proof})
      assert session_row(session_id) == nil
      assert {:error, :invalid_session} = Sanctum.Session.load(token)

      assert {:ok, %{locked: true}} = DeviceUnlock.lock(ctx, %{"proof" => proof})
      assert %Session{} = session_row(successor.session_id)
      assert {:ok, _ctx} = Sanctum.Session.load(successor_token)
    end

    test "a proof of another key, another session's or another purpose's locks nothing",
         %{device: device, ctx: ctx, session_id: session_id, token: token} do
      assert {:error, :proof_refused} =
               DeviceUnlock.lock(ctx, %{"proof" => lock_proof(device, session_id, key())})

      {:ok, %{challenge: unlock}} = DeviceUnlock.unlock(ctx, %{})

      assert {:error, :proof_refused} =
               DeviceUnlock.lock(ctx, %{"proof" => signed(unlock, elem(device.key, 1))})

      assert {:ok, _ctx} = Sanctum.Session.load(token)
      assert %Session{} = session_row(session_id)
    end

    test "before the ticket's redemption leaves the ticket redeeming nothing", %{
      device: device,
      ctx: ctx
    } do
      answer = unlocked!(ctx, device.key)

      assert {:ok, %{locked: true}} =
               DeviceUnlock.lock(ctx, %{"proof" => lock_proof(device, answer.session_id)})

      assert {:error, :invalid_ticket} = DeviceUnlock.redeem(answer.ticket)
      assert session_row(answer.session_id) == nil
    end

    test "the channel's end retires its sessions and its unspent tickets", %{
      device: device,
      ctx: ctx,
      session_id: session_id,
      token: token
    } do
      pending = unlocked!(ctx, device.key)
      :ok = DeviceUnlock.closed(ctx.user_id, ctx.client_id, [session_id, pending.session_id])
      assert {:error, :invalid_session} = Sanctum.Session.load(token)
      assert {:error, :invalid_ticket} = DeviceUnlock.redeem(pending.ticket)
    end
  end

  describe "retirement" do
    setup do
      device = enrolled!()
      %{device: device, ctx: connected!(device)}
    end

    test "a revocation before the redemption refuses it, and after it ends the session", %{
      device: device,
      ctx: ctx
    } do
      first = unlocked!(ctx, device.key)
      second = unlocked!(ctx, device.key)
      {:ok, %{token: token}} = DeviceUnlock.redeem(first.ticket)

      revoke_client!(device)

      assert session_row(first.session_id) == nil
      assert {:error, :invalid_session} = Sanctum.Session.load(token)
      assert {:error, :not_standing} = DeviceUnlock.redeem(second.ticket)
      assert session_row(second.session_id) == nil
    end

    test "a certificate revoked before the redemption refuses it, and after it the session no longer loads",
         %{device: device, ctx: ctx} do
      first = unlocked!(ctx, device.key)
      second = unlocked!(ctx, device.key)
      {:ok, %{token: token}} = DeviceUnlock.redeem(first.ticket)

      revoke_certificate!(device.certificate.athanor, device.certificate.client_id)

      assert {:error, :invalid_session} = Sanctum.Session.load(token)
      assert {:error, :not_standing} = DeviceUnlock.redeem(second.ticket)
    end
  end

  # ---------------------------------------------------------------------------
  # Confirmation
  # ---------------------------------------------------------------------------

  describe "confirmation" do
    setup do
      device = enrolled!()
      ctx = connected!(device)

      # The change is asked on another client of the person's: a browser's
      # session, which stands whatever becomes of the device.
      browser =
        Context.build(
          user_id: ctx.user_id,
          provider: "passkey",
          athanor_id: ctx.athanor_id,
          permissions: Context.person_permissions(),
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, session} = Sanctum.TestContext.create_session(browser)
      {:ok, opener} = Sanctum.Caller.establish(session.token)

      change = %{
        operation: "pairing.revoke",
        arguments: %{"client_id" => "pcl_x"},
        resource: "pcl_x"
      }

      {:error, {:confirmation_required, %{id: secret}}} =
        Sanctum.Consent.Authz.check(opener, :pairing_revocation, change)

      ref = Prima.Confirmation.ref(secret)
      %{device: device, ctx: ctx, opener: opener, change: change, secret: secret, ref: ref}
    end

    defp pending_challenge!(ctx, ref) do
      {:ok, %{confirmations: [record]}} =
        Sanctum.Providers.Confirmation.handle(ctx, %{"action" => "pending", "request" => ref})

      assert "device" in record.methods
      {:ok, challenge} = Challenge.decode(record.challenge)
      {record, challenge}
    end

    defp confirm(ctx, ref, proof),
      do:
        Sanctum.Providers.Confirmation.handle(ctx, %{
          "action" => "confirm",
          "ref" => ref,
          "device_proof" => proof
        })

    test "the device proves its person's record, recorded as its own, and the opener alone consumes it",
         %{device: device, ctx: ctx, opener: opener, change: change, secret: secret, ref: ref} do
      {record, challenge} = pending_challenge!(ctx, ref)
      assert challenge.purpose == :confirm
      assert challenge.ref == ref
      {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), ref)
      assert challenge.digest == row.digest
      assert record.preview == Jason.decode!(row.preview)

      assert {:ok, %{state: "confirmed"}} =
               confirm(ctx, ref, signed(challenge, elem(device.key, 1)))

      {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), ref)
      assert row.proof == "device" and row.confirmed_client_id == ctx.client_id

      # Only the opener repeats the change: the device, even holding the
      # secret, is another credential and consumes nothing.
      refute :ok ==
               Sanctum.Consent.Authz.check(
                 %{ctx | confirmation_id: secret},
                 :pairing_revocation,
                 change
               )

      assert :ok =
               Sanctum.Consent.Authz.check(
                 %{opener | confirmation_id: secret},
                 :pairing_revocation,
                 change
               )
    end

    test "a proof over a modified digest, another key's or a replayed one confirms nothing",
         %{device: device, ctx: ctx, ref: ref} do
      {_record, challenge} = pending_challenge!(ctx, ref)
      forged = %{challenge | digest: "sha256:" <> String.duplicate("0", 64)}

      assert {:error, %Prima.Refusal{reason: :proof_refused}} =
               confirm(ctx, ref, signed(forged, elem(device.key, 1)))

      {_record, challenge} = pending_challenge!(ctx, ref)
      {_other, other_private} = key()

      assert {:error, %Prima.Refusal{reason: :proof_refused}} =
               confirm(ctx, ref, signed(challenge, other_private))

      # Taken by that refusal.
      assert {:error, %Prima.Refusal{reason: :proof_refused}} =
               confirm(ctx, ref, signed(challenge, elem(device.key, 1)))

      {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), ref)
      assert row.state == "pending"
    end

    test "a cancelled record, a browser's device proof and a device proof beside another confirm nothing",
         %{device: device, ctx: ctx, opener: opener, ref: ref} do
      {_record, challenge} = pending_challenge!(ctx, ref)
      proof = signed(challenge, elem(device.key, 1))

      assert {:error, {:invalid_argument, _}} =
               Sanctum.Providers.Confirmation.handle(ctx, %{
                 "action" => "confirm",
                 "ref" => ref,
                 "device_proof" => proof,
                 "code" => "123456"
               })

      assert {:error, %Prima.Refusal{reason: :not_a_device}} = confirm(opener, ref, proof)

      {:ok, _} = Sanctum.Providers.Confirmation.handle(ctx, %{"action" => "cancel", "ref" => ref})
      {:error, _refused} = confirm(ctx, ref, proof)
      {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), ref)
      assert row.state == "cancelled"
    end

    test "a device revoked after its proof leaves the change unconsumed",
         %{device: device, ctx: ctx, opener: opener, change: change, secret: secret, ref: ref} do
      {_record, challenge} = pending_challenge!(ctx, ref)
      {:ok, _} = confirm(ctx, ref, signed(challenge, elem(device.key, 1)))

      revoke_certificate!(ctx.athanor_id, ctx.client_id)

      refute :ok ==
               Sanctum.Consent.Authz.check(
                 %{opener | confirmation_id: secret},
                 :pairing_revocation,
                 change
               )
    end
  end

  describe "a passkey beside a device" do
    # A person setup made by a device's enrollment: they hold no sign-in
    # method and no passkey, only the box; then a passkey of theirs,
    # registered under the box's own confirmation.
    setup do
      device = enrolled!()
      device_ctx = connected!(device)
      user_id = device.certificate.subject.user_id
      session = Sanctum.TestContext.session!(user_id, "local", device.certificate.athanor)
      assert {:ok, []} = Arca.Users.identities(Prima.Actor.system(), user_id)

      authenticator = Sanctum.TestContext.Authenticator.new("beside-#{user_id}")
      {:ok, options} = Sanctum.Passkeys.register(session, %{})

      credential =
        Sanctum.TestContext.Authenticator.registration(authenticator, options)

      {:error, {:confirmation_required, %{id: id}}} =
        Sanctum.Passkeys.register(session, %{credential: credential})

      device_confirmed!(device_ctx, device, id)

      {:ok, %{status: "active", passkey: passkey}} =
        Sanctum.Passkeys.register(%{session | confirmation_id: id}, %{credential: credential})

      %{device: device, device_ctx: device_ctx, session: session, passkey: passkey}
    end

    # The record `id` names proven by the device's own unlock, over the
    # challenge its pending read answered.
    defp device_confirmed!(device_ctx, device, id) do
      ref = Prima.Confirmation.ref(id)

      {:ok, %{confirmations: [record]}} =
        Sanctum.Providers.Confirmation.handle(device_ctx, %{
          "action" => "pending",
          "request" => ref
        })

      {:ok, challenge} = Challenge.decode(record.challenge)

      {:ok, %{state: "confirmed"}} =
        Sanctum.Providers.Confirmation.handle(device_ctx, %{
          "action" => "confirm",
          "ref" => ref,
          "device_proof" => signed(challenge, elem(device.key, 1))
        })
    end

    test "the passkey is revoked with the device standing, which still signs its person in", %{
      device: device,
      device_ctx: device_ctx,
      session: session,
      passkey: passkey
    } do
      assert {:error, {:confirmation_required, %{id: id}}} =
               Sanctum.Passkeys.revoke(session, passkey.id)

      device_confirmed!(device_ctx, device, id)

      assert {:ok, %{state: "revoked"}} =
               Sanctum.Passkeys.revoke(%{session | confirmation_id: id}, passkey.id)

      # The device unlocks a session as before.
      assert %{ticket: _} = unlocked!(device_ctx, device.key)
    end

    test "with the device revoked too, the passkey is the last way in and stays", %{
      device: device,
      session: session,
      passkey: passkey
    } do
      {1, _} =
        Arca.Repo.update_all(
          from(p in PairedClient, where: p.id == ^device.certificate.client_id),
          set: [standing: "revoked"]
        )

      assert {:error, {:conflict, sentence}} = Sanctum.Passkeys.revoke(session, passkey.id)
      assert sentence =~ "only way to sign in"
    end
  end
end

defmodule Sanctum.DeviceUnlockKilledTest do
  @moduledoc """
  A device's setup enrollment killed mid-transaction, on a real connection
  outside the sandbox: the process dies after the person's row and keys
  are written and before the commit, and nothing of it remains, so a
  resume of it finds nothing and the device enrolls again from the start.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{
    DeviceCertificate,
    IdentityAttempt,
    Membership,
    PairedClient,
    PersonIdentity,
    User
  }

  alias Ecto.Adapters.SQL.Sandbox
  alias Prima.DeviceCert.Proof
  alias Sanctum.DeviceUnlock

  @token String.duplicate("9c", 32)

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  setup do
    Arca.Cache.init()

    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Sanctum.Test.Newcomers.directory!()
    assert 0 == unboxed(fn -> Arca.Repo.aggregate(User, :count) end)
    :ok
  end

  defp counts do
    unboxed(fn ->
      for schema <- [User, PersonIdentity, PairedClient, DeviceCertificate, IdentityAttempt],
          do: Arca.Repo.aggregate(schema, :count)
    end) ++
      [
        unboxed(fn ->
          Arca.Repo.aggregate(from(m in Membership, where: m.scope == "platform"), :count)
        end)
      ]
  end

  defp enroll(key, identity) do
    {public, private} = key

    {:ok, %{challenge: challenge}} =
      DeviceUnlock.enrollment_challenge({:setup, @token}, %{
        "admission" => "setup",
        "device_key" => b64(public),
        "request_id" => identity.request_id,
        "holder_kind" => "software",
        "display_name" => "Box"
      })

    DeviceUnlock.enroll({:setup, @token}, %{
      "proof" => Proof.encode(Proof.sign(challenge, private)),
      "name" => identity.name,
      "recovery_secret" => b64(identity.recovery_secret)
    })
  end

  test "an enrollment killed before its commit leaves nothing to resume" do
    test = self()
    handler = "device-killed-#{System.unique_integer([:positive])}"
    key = :crypto.generate_key(:eddsa, :ed25519)
    identity = Sanctum.Test.Newcomers.identity()

    # Inside the admission's transaction, at its paired client's write: the
    # person's row, their keys and their athanor are written and
    # uncommitted.
    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:source] == "paired_clients" and Process.get(:device_enrolling) and
               not Process.get(:device_paused, false) do
            Process.put(:device_paused, true)
            send(test, {:enrolling, self()})

            receive do
              :never -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    enrolling =
      spawn(fn ->
        unboxed(fn ->
          Process.put(:device_enrolling, true)
          enroll(key, identity)
        end)
      end)

    assert_receive {:enrolling, ^enrolling}, 15_000
    ref = Process.monitor(enrolling)
    Process.exit(enrolling, :kill)
    assert_receive {:DOWN, ^ref, :process, ^enrolling, :killed}, 5_000
    :telemetry.detach(handler)

    assert counts() == [0, 0, 0, 0, 0, 0]

    # Nothing committed, so nothing resumes.
    assert {:error, :not_found} =
             unboxed(fn ->
               DeviceUnlock.resume({:setup, @token}, %{
                 "admission" => "setup",
                 "device_key" => b64(elem(key, 0)),
                 "request_id" => identity.request_id
               })
             end)
  end
end
