# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PairingTest do
  @moduledoc """
  The pairing ceremony, which changes need a fresh confirmation, and which
  clients can give one.

  A session opens a short-lived, single-use bearer invitation, stored
  hashed. A glass holding nothing presents it with its device key, signs
  the `pair` challenge it is answered, and is paired to the person the
  invitation names, whoever's session its browser holds, with its first
  certificate, in one transaction with the invitation's consumption and
  the person's standing and seat locked and rechecked. A device renews
  through its channel under the key its row stores while it stands, and a
  person revokes their own. Completions share per-source and
  per-installation bounds. Local pairing reads no directory.

  The closed action table, the operations that confirm each action, no
  change asking for a proof before one exists, and who can confirm: a
  client with no person behind it confirms nothing, a paired device while
  its client stands. No rank is held anywhere.
  """

  # The rate limiter's table and the directory setting are the node's.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{DeviceCertificate, PairedClient, PairingInvitation, PersonIdentity}
  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Sanctum.{Context, DeviceCerts, Pairing, Person}
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @source "198.51.100.20"

  setup tags do
    if tags[:database] == false do
      :ok
    else
      Arca.Cache.init()
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      Prima.RateLimiter.reset()
      directory = Application.get_env(:sanctum, :directory_url)

      on_exit(fn ->
        Prima.RateLimiter.reset()

        if directory,
          do: Application.put_env(:sanctum, :directory_url, directory),
          else: Application.delete_env(:sanctum, :directory_url)
      end)

      seated!()
    end
  end

  defp ctx(attrs) do
    Context.build(
      Map.merge(
        %{user_id: "usr_pair", athanor_id: "ath_pair", authenticated: true, permissions: [:*]},
        Map.new(attrs)
      )
    )
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A person seated in a group of their own, and the context their session
  # establishes there.
  defp seated! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|pairing-#{n}",
        provider: "github",
        email: "pairing#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Pairing #{n}")

    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)

    {:ok, session_ctx} =
      Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

    %{user: user, athanor: athanor, session_ctx: session_ctx, session_token: session.token}
  end

  # The pending record a confirmation's secret names, read by its ref.
  defp record!(ctx, id) do
    {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), Prima.Confirmation.ref(id))
    row
  end

  defp glass(source \\ @source), do: Context.build(%{authenticated: false, client_ip: source})

  defp device_key, do: :crypto.generate_key(:eddsa, :ed25519)

  # The glass's two calls: the challenge for its key, then its proof.
  defp complete(secret, {device_key, private}, source \\ @source) do
    with {:ok, %{challenge: challenge}} <-
           Pairing.complete(glass(source), secret, %{device_key: device_key}) do
      Pairing.complete(glass(source), secret, %{
        device_key: device_key,
        proof: Proof.sign(challenge, private)
      })
    end
  end

  # Beginning a pairing and revoking a device are sensitive changes: each
  # under a confirmation the person proved (`Sanctum.TestContext.confirmed/3`).
  defp begin!(session_ctx) do
    session_ctx
    |> Sanctum.TestContext.confirmed(:device_pairing, Pairing.invitation_change())
    |> Pairing.begin(%{})
  end

  defp revoke!(session_ctx, client_id) do
    session_ctx
    |> Sanctum.TestContext.confirmed(:pairing_revocation, %{
      operation: "pairing.revoke",
      arguments: %{"client_id" => client_id},
      resource: client_id
    })
    |> Pairing.revoke(client_id)
  end

  defp pair!(session_ctx) do
    {device_key, private} = key = device_key()
    {:ok, invitation} = begin!(session_ctx)
    {:ok, paired} = complete(invitation.invitation_secret, key)
    Map.merge(paired, %{device_key: device_key, private: private})
  end

  # The device's context, as its channel mints it from a connect proof.
  defp connected!(device) do
    challenge = challenge(device, :connect)

    {:ok, ctx} =
      DeviceCerts.verify_connect(
        %{client_id: device.client_id, certificate: device.certificate, source: @source},
        Proof.sign(challenge, device.private),
        challenge
      )

    ctx
  end

  # The device's context, as its channel mints it from a renewal proof.
  defp renewing!(device, challenge) do
    {:ok, ctx} =
      DeviceCerts.verify_connect(
        %{client_id: device.client_id, certificate: device.certificate, source: @source},
        Proof.sign(challenge, device.private),
        challenge
      )

    ctx
  end

  defp challenge(device, purpose, overrides \\ []) do
    certificate = device.certificate

    {:ok, challenge} =
      [
        purpose: purpose,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: device.client_id,
        device_key: certificate.device_key,
        nonce: :crypto.strong_rand_bytes(Challenge.nonce_bytes()),
        now: System.system_time(:millisecond)
      ]
      |> Keyword.merge(overrides)
      |> Challenge.new()

    challenge
  end

  defp renewal(device, challenge) do
    %{
      client_id: device.client_id,
      device_key: device.device_key,
      proof: Proof.sign(challenge, device.private)
    }
  end

  defp clients(user_id),
    do: Arca.Repo.all(from(p in PairedClient, where: p.user_id == ^user_id))

  defp invitation_row(secret),
    do: Arca.Repo.get_by!(PairingInvitation, secret_hash: Prima.Digest.sha256(secret))

  defp live_key(user_id), do: Arca.Repo.get_by!(PersonIdentity, user_id: user_id).live_public_key

  defp rotate_live_key!(user_id) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, sealed} = Sanctum.Cipher.encrypt(private, Sanctum.CipherAAD.person_key(user_id, :live))

    {1, _} =
      Arca.Repo.update_all(from(p in PersonIdentity, where: p.user_id == ^user_id),
        set: [live_public_key: public, live_key_sealed: sealed]
      )

    public
  end

  # ---------------------------------------------------------------------------
  # The action table
  # ---------------------------------------------------------------------------

  @sensitive [
    :credential_entry,
    :credential_issuance,
    :vault_unlock,
    :home_transfer,
    :pairing_revocation,
    :recovery_material,
    :device_pairing,
    :passkey_registration,
    :remote_sign_in,
    :key_rotation,
    :sign_in_methods
  ]

  describe "the action table" do
    @describetag database: false

    test "is closed: today's rows and the seven this plan adds" do
      assert Pairing.actions() == Enum.sort([:grant, :approval | @sensitive])
    end

    test "a grant and an approval need the session alone; every other action is sensitive" do
      refute Pairing.sensitive?(:grant)
      refute Pairing.sensitive?(:approval)
      for action <- @sensitive, do: assert(Pairing.sensitive?(action), inspect(action))

      assert_raise FunctionClauseError, fn -> Pairing.sensitive?(:anything) end
    end

    test "each operation that confirms something maps to its action, and no other does" do
      expected = %{
        "vault.create" => :credential_entry,
        "vault.rotate" => :credential_entry,
        "vault.authorize" => :credential_entry,
        "oauth.set_client" => :credential_entry,
        "key.create" => :credential_issuance,
        "key.rotate" => :credential_issuance,
        "webhook.create" => :credential_issuance,
        "webhook.rotate" => :credential_issuance,
        "pairing.revoke" => :pairing_revocation,
        "person.enroll" => :recovery_material,
        "person.kit" => :recovery_material,
        "person.enroll_holder" => :recovery_material,
        "passkey.register" => :passkey_registration,
        "passkey.revoke" => :passkey_registration,
        "passkey.recover_admin" => :passkey_registration,
        "pairing.begin" => :device_pairing,
        "person.certify" => :device_pairing,
        "person.assert" => :remote_sign_in,
        "person.rotate" => :key_rotation,
        "person.link_door" => :sign_in_methods,
        "person.unlink_door" => :sign_in_methods
      }

      for {operation, action} <- expected do
        assert Pairing.action_for(operation) == action, operation
        assert action in Pairing.actions()
      end

      # The unlock and the transfer have no operation yet, and a read or an
      # everyday change confirms nothing.
      for operation <- ~w(vault.list vault.rename key.revoke profile.commit person.kit_ack
                          pairing.complete pairing.list pairing.renew vault/create) do
        assert Pairing.action_for(operation) == nil, operation
      end
    end
  end

  describe "fresh_required?/2" do
    @describetag database: false

    test "answers the table, the same for every person and every client" do
      for action <- Pairing.actions(),
          context <- [
            ctx(auth_method: :oidc),
            ctx(auth_method: :api_key),
            ctx(auth_method: :device)
          ] do
        assert Pairing.fresh_required?(action, context) == Pairing.sensitive?(action),
               inspect(action)
      end

      refute Pairing.fresh_required?(:grant, ctx(auth_method: :oidc))
      refute Pairing.fresh_required?(:approval, ctx(auth_method: :oidc))
      assert Pairing.fresh_required?(:credential_issuance, ctx(auth_method: :api_key))
      assert Pairing.fresh_required?(:vault_unlock, ctx(auth_method: :oidc))
      assert Pairing.fresh_required?(:home_transfer, ctx(auth_method: :oidc))

      assert_raise FunctionClauseError, fn ->
        Pairing.fresh_required?(:delete_everything, ctx(auth_method: :oidc))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Who can confirm
  # ---------------------------------------------------------------------------

  describe "can_confirm?/1" do
    test "a signed-in browser session has a person behind it who can give a proof" do
      assert Pairing.can_confirm?(ctx(auth_method: :oidc))
    end

    test "a client with no person behind it confirms nothing" do
      nobody = [
        ctx(auth_method: :oidc, plane: :guest),
        ctx(auth_method: :api_key, api_key_type: :admin),
        ctx(auth_method: :api_key, plane: :guest),
        ctx(auth_method: :session),
        ctx(auth_method: :tincture),
        ctx(auth_method: :webhook),
        ctx(auth_method: :scheduled),
        ctx(auth_method: :system),
        ctx(auth_method: :oidc, anonymous: true),
        Context.build(%{auth_method: :oidc, authenticated: false})
      ]

      for context <- nobody,
          do: refute(Pairing.can_confirm?(context), inspect(context.auth_method))
    end

    test "a paired device confirms while its paired client stands, read from the store", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      ctx = connected!(device)

      assert Pairing.can_confirm?(ctx)

      {:ok, _row} = revoke!(session_ctx, device.client_id)
      refute Pairing.can_confirm?(ctx)
    end

    test "a paired client is the device channel's alone: no other context names one" do
      refute Pairing.can_confirm?(ctx(auth_method: :device))
      refute Pairing.can_confirm?(ctx(auth_method: :oidc, client_id: "pcl_1"))
      refute Pairing.can_confirm?(ctx(auth_method: :device, client_id: "pcl_1"))
      refute Pairing.can_confirm?(ctx(auth_method: :device, client_id: "pcl_1", plane: :guest))
    end
  end

  # ---------------------------------------------------------------------------
  # Beginning
  # ---------------------------------------------------------------------------

  describe "begin/2" do
    test "a thief holding the asking session's own token, asking first, never takes the person's invitation",
         %{session_token: token, user: user, athanor: athanor} do
      # Two contexts built from one session token: the thief's, which asks
      # first, and the person's. One credential, one opener.
      {:ok, thief} = Sanctum.Caller.establish(token, focus: athanor.id, task_supervisor: nil)
      {:ok, person} = Sanctum.Caller.establish(token, focus: athanor.id, task_supervisor: nil)
      assert thief.session_token_hash == person.session_token_hash

      assert {:error, {:confirmation_required, %{id: thief_id}}} = Pairing.begin(thief, %{})
      assert {:error, {:confirmation_required, %{id: person_id}}} = Pairing.begin(person, %{})

      # The person's identical request gets a record of its own, which the
      # person proves by its ref, as any client of theirs reads it.
      refute person_id == thief_id
      person_ref = Prima.Confirmation.ref(person_id)
      refute person_ref == Prima.Confirmation.ref(thief_id)
      assert %{state: "confirmed"} = Sanctum.TestContext.prove!(person, person_ref)

      # The thief repeats under its own secret, and waits on its own
      # unproven record; or under the ref it learned from the stream or the
      # pending list, which names nothing to consume, and is asked for a
      # proof anew. No invitation opens.
      assert {:error, {:confirmation_required, %{id: ^thief_id}}} =
               Pairing.begin(%{thief | confirmation_id: thief_id}, %{})

      assert {:error, {:confirmation_required, %{id: fresh}}} =
               Pairing.begin(%{thief | confirmation_id: person_ref}, %{})

      refute fresh in [thief_id, person_id]

      assert Arca.Repo.all(from(i in PairingInvitation, where: i.user_id == ^user.id)) == []
      assert record!(person, person_id).state == "confirmed"

      # The person repeats under their own secret, once; the thief's record
      # stays unproven.
      assert {:ok, %{invitation_secret: _}} =
               Pairing.begin(%{person | confirmation_id: person_id}, %{})

      assert record!(person, person_id).state == "consumed"
      assert record!(person, thief_id).state == "pending"
    end

    test "opens a five-minute, 128-bit bearer invitation, stored only as its hash", %{
      session_ctx: session_ctx,
      user: user,
      athanor: athanor
    } do
      before = DateTime.utc_now()
      assert {:ok, invitation} = begin!(session_ctx)

      assert byte_size(invitation.invitation_secret) == 16
      assert "pcl_" <> _ = invitation.client_id

      row = invitation_row(invitation.invitation_secret)
      assert row.state == "pending"
      assert {row.user_id, row.athanor_id} == {user.id, athanor.id}
      assert row.prospective_client_id == invitation.client_id
      assert row.audience_home == Person.home()
      assert DateTime.diff(row.expires_at, before, :second) in 299..301
      assert invitation.expires_at == row.expires_at

      # No column holds the secret or anything but its hash.
      raw = Base.url_encode64(invitation.invitation_secret, padding: false)
      refute inspect(Map.from_struct(row)) =~ raw
      refute inspect(Map.from_struct(row)) =~ invitation.invitation_secret

      # Each invitation is its own.
      {:ok, second} = begin!(session_ctx)
      refute second.invitation_secret == invitation.invitation_secret
      refute second.client_id == invitation.client_id
    end

    test "begun without proof asks for one and opens nothing; proven, it pairs", %{
      session_ctx: session_ctx,
      user: user
    } do
      assert {:error, {:confirmation_required, %{id: id, operation: "pairing.begin"}}} =
               Pairing.begin(session_ctx, %{})

      assert Arca.Repo.all(from(i in PairingInvitation, where: i.user_id == ^user.id)) == []

      Sanctum.TestContext.prove!(session_ctx, id)
      assert {:ok, invitation} = Pairing.begin(%{session_ctx | confirmation_id: id}, %{})

      assert record!(session_ctx, id).state == "consumed"
      assert {:ok, _paired} = complete(invitation.invitation_secret, device_key())

      # The confirmation paired once: naming it again asks anew.
      assert {:error, {:confirmation_required, %{id: again}}} =
               Pairing.begin(%{session_ctx | confirmation_id: id}, %{})

      refute again == id
    end

    test "another session of the person never takes the invitation the asking session proved", %{
      session_ctx: asking,
      user: user,
      athanor: athanor
    } do
      built =
        Context.build(
          user_id: user.id,
          email: user.email,
          provider: "github",
          athanor_id: athanor.id,
          permissions: [:*],
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, session} = Sanctum.TestContext.create_session(built)

      {:ok, stolen} =
        Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

      assert {:error, {:confirmation_required, %{id: id}}} = Pairing.begin(asking, %{})
      Sanctum.TestContext.prove!(asking, id)

      # The stolen session names the proven record: it is asked for a proof
      # of its own, and no invitation is opened for it.
      assert {:error, {:confirmation_required, %{id: own}}} =
               Pairing.begin(%{stolen | confirmation_id: id}, %{})

      refute own == id
      assert Arca.Repo.all(from(i in PairingInvitation, where: i.user_id == ^user.id)) == []

      # The asking session repeats under its record, once.
      assert {:ok, %{invitation_secret: _}} = Pairing.begin(%{asking | confirmation_id: id}, %{})
      assert record!(asking, id).state == "consumed"
    end

    test "a record a device confirmed is void once that device is revoked", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      device_ctx = connected!(device)
      authenticator = Sanctum.TestContext.passkey!(session_ctx.user_id)

      {1, _} =
        Arca.Repo.update_all(from(p in PairedClient, where: p.id == ^device.client_id),
          set: [label: "Kitchen tablet"]
        )

      assert {:error, {:confirmation_required, %{id: id}}} = Pairing.begin(device_ctx, %{})
      row = record!(device_ctx, id)
      "sha256:" <> hex = row.digest

      # The record names the device that asked, by its name.
      assert Jason.decode!(row.asker) == %{"kind" => "client", "name" => "Kitchen tablet"}

      assertion =
        Sanctum.TestContext.Authenticator.assertion(
          authenticator,
          Base.decode16!(hex, case: :lower)
        )

      assert {:ok, %{state: "confirmed"}} =
               Sanctum.Passkeys.assert(device_ctx, row.ref, assertion)

      assert record!(device_ctx, id).confirmed_client_id == device.client_id

      # The revocation's preview names the device by its name now.
      {:ok, _} =
        Sanctum.TestContext.confirming(session_ctx, &Pairing.revoke(&1, device.client_id))

      assert record!(device_ctx, id).state == "voided"

      assert {:error, {:confirmation_required, %{id: fresh}}} =
               Pairing.begin(%{session_ctx | confirmation_id: id}, %{})

      refute fresh == id
    end

    test "a device's long name is kept within 255 bytes, cut between characters", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      device_ctx = connected!(device)

      # Four bytes a character: 100 of them are 400 bytes, and 63 fit.
      {1, _} =
        Arca.Repo.update_all(from(p in PairedClient, where: p.id == ^device.client_id),
          set: [label: String.duplicate("🦫", 100)]
        )

      assert {:error, {:confirmation_required, %{id: id}}} = Pairing.begin(device_ctx, %{})
      assert %{"kind" => "client", "name" => name} = Jason.decode!(record!(device_ctx, id).asker)
      assert name == String.duplicate("🦫", 63)
      assert byte_size(name) <= 255 and String.valid?(name)
    end

    test "needs a person working in an athanor", %{session_ctx: session_ctx} do
      assert Pairing.begin(%{session_ctx | athanor_id: nil}, %{}) == {:error, :missing_tenant}

      assert Pairing.begin(Context.build(%{authenticated: false}), %{}) ==
               {:error, :unauthenticated}
    end

    test "opens nothing for a person denied since their context was read", %{
      session_ctx: session_ctx,
      user: user
    } do
      {:ok, _} = Users.deny(user)

      assert {:error, _refused} = Pairing.begin(session_ctx, %{})

      assert Arca.Repo.all(from(i in PairingInvitation, where: i.user_id == ^user.id)) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Completing
  # ---------------------------------------------------------------------------

  describe "complete/3" do
    test "a glass with neither cookie nor certificate is paired by the invitation and its key proof",
         %{session_ctx: session_ctx, user: user, athanor: athanor} do
      {:ok, invitation} = begin!(session_ctx)
      {device_key, private} = device_key()

      assert {:ok, %{challenge: %Challenge{} = challenge}} =
               Pairing.complete(glass(), invitation.invitation_secret, %{device_key: device_key})

      assert challenge.purpose == :pair
      assert challenge.home == Person.home()
      assert challenge.athanor == athanor.id
      assert challenge.client_id == invitation.client_id
      assert challenge.device_key == device_key

      # Nothing is issued for a challenge.
      assert clients(user.id) == []

      assert {:ok, %{client_id: client_id, certificate: %DeviceCert{} = certificate}} =
               Pairing.complete(glass(), invitation.invitation_secret, %{
                 device_key: device_key,
                 proof: Proof.sign(challenge, private)
               })

      # The client the invitation reserved, standing on the device key it
      # proved, for the person and athanor the invitation named.
      assert client_id == invitation.client_id
      assert [client] = clients(user.id)

      assert {client.id, client.standing, client.source_kind} ==
               {client_id, "active", "device_cert"}

      assert client.device_public_key == device_key
      assert client.athanor_id == athanor.id

      # Its first certificate: local, this home's, signed by the live key.
      assert certificate.subject == %{kind: :local, user_id: user.id}
      assert certificate.issuer == Person.home() and certificate.audience == Person.home()
      assert {certificate.client_id, certificate.athanor} == {client_id, athanor.id}
      assert certificate.device_key == device_key

      assert {:ok, _} =
               DeviceCert.verify(certificate, live_key(user.id),
                 home: Person.home(),
                 now: System.os_time(:millisecond),
                 skew: 0
               )

      assert [recorded] =
               Arca.Repo.all(
                 from(c in DeviceCertificate, where: c.paired_client_id == ^client_id)
               )

      assert recorded.subject_kind == "local"
      assert invitation_row(invitation.invitation_secret).state == "consumed"
    end

    test "binds the client to the person the invitation names, whatever session asks", %{
      session_ctx: session_ctx,
      user: user
    } do
      {:ok, invitation} = begin!(session_ctx)
      stranger = seated!()
      {device_key, private} = device_key()

      {:ok, %{challenge: challenge}} =
        Pairing.complete(stranger.session_ctx, invitation.invitation_secret, %{
          device_key: device_key
        })

      assert {:ok, %{certificate: certificate}} =
               Pairing.complete(stranger.session_ctx, invitation.invitation_secret, %{
                 device_key: device_key,
                 proof: Proof.sign(challenge, private)
               })

      assert certificate.subject.user_id == user.id
      assert [_client] = clients(user.id)
      assert clients(stranger.user.id) == []
    end

    test "a code presented twice: the second is refused, one client stands", %{
      session_ctx: session_ctx,
      user: user
    } do
      {:ok, invitation} = begin!(session_ctx)
      assert {:ok, _paired} = complete(invitation.invitation_secret, device_key())

      assert complete(invitation.invitation_secret, device_key()) ==
               {:error, :invalid_invitation}

      {device_key, _} = device_key()

      assert Pairing.complete(glass(), invitation.invitation_secret, %{device_key: device_key}) ==
               {:error, :invalid_invitation}

      assert length(clients(user.id)) == 1
    end

    test "a correct code with no proof of the key submitted issues nothing", %{
      session_ctx: session_ctx,
      user: user
    } do
      {:ok, invitation} = begin!(session_ctx)
      {device_key, private} = device_key()
      {_other_key, other_private} = device_key()

      {:ok, %{challenge: challenge}} =
        Pairing.complete(glass(), invitation.invitation_secret, %{device_key: device_key})

      # Signed by another key than the one submitted.
      assert Pairing.complete(glass(), invitation.invitation_secret, %{
               device_key: device_key,
               proof: Proof.sign(challenge, other_private)
             }) == {:error, :proof_refused}

      # A proof that is not one at all.
      assert Pairing.complete(glass(), invitation.invitation_secret, %{
               device_key: device_key,
               proof: %{"sig" => "nothing"}
             }) == {:error, :proof_refused}

      assert clients(user.id) == []
      assert invitation_row(invitation.invitation_secret).state == "pending"

      # The invitation still pairs the key that proves itself.
      assert {:ok, _} =
               Pairing.complete(glass(), invitation.invitation_secret, %{
                 device_key: device_key,
                 proof: Proof.sign(challenge, private)
               })
    end

    test "a challenge for another home, client, athanor, key or purpose is refused", %{
      session_ctx: session_ctx,
      user: user
    } do
      {:ok, invitation} = begin!(session_ctx)
      {device_key, private} = device_key()
      {other_key, _} = device_key()

      {:ok, %{challenge: challenge}} =
        Pairing.complete(glass(), invitation.invitation_secret, %{device_key: device_key})

      for changed <- [
            %{challenge | home: "https://elsewhere.example"},
            %{challenge | client_id: "pcl_another"},
            %{challenge | athanor: "ath_another"},
            %{challenge | device_key: other_key},
            %{challenge | purpose: :connect},
            %{challenge | purpose: :renew},
            %{challenge | nonce: :crypto.strong_rand_bytes(32)},
            # A challenge that would outlive any this home issues.
            %{challenge | expires_at: challenge.expires_at + Challenge.lifetime_ms()}
          ] do
        assert Pairing.complete(glass(), invitation.invitation_secret, %{
                 device_key: device_key,
                 proof: Proof.sign(changed, private)
               }) == {:error, :proof_refused},
               inspect(Map.take(changed, [:home, :client_id, :athanor, :purpose]))
      end

      assert clients(user.id) == []
    end

    test "a proof after its challenge expired is refused", %{session_ctx: session_ctx} do
      {:ok, invitation} = begin!(session_ctx)
      {device_key, private} = device_key()

      {:ok, %{challenge: challenge}} =
        Pairing.complete(glass(), invitation.invitation_secret, %{device_key: device_key})

      stale = %{challenge | expires_at: System.os_time(:millisecond) - 1}

      assert Pairing.complete(glass(), invitation.invitation_secret, %{
               device_key: device_key,
               proof: Proof.sign(stale, private)
             }) == {:error, :proof_refused}
    end

    test "an invitation for another home is refused", %{session_ctx: session_ctx, user: user} do
      secret = :crypto.strong_rand_bytes(16)
      {:ok, expectation} = Sanctum.Issuance.expectation(session_ctx, [])

      {:ok, _} =
        Arca.PairingInvitations.open(
          Context.actor(session_ctx),
          %{
            user_id: user.id,
            membership_id: expectation.membership_id,
            secret_hash: Prima.Digest.sha256(secret),
            audience_home: "https://hub.example",
            lifetime_ms: 300_000
          },
          fn _locked -> :ok end
        )

      {device_key, _} = device_key()

      assert Pairing.complete(glass(), secret, %{device_key: device_key}) ==
               {:error, :wrong_audience}
    end

    test "an expired invitation is refused", %{session_ctx: session_ctx} do
      {:ok, invitation} = begin!(session_ctx)
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      Arca.Repo.update_all(
        from(i in PairingInvitation,
          where: i.secret_hash == ^Prima.Digest.sha256(invitation.invitation_secret)
        ),
        set: [expires_at: past]
      )

      assert complete(invitation.invitation_secret, device_key()) ==
               {:error, :invalid_invitation}
    end

    test "a code presented after its person was denied is refused before issuance", %{
      session_ctx: session_ctx,
      user: user
    } do
      {:ok, invitation} = begin!(session_ctx)
      {:ok, _} = Users.deny(user)

      assert complete(invitation.invitation_secret, device_key()) ==
               {:error, :invalid_invitation}

      assert clients(user.id) == []
    end

    test "a code presented after its person left the athanor is refused before issuance", %{
      session_ctx: session_ctx,
      user: user,
      athanor: athanor
    } do
      {:ok, invitation} = begin!(session_ctx)
      {device_key, private} = device_key()

      {:ok, %{challenge: challenge}} =
        Pairing.complete(glass(), invitation.invitation_secret, %{device_key: device_key})

      # A second member keeps the group open.
      other = seated!()
      {:ok, _} = Members.ensure(other.user.id, scope: "athanor", athanor_id: athanor.id)
      :ok = Members.remove_member(athanor, user_id: user.id)

      # The leave revoked the pending invitation with the seat.
      assert Pairing.complete(glass(), invitation.invitation_secret, %{
               device_key: device_key,
               proof: Proof.sign(challenge, private)
             }) == {:error, :invalid_invitation}

      assert clients(user.id) == []
      assert Arca.Repo.all(from(c in DeviceCertificate, where: c.user_id == ^user.id)) == []
    end

    test "a person whose keys are not here is refused, and nothing is issued", %{
      session_ctx: session_ctx,
      user: user
    } do
      {:ok, invitation} = begin!(session_ctx)
      Arca.Repo.delete_all(from(p in PersonIdentity, where: p.user_id == ^user.id))

      assert complete(invitation.invitation_secret, device_key()) ==
               {:error, :remote_identity_unavailable}

      assert clients(user.id) == []
      assert invitation_row(invitation.invitation_secret).state == "pending"
    end

    test "local pairing reads no directory: none configured, pairing works", %{
      session_ctx: session_ctx,
      user: user
    } do
      Application.delete_env(:sanctum, :directory_url)
      assert Sanctum.directory_url() == nil
      assert %{identifier: nil} = Arca.Repo.get_by!(PersonIdentity, user_id: user.id)

      device = pair!(session_ctx)
      assert device.certificate.subject == %{kind: :local, user_id: user.id}
    end

    test "a burst of wrong codes from one address is limited, a correct one after it too", %{
      session_ctx: session_ctx
    } do
      {:ok, invitation} = begin!(session_ctx)
      {device_key, _} = device_key()

      for _ <- 1..20 do
        assert Pairing.complete(glass("198.51.100.99"), :crypto.strong_rand_bytes(16), %{
                 device_key: device_key
               }) == {:error, :invalid_invitation}
      end

      assert {:error, {:rate_limited, _}} =
               Pairing.complete(glass("198.51.100.99"), :crypto.strong_rand_bytes(16), %{
                 device_key: device_key
               })

      assert {:error, {:rate_limited, _}} =
               Pairing.complete(glass("198.51.100.99"), invitation.invitation_secret, %{
                 device_key: device_key
               })

      # Another address is not charged for it.
      assert {:ok, %{challenge: _}} =
               Pairing.complete(glass("198.51.100.98"), invitation.invitation_secret, %{
                 device_key: device_key
               })
    end

    test "a code brute-forced from many addresses across two members: the installation bound holds",
         %{session_ctx: session_ctx} do
      {:ok, invitation} = begin!(session_ctx)
      {device_key, _} = device_key()

      for n <- 1..200 do
        # The first half reach one member, the second another.
        if n == 101, do: Prima.RateLimiter.reset()

        assert Pairing.complete(
                 glass("10.2.#{div(n, 250)}.#{rem(n, 250)}"),
                 :crypto.strong_rand_bytes(16),
                 %{device_key: device_key}
               ) == {:error, :invalid_invitation}
      end

      Prima.RateLimiter.reset()

      assert {:error, {:rate_limited, _}} =
               Pairing.complete(glass("10.3.0.1"), invitation.invitation_secret, %{
                 device_key: device_key
               })
    end
  end

  # ---------------------------------------------------------------------------
  # Renewing
  # ---------------------------------------------------------------------------

  describe "renew/2" do
    test "issues a replacement under the stored key while the client stands", %{
      session_ctx: session_ctx,
      user: user
    } do
      device = pair!(session_ctx)
      challenge = challenge(device, :renew)
      ctx = renewing!(device, challenge)

      assert {:ok, %{client_id: client_id, certificate: renewed}} =
               Pairing.renew(ctx, renewal(device, challenge))

      assert client_id == device.client_id
      assert renewed.device_key == device.device_key
      assert renewed.expires_at >= device.certificate.expires_at
      assert {:ok, _ctx} = DeviceCerts.verify_request(renewed, ctx, [])

      assert length(
               Arca.Repo.all(
                 from(c in DeviceCertificate, where: c.paired_client_id == ^client_id)
               )
             ) == 2

      assert renewed.subject == %{kind: :local, user_id: user.id}
    end

    test "after the live key rotated, the stored key renews and the old certificate is refused",
         %{session_ctx: session_ctx, user: user} do
      device = pair!(session_ctx)
      ctx = connected!(device)
      new_key = rotate_live_key!(user.id)

      assert DeviceCerts.verify_request(device.certificate, ctx, []) == {:error, :bad_signature}

      challenge = challenge(device, :renew)
      ctx = renewing!(device, challenge)

      assert {:ok, %{certificate: renewed}} = Pairing.renew(ctx, renewal(device, challenge))

      assert {:ok, _} =
               DeviceCert.verify(renewed, new_key,
                 home: Person.home(),
                 now: System.os_time(:millisecond),
                 skew: 0
               )
    end

    test "a renewal proof is consumed once", %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      challenge = challenge(device, :renew)
      ctx = renewing!(device, challenge)
      request = renewal(device, challenge)

      assert {:ok, _} = Pairing.renew(ctx, request)
      assert Pairing.renew(ctx, request) == {:error, :replayed}
    end

    test "concurrent renewals presenting one proof: one issues, every other is replayed", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      challenge = challenge(device, :renew)
      ctx = renewing!(device, challenge)
      request = renewal(device, challenge)

      results =
        1..4
        |> Enum.map(fn _ -> Task.async(fn -> Pairing.renew(ctx, request) end) end)
        |> Task.await_many(30_000)

      assert [{:ok, %{certificate: issued}}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert Enum.count(results, &(&1 == {:error, :replayed})) == 3

      # One replacement beside the first certificate, and it is the one
      # answered.
      assert [_first, _replacement] =
               Arca.Repo.all(
                 from(c in DeviceCertificate, where: c.paired_client_id == ^device.client_id)
               )

      assert issued.client_id == device.client_id
    end

    test "a proof of another purpose, client or key is refused", %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      renew = challenge(device, :renew)
      ctx = renewing!(device, renew)
      {other_key, other_private} = device_key()

      for {challenge, private} <- [
            {challenge(device, :connect), device.private},
            {challenge(device, :renew, client_id: "pcl_another"), device.private},
            {challenge(device, :renew, home: "https://elsewhere.example"), device.private},
            {challenge(device, :renew, device_key: other_key), other_private}
          ] do
        assert Pairing.renew(ctx, %{
                 client_id: device.client_id,
                 device_key: device.device_key,
                 proof: Proof.sign(challenge, private)
               }) == {:error, :proof_refused}
      end

      # A device key the row does not store.
      assert Pairing.renew(ctx, %{
               client_id: device.client_id,
               device_key: other_key,
               proof: Proof.sign(challenge(device, :renew, device_key: other_key), other_private)
             }) == {:error, :proof_refused}
    end

    test "a revoked client renews nothing: a revoked pairing is never revived", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      challenge = challenge(device, :renew)
      ctx = renewing!(device, challenge)
      {:ok, _} = revoke!(session_ctx, device.client_id)

      assert Pairing.renew(ctx, renewal(device, challenge)) == {:error, :revoked}
    end

    test "a person denied since renews nothing", %{session_ctx: session_ctx, user: user} do
      device = pair!(session_ctx)
      challenge = challenge(device, :renew)
      ctx = renewing!(device, challenge)
      {:ok, _} = Users.deny(user)

      assert {:error, reason} = Pairing.renew(ctx, renewal(device, challenge))
      assert reason in [:revoked, :not_standing]
    end

    test "only the renewal exchange's context renews: an ordinary device context does not", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      second = pair!(session_ctx)
      challenge = challenge(device, :renew)
      request = renewal(device, challenge)

      # A session, the client's own ordinary context (what an intent naming
      # `pairing.renew` runs under), and another device's.
      for ctx <- [session_ctx, connected!(device), connected!(second)] do
        assert Pairing.renew(ctx, request) == {:error, :renewal_exchange_only}
      end

      # Nothing was issued, and the proof was not spent: the exchange still
      # renews with it.
      assert {:ok, _} = Pairing.renew(renewing!(device, challenge), request)
    end
  end

  # ---------------------------------------------------------------------------
  # Revoking and listing
  # ---------------------------------------------------------------------------

  describe "revoke/2" do
    test "ends the person's own client with its certificates", %{session_ctx: session_ctx} do
      device = pair!(session_ctx)

      assert {:ok, %{id: id, standing: "revoked"}} = revoke!(session_ctx, device.client_id)
      assert id == device.client_id

      assert Enum.all?(
               Arca.Repo.all(from(c in DeviceCertificate, where: c.paired_client_id == ^id)),
               &(&1.state == "revoked")
             )

      assert {:ok, []} = Pairing.list(session_ctx)
    end

    test "cannot reach another person's client, or one that does not exist", %{
      session_ctx: session_ctx,
      athanor: athanor
    } do
      # Another member of the same athanor, signed in there.
      other = seated!()
      {:ok, _} = Members.ensure(other.user.id, scope: "athanor", athanor_id: athanor.id)

      built =
        Context.build(
          user_id: other.user.id,
          email: other.user.email,
          provider: "github",
          athanor_id: athanor.id,
          permissions: [:*],
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, session} = Sanctum.TestContext.create_session(built)

      {:ok, other_ctx} =
        Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

      device = pair!(session_ctx)

      assert Pairing.revoke(other_ctx, device.client_id) ==
               {:error, {:not_found, "paired client", device.client_id}}

      assert Pairing.revoke(session_ctx, "pcl_nothing") ==
               {:error, {:not_found, "paired client", "pcl_nothing"}}

      assert [%{client_id: client_id}] = elem(Pairing.list(session_ctx), 1)
      assert client_id == device.client_id
    end
  end

  describe "list/1" do
    test "the person's active clients in the athanor, marking the one asking", %{
      session_ctx: session_ctx
    } do
      first = pair!(session_ctx)
      second = pair!(session_ctx)

      assert {:ok, listed} = Pairing.list(session_ctx)
      assert Enum.map(listed, & &1.client_id) == [first.client_id, second.client_id]
      assert Enum.all?(listed, &(&1.source == "device_cert" and &1.current == false))

      assert Enum.all?(listed, fn client ->
               %DateTime{} = client.certificate_expires_at
             end)

      {:ok, listed} = Pairing.list(connected!(second))

      assert Enum.map(listed, &{&1.client_id, &1.current}) ==
               [{first.client_id, false}, {second.client_id, true}]
    end
  end

  # ---------------------------------------------------------------------------
  # A remote person's device
  # ---------------------------------------------------------------------------

  describe "complete/3 for a person whose keys are at another home" do
    setup %{session_ctx: session_ctx, user: user} do
      tls = Sanctum.Test.DirectoryServer.tls()
      Sanctum.Test.DirectoryServer.listen!()
      Sanctum.Test.DirectoryServer.seam!(tls)
      directory = Sanctum.Test.DirectoryServer.start!(tls)
      identity = Sanctum.Test.DirectoryServer.identity!(directory.dir, directory.url)

      # The invitation is opened under the person's proof here, then they
      # are this home's remote person of `identity`.
      {:ok, invitation} = begin!(session_ctx)
      :ok = Sanctum.Test.DirectoryServer.remote_person!(user.id, identity)

      %{directory: directory, identity: identity, invitation: invitation}
    end

    # The certificate the person's own home issues (`person.certify`) for
    # the reserved client, signed by their live key: `overrides` change its
    # fields, `:live` the key it is signed with.
    defp certified(identity, invitation, device_key, athanor, overrides \\ []) do
      now = System.os_time(:millisecond)

      {:ok, certificate} =
        DeviceCert.new(
          device_key: Keyword.get(overrides, :device_key, device_key),
          client_id: Keyword.get(overrides, :client_id, invitation.client_id),
          subject:
            Keyword.get(overrides, :subject, %{
              kind: :identity,
              identifier: identity.identifier,
              key_epoch: Sanctum.Test.DirectoryServer.key_epoch(identity)
            }),
          issuer: "https://a.example",
          audience: Keyword.get(overrides, :audience, Person.home()),
          athanor: Keyword.get(overrides, :athanor, athanor.id),
          not_before: Keyword.get(overrides, :not_before, now),
          expires_at: Keyword.get(overrides, :expires_at, now + 3_600_000)
        )

      DeviceCert.sign(certificate, Keyword.get(overrides, :live, elem(identity.live, 1)))
    end

    defp complete_remote(secret, {device_key, private}, certificate) do
      submission = %{device_key: device_key, certificate: certificate}

      with {:ok, %{challenge: challenge}} <- Pairing.complete(glass(), secret, submission) do
        Pairing.complete(
          glass(),
          secret,
          Map.put(submission, :proof, Proof.sign(challenge, private))
        )
      end
    end

    test "records the client under the reserved id with their home's certificate, bound to the current key epoch",
         %{identity: identity, invitation: invitation, user: user, athanor: athanor} do
      {device_key, _} = key = device_key()
      certificate = certified(identity, invitation, device_key, athanor)

      assert {:ok, %{client_id: client_id, certificate: ^certificate}} =
               complete_remote(invitation.invitation_secret, key, certificate)

      assert client_id == invitation.client_id
      assert [%{id: ^client_id}] = clients(user.id)

      assert [row] = Arca.Repo.all(from(c in DeviceCertificate, where: c.user_id == ^user.id))
      assert row.subject_kind == "identity"
      assert row.identifier == identity.identifier
      assert row.key_epoch == Sanctum.Test.DirectoryServer.key_epoch(identity)
      assert row.issuing_home == "https://a.example"
      assert invitation_row(invitation.invitation_secret).state == "consumed"
    end

    test "no certificate for a remote person, or one for a local person, is refused",
         %{identity: identity, invitation: invitation, user: user} do
      {device_key, _} = key = device_key()

      assert {:error, :certificate_required} =
               Pairing.complete(glass(), invitation.invitation_secret, %{device_key: device_key})

      assert {:error, :certificate_required} =
               Pairing.complete(glass(), invitation.invitation_secret, %{
                 device_key: device_key,
                 proof: %{}
               })

      local = seated!()
      {:ok, local_invitation} = begin!(local.session_ctx)
      certificate = certified(identity, local_invitation, device_key, local.athanor)

      assert {:error, :certificate_unexpected} =
               complete_remote(local_invitation.invitation_secret, key, certificate)

      assert clients(user.id) == []
      assert clients(local.user.id) == []
    end

    test "a certificate not bound exactly to this invitation, device, home and athanor is refused before issuance",
         %{
           directory: directory,
           identity: identity,
           invitation: invitation,
           user: user,
           athanor: athanor
         } do
      {device_key, _} = key = device_key()
      {other_device, _} = device_key()
      {_public, forger} = :crypto.generate_key(:eddsa, :ed25519)
      other = Sanctum.Test.DirectoryServer.identity!(directory.dir, directory.url)

      for overrides <- [
            [client_id: "pcl_another"],
            [device_key: other_device],
            [audience: "https://elsewhere.example"],
            [athanor: "ath_another"],
            [
              subject: %{
                kind: :identity,
                identifier: other.identifier,
                key_epoch: Sanctum.Test.DirectoryServer.key_epoch(other)
              }
            ],
            [live: forger],
            [
              not_before: System.os_time(:millisecond) - 7_200_000,
              expires_at: System.os_time(:millisecond) - 1
            ]
          ] do
        certificate = certified(identity, invitation, device_key, athanor, overrides)

        assert {:error, :certificate_refused} =
                 complete_remote(invitation.invitation_secret, key, certificate),
               inspect(overrides)
      end

      assert clients(user.id) == []
      assert invitation_row(invitation.invitation_secret).state == "pending"
    end

    test "a key rotation between the certificate and the pairing refuses it; the head is read live",
         %{directory: directory, identity: identity, invitation: invitation, user: user} = ctx do
      {device_key, _} = key = device_key()
      certificate = certified(identity, invitation, device_key, ctx.athanor)
      Sanctum.Test.DirectoryServer.rotate!(directory.dir, identity)

      assert {:error, :certificate_refused} =
               complete_remote(invitation.invitation_secret, key, certificate)

      assert clients(user.id) == []
    end

    test "a proof of possession under another key pairs nothing",
         %{identity: identity, invitation: invitation, user: user, athanor: athanor} do
      {device_key, _} = device_key()
      {_other, other_private} = device_key()
      certificate = certified(identity, invitation, device_key, athanor)

      assert {:error, :proof_refused} =
               complete_remote(
                 invitation.invitation_secret,
                 {device_key, other_private},
                 certificate
               )

      assert clients(user.id) == []
    end

    test "a directory that cannot be read pairs nothing",
         %{directory: directory, identity: identity, invitation: invitation, athanor: athanor} do
      {device_key, _} = key = device_key()
      certificate = certified(identity, invitation, device_key, athanor)
      Sanctum.Test.DirectoryServer.Server.stop(directory.server)

      assert {:error, :identity_stale} =
               complete_remote(invitation.invitation_secret, key, certificate)
    end
  end
end
