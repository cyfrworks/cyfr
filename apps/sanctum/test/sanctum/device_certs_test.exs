# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceCertsTest do
  @moduledoc """
  Device certificates as a backend checks them. A connect proof must be
  made by the certificate's device key over a challenge this home issued
  for that client; a renewal proof by the key the paired-client row
  stores, the certificate only locating it. On every request the
  certificate is held to the person's current live key, its expiry
  strictly on this home's clock, its not-before within the clock
  tolerance, and the paired client and its person's seat, read anew each
  time. An attempt that proves the key a client's row stores counts
  against that client's own budget; any other counts against its address
  and the installation, so a flood naming a client never spends the
  client's. Every member counts every bound.

  Every certificate here comes from the real ceremony
  (`Sanctum.Pairing.begin/2` under a session, `complete/3` from a glass
  holding nothing); a key is proved by what it signs.
  """

  # The rate limiter's table is the node's, the settings' cache is the
  # node's, and some cases change the home's name: one case at a time.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{PairedClient, PersonIdentity, RequestRateWindow}
  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Sanctum.{Context, DeviceCerts, Pairing, Person}
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @source "198.51.100.7"

  setup tags do
    Arca.Cache.init()
    Arca.Test.Sandbox.setup!(tags)
    Prima.RateLimiter.reset()

    public_url = Application.get_env(:sanctum, :public_url)

    on_exit(fn ->
      Prima.RateLimiter.reset()

      if public_url,
        do: Application.put_env(:sanctum, :public_url, public_url),
        else: Application.delete_env(:sanctum, :public_url)
    end)

    seated!()
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
        id: "github|https://github.com|devcert-#{n}",
        provider: "github",
        email: "devcert#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Devices #{n}")

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

    %{user: user, athanor: athanor, session_ctx: session_ctx}
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

  # A device paired through the ceremony: its key pair, its client and its
  # first certificate.
  defp pair!(session_ctx, source \\ @source) do
    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, invitation} = begin!(session_ctx)
    glass = Context.build(%{authenticated: false, client_ip: source})
    submission = %{device_key: device_key}

    {:ok, %{challenge: challenge}} =
      Pairing.complete(glass, invitation.invitation_secret, submission)

    {:ok, %{client_id: client_id, certificate: certificate}} =
      Pairing.complete(
        glass,
        invitation.invitation_secret,
        Map.put(submission, :proof, Proof.sign(challenge, private))
      )

    %{client_id: client_id, certificate: certificate, device_key: device_key, private: private}
  end

  # A challenge as the channel issues one for `device`, with `overrides`.
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

  defp connection(device, source \\ @source),
    do: %{client_id: device.client_id, certificate: device.certificate, source: source}

  defp connect(device, source \\ @source) do
    challenge = challenge(device, :connect)

    DeviceCerts.verify_connect(
      connection(device, source),
      Proof.sign(challenge, device.private),
      challenge
    )
  end

  # The renewal exchange's proof, by the device's key, from `source`.
  defp renew(device, source) do
    challenge = challenge(device, :renew)

    DeviceCerts.verify_connect(
      connection(device, source),
      Proof.sign(challenge, device.private),
      challenge
    )
  end

  # What anyone who has seen `device`'s certificate, which is not secret,
  # can make: one naming its client, athanor and person, for a device key
  # of the sender's own, signed by a key that is not the person's. A proof
  # by that key verifies; only the client's row tells it is not the
  # client's.
  defp forged(device) do
    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)
    {_live, live_private} = :crypto.generate_key(:eddsa, :ed25519)

    certificate =
      %{device.certificate | device_key: device_key}
      |> Map.put(:sig, nil)
      |> DeviceCert.sign(live_private)

    %{device | certificate: certificate, device_key: device_key, private: private}
  end

  # A forged certificate naming the client and its athanor, but a person
  # this home does not hold.
  defp stranger(device) do
    stranger = forged(device)
    {_live, live_private} = :crypto.generate_key(:eddsa, :ed25519)

    certificate =
      %{stranger.certificate | subject: %{kind: :local, user_id: Prima.UUID7.generate_id("usr")}}
      |> Map.put(:sig, nil)
      |> DeviceCert.sign(live_private)

    %{stranger | certificate: certificate}
  end

  # `n` requests counted in the cell's `bucket` for `key`, as members
  # before this one counted them.
  defp spend!(bucket, key, n, cap \\ 20) do
    for _ <- 1..n,
        do: :ok = Arca.RequestRateWindows.claim(Prima.Actor.system(), bucket, key, cap, 60_000)
  end

  # The person's live key replaced as a rotation activates one: a new pair,
  # its private half sealed to them as their live key.
  defp rotate_live_key!(user_id) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, sealed} = Sanctum.Cipher.encrypt(private, Sanctum.CipherAAD.person_key(user_id, :live))

    {1, _} =
      Arca.Repo.update_all(from(p in PersonIdentity, where: p.user_id == ^user_id),
        set: [live_public_key: public, live_key_sealed: sealed]
      )

    public
  end

  # What `Sanctum.DeviceCerts` hands establish once a device verified:
  # the certificate and the rows it read.
  defp device_credential(device) do
    certificate = device.certificate
    user_id = certificate.subject.user_id
    {:ok, client} = DeviceCerts.paired_client(certificate.athanor, user_id, device.client_id)
    {:ok, standing} = DeviceCerts.standing(user_id, certificate.athanor)

    %{
      certificate: certificate,
      client: client,
      user: standing.user,
      athanor: standing.athanor,
      seat: standing.seat,
      platform_admin: standing.platform_admin
    }
  end

  defp live_key(user_id), do: Arca.Repo.get_by!(PersonIdentity, user_id: user_id).live_public_key

  # The tables this process's statements read or write from here on.
  defp watch_sources! do
    handler = "device-certs-sources-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == parent and is_binary(meta[:source]),
            do: send(parent, {:source, meta[:source]})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp sources(acc \\ []) do
    receive do
      {:source, source} -> sources([source | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.uniq()
    end
  end

  defp window(bucket, key) do
    hash = Prima.Digest.sha256(key)

    Arca.Repo.one(
      from(w in RequestRateWindow,
        where: w.bucket == ^Atom.to_string(bucket) and w.key_hash == ^hash
      )
    )
  end

  # ---------------------------------------------------------------------------
  # A connect proof
  # ---------------------------------------------------------------------------

  describe "verify_connect/3 for a connect" do
    test "a proof by the certificate's key answers the client's context", %{
      session_ctx: session_ctx,
      user: user,
      athanor: athanor
    } do
      device = pair!(session_ctx)

      assert {:ok, %Context{} = ctx} = connect(device)
      assert ctx.auth_method == :device
      assert ctx.client_id == device.client_id
      assert {ctx.user_id, ctx.athanor_id} == {user.id, athanor.id}
      assert ctx.authenticated and not ctx.anonymous
      assert ctx.origin == :interactive
      assert ctx.plane == :external

      assert ctx.credential_deadline ==
               DateTime.from_unix!(device.certificate.expires_at, :millisecond)

      client_id = device.client_id

      assert %{source_kind: :device, source_id: ^client_id, focus_basis: basis, identity: nil} =
               ctx.credential_binding

      assert {:ok, %{athanor_id: athanor_id}} = Members.get(basis)
      assert athanor_id == athanor.id
    end

    test "a proof under a key the certificate does not name is refused", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      {_other, other_private} = :crypto.generate_key(:eddsa, :ed25519)
      challenge = challenge(device, :connect)

      assert DeviceCerts.verify_connect(
               connection(device),
               Proof.sign(challenge, other_private),
               challenge
             ) == {:error, :proof_refused}
    end

    test "a challenge not this home's, or not for this client, athanor or key, is refused", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      {other_key, _} = :crypto.generate_key(:eddsa, :ed25519)

      for overrides <- [
            [home: "https://elsewhere.example"],
            [client_id: "pcl_another"],
            [athanor: "ath_another"],
            [device_key: other_key]
          ] do
        challenge = challenge(device, :connect, overrides)

        assert DeviceCerts.verify_connect(
                 connection(device),
                 Proof.sign(challenge, device.private),
                 challenge
               ) == {:error, :proof_refused},
               inspect(overrides)
      end
    end

    test "a proof after its challenge expired is refused", %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      past = System.system_time(:millisecond) - Challenge.lifetime_ms() - 1
      challenge = challenge(device, :connect, now: past)

      assert DeviceCerts.verify_connect(
               connection(device),
               Proof.sign(challenge, device.private),
               challenge
             ) == {:error, :proof_refused}
    end

    test "a renewal proof is not a connect proof", %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      renewal = challenge(device, :renew)
      connect = %{renewal | purpose: :connect}

      assert DeviceCerts.verify_connect(
               connection(device),
               Proof.sign(renewal, device.private),
               connect
             ) == {:error, :proof_refused}
    end

    test "a failed proof no client's key made counts against the address, a verified connect against nothing",
         %{session_ctx: session_ctx} do
      device = pair!(session_ctx, "192.0.2.10")

      # Verified connects are no guesses: neither the address nor the
      # client spends anything.
      for _ <- 1..25, do: assert({:ok, _ctx} = connect(device, "192.0.2.20"))
      assert window(:device_connect_source, "192.0.2.20") == nil
      assert window(:device_connect_client, device.client_id) == nil

      {_other, other_private} = :crypto.generate_key(:eddsa, :ed25519)

      failed = fn ->
        challenge = challenge(device, :connect)

        DeviceCerts.verify_connect(
          connection(device, "192.0.2.30"),
          Proof.sign(challenge, other_private),
          challenge
        )
      end

      for _ <- 1..20, do: assert(failed.() == {:error, :proof_refused})
      assert %{count: 20} = window(:device_connect_source, "192.0.2.30")

      # The next is refused for the address before any signature, and
      # says when to retry.
      assert {:error, {:rate_limited, retry_after_ms}} = failed.()
      assert retry_after_ms in 1..60_000

      # None of it proved the client, so none of it is the client's.
      assert window(:device_connect_client, device.client_id) == nil

      # Bad connects spend nothing a completion or a renewal is held to.
      assert window(:device_verification_source, "192.0.2.30") == nil
      assert DeviceCerts.verification_room("192.0.2.30") == :ok
    end

    test "a flood naming a real client, from 200 addresses across two members, leaves its reconnect and renewal admitted",
         %{session_ctx: session_ctx} do
      device = pair!(session_ctx)

      # Each names the client, its athanor and its person with a key of
      # the sender's own, so its proof verifies and only the client's row
      # can tell it is not the client's.
      for n <- 1..200 do
        # Half the sources reach one member, half another.
        if n == 101, do: Prima.RateLimiter.reset()
        source = "10.4.#{div(n, 250)}.#{rem(n, 250)}"
        # Each answered the word its certificate always got.
        assert connect(forged(device), source) == {:error, :bad_signature}
        assert renew(forged(device), source) == {:error, :proof_refused}
      end

      # The installation's ceiling holds for what no client proved: the
      # next from a fresh address is refused, on either member.
      assert {:error, {:rate_limited, _}} = connect(forged(device), "10.5.0.1")
      Prima.RateLimiter.reset()
      assert {:error, {:rate_limited, _}} = connect(forged(device), "10.5.0.2")
      assert {:error, {:rate_limited, _}} = renew(forged(device), "10.5.0.2")
      assert %{count: 200} = window(:device_connect_installation, "installation")
      assert %{count: 200} = window(:device_verification_installation, "installation")

      # Named 400 times, the client spent nothing of its own.
      assert window(:device_connect_client, device.client_id) == nil
      assert window(:device_verification_client, device.client_id) == nil

      # And proving itself from its own address, it reconnects and renews.
      assert {:ok, %Context{client_id: client_id}} = connect(device, "10.6.0.1")
      assert client_id == device.client_id
      assert {:ok, %Context{client_id: ^client_id}} = renew(device, "10.6.0.1")
      assert %{count: 1} = window(:device_verification_client, device.client_id)
      assert window(:device_connect_client, device.client_id) == nil
    end

    test "a client past its own budget of failures is refused with its retry bound, before its certificate is checked",
         %{session_ctx: session_ctx, user: user} do
      device = pair!(session_ctx)
      keys = Arca.Repo.get_by!(PersonIdentity, user_id: user.id)
      rotate_live_key!(user.id)

      # The device proves its key, but its certificate is chained to a
      # rotated key: its own failures, from addresses that spend nothing.
      for n <- 1..20 do
        assert {:error, :bad_signature} = connect(device, "192.0.2.#{100 + n}")
      end

      assert %{count: 20} = window(:device_connect_client, device.client_id)
      assert window(:device_connect_source, "192.0.2.101") == nil

      # Its certificate stands again; its own budget is spent, on this
      # member and in the cell.
      {1, _} =
        Arca.Repo.update_all(from(p in PersonIdentity, where: p.user_id == ^user.id),
          set: [live_public_key: keys.live_public_key, live_key_sealed: keys.live_key_sealed]
        )

      watch_sources!()
      assert {:error, {:device_rate_limited, retry_after_ms}} = connect(device, "192.0.2.150")
      assert retry_after_ms in 1..60_000

      # Refused before its certificate: the person's key was never read.
      refute "person_identities" in sources()

      Prima.RateLimiter.reset()
      assert {:error, {:device_rate_limited, retry_after_ms}} = connect(device, "192.0.2.151")
      assert retry_after_ms in 1..60_000
      assert %{count: 20} = window(:device_connect_client, device.client_id)

      # Another client of the same person has its own.
      other = pair!(session_ctx)
      assert {:ok, _ctx} = connect(other, "192.0.2.152")
    end
  end

  # ---------------------------------------------------------------------------
  # A connect's bounds, read before any signature
  # ---------------------------------------------------------------------------

  describe "the connect pre-check" do
    test "a spent address bound refuses the next connect before any signature is checked", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      source = "192.0.2.50"
      spend!(:device_connect_source, source, 20)

      # This member's own count forgotten, as another member's would be:
      # the cell's is what refuses.
      Prima.RateLimiter.reset()
      {_other, other_private} = :crypto.generate_key(:eddsa, :ed25519)
      watch_sources!()

      # A valid proof and certificate, and a proof no key of the device
      # made: both refused for the bound, so neither was verified. A proof
      # checked first would have answered `:proof_refused`.
      for private <- [device.private, other_private] do
        challenge = challenge(device, :connect)

        assert {:error, {:rate_limited, retry_after_ms}} =
                 DeviceCerts.verify_connect(
                   connection(device, source),
                   Proof.sign(challenge, private),
                   challenge
                 )

        assert retry_after_ms > 0 and retry_after_ms <= 60_000
      end

      # Only the bound was read: never the person's key, which the
      # certificate's signature is checked under, nor the client's row.
      assert sources() -- ["request_rate_windows"] == []

      # And the refusals counted nothing.
      assert %{count: 20} = window(:device_connect_source, source)

      # Another source has room, and connects as ever.
      assert {:ok, _ctx} = connect(device, "192.0.2.51")
    end

    test "this member's spent count refuses before the database is asked", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      source = "192.0.2.60"

      for _ <- 1..20,
          do: :ok = Prima.RateLimiter.check({:device_connect, :source, source}, 20, 60_000)

      watch_sources!()
      challenge = challenge(device, :connect)

      assert {:error, {:rate_limited, _}} =
               DeviceCerts.verify_connect(
                 connection(device, source),
                 Proof.sign(challenge, device.private),
                 challenge
               )

      assert sources() == []
      assert window(:device_connect_source, source) == nil
    end

    test "a connect no client's row stands behind is counted before its certificate is checked: past the installation's bound no key is read",
         %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      spend!(:device_connect_installation, "installation", 200, 200)
      watch_sources!()

      assert {:error, {:rate_limited, retry_after_ms}} = connect(forged(device), "192.0.2.65")
      assert retry_after_ms in 1..60_000

      # The address's window, the client's row, and the counts; never the
      # person's key, nor anything the certificate's subject would lead to.
      assert Enum.sort(sources()) == ["paired_clients", "request_rate_windows"]

      # The client proving itself is not held to that bound.
      assert {:ok, _ctx} = connect(device, "192.0.2.66")
    end

    test "a connect no client's row stands behind answers the word every connect always got",
         %{session_ctx: session_ctx, user: user, athanor: athanor} do
      device = pair!(session_ctx)

      # Signed by the person's own key for the client, but for a device
      # key the client's row does not store.
      {other_key, other_private} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, misnamed} =
        Person.issue_device_cert(user.id, other_key, device.client_id, %{
          subject: :local,
          audience: Person.home(),
          athanor: athanor.id
        })

      misnamed = %{device | certificate: misnamed, device_key: other_key, private: other_private}
      assert connect(misnamed, "192.0.2.70") == {:error, :client_mismatch}

      # Not signed by the person's key: the certificate's own word.
      assert connect(forged(device), "192.0.2.71") == {:error, :bad_signature}

      # Naming a person this home does not hold.
      assert connect(stranger(device), "192.0.2.72") == {:error, :unknown_subject}

      # Each was no one's: the address and the installation counted it,
      # and the client's own budget not at all.
      assert %{count: 1} = window(:device_connect_source, "192.0.2.70")
      assert %{count: 3} = window(:device_connect_installation, "installation")
      assert window(:device_connect_client, device.client_id) == nil

      # A verified certificate whose client is gone, after a restore for
      # instance, is told its standing ended, so the glass pairs again.
      {1, _} =
        Arca.Repo.delete_all(from(c in PairedClient, where: c.id == ^device.client_id))

      assert connect(device, "192.0.2.73") == {:error, :not_standing}

      # And one revoked, signed for another key: revoked, as ever.
      other = pair!(session_ctx)
      {:ok, _row} = revoke!(session_ctx, other.client_id)

      {:ok, renamed} =
        Person.issue_device_cert(user.id, other_key, other.client_id, %{
          subject: :local,
          audience: Person.home(),
          athanor: athanor.id
        })

      renamed = %{other | certificate: renamed, device_key: other_key, private: other_private}
      assert connect(renamed, "192.0.2.74") == {:error, :revoked}
      assert window(:device_connect_client, other.client_id) == nil
    end

    test "a revocation committed while the certificate is checked is seen by the connect",
         %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      parent = self()
      client_id = device.client_id
      handler = "device-certs-revoke-#{System.unique_integer([:positive])}"

      # The client's row is revoked the moment the person's key is read,
      # after the row was read to attribute the connect.
      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == parent and meta[:source] == "person_identities" and
                 Process.get(:revoke_armed) do
              Process.delete(:revoke_armed)

              {1, _} =
                Arca.Repo.update_all(from(c in PairedClient, where: c.id == ^client_id),
                  set: [standing: "revoked"]
                )

              send(parent, :revoked_meanwhile)
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      Process.put(:revoke_armed, true)
      result = connect(device, "192.0.2.75")
      assert_received :revoked_meanwhile
      assert result == {:error, :revoked}
    end
  end

  # ---------------------------------------------------------------------------
  # A renewal proof
  # ---------------------------------------------------------------------------

  describe "verify_connect/3 for a renewal" do
    test "a proof by the stored key answers the client's context, the certificate only a locator",
         %{session_ctx: session_ctx, user: user} do
      device = pair!(session_ctx)

      # The certificate no longer verifies: the live key rotated.
      rotate_live_key!(user.id)
      assert {:error, :bad_signature} = connect(device)

      challenge = challenge(device, :renew)

      assert {:ok, %Context{auth_method: :device} = ctx} =
               DeviceCerts.verify_connect(
                 connection(device),
                 Proof.sign(challenge, device.private),
                 challenge
               )

      assert ctx.client_id == device.client_id
      assert ctx.user_id == user.id
    end

    test "a locator naming another device key is refused: the row's key must have signed", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      {other_key, other_private} = :crypto.generate_key(:eddsa, :ed25519)
      challenge = challenge(device, :renew, device_key: other_key)

      assert DeviceCerts.verify_connect(
               connection(device),
               Proof.sign(challenge, other_private),
               challenge
             ) == {:error, :proof_refused}
    end

    test "a connect proof is not a renewal proof", %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      connect = challenge(device, :connect)
      renewal = %{connect | purpose: :renew}

      assert DeviceCerts.verify_connect(
               connection(device),
               Proof.sign(connect, device.private),
               renewal
             ) == {:error, :proof_refused}
    end

    test "a revoked client renews nothing", %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      {:ok, _row} = revoke!(session_ctx, device.client_id)
      challenge = challenge(device, :renew)

      assert DeviceCerts.verify_connect(
               connection(device),
               Proof.sign(challenge, device.private),
               challenge
             ) == {:error, :revoked}
    end

    test "a renewal counts against its client's own budget, never the address's, and past it is refused with its retry bound",
         %{session_ctx: session_ctx, user: user} do
      device = pair!(session_ctx, "192.0.2.40")

      for _ <- 1..20, do: assert({:ok, _ctx} = renew(device, "192.0.2.41"))
      assert %{count: 20} = window(:device_verification_client, device.client_id)
      assert window(:device_verification_source, "192.0.2.41") == nil

      # From any address, on this member and in the cell.
      assert {:error, {:device_rate_limited, retry_after_ms}} = renew(device, "192.0.2.42")
      assert retry_after_ms in 1..60_000
      Prima.RateLimiter.reset()
      assert {:error, {:device_rate_limited, retry_after_ms}} = renew(device, "192.0.2.43")
      assert retry_after_ms in 1..60_000
      assert %{count: 20} = window(:device_verification_client, device.client_id)

      # Counted before anything past the client's row is read: the
      # person's key and standing were not.
      watch_sources!()
      assert {:error, {:device_rate_limited, _}} = renew(device, "192.0.2.44")
      refute Enum.any?(sources(), &(&1 in ["person_identities", "users", "athanors"]))

      # Another of the person's clients renews on its own budget.
      other = pair!(session_ctx)
      assert {:ok, %Context{user_id: user_id}} = renew(other, "192.0.2.45")
      assert user_id == user.id
    end
  end

  # ---------------------------------------------------------------------------
  # Every request
  # ---------------------------------------------------------------------------

  describe "verify_request/3" do
    test "takes only a device context a proof produced: a certificate alone verifies nothing", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      {:ok, ctx} = connect(device)

      # The reviewer's demonstration: a certificate, which is not secret,
      # and the client id it names, with no proof, answered a context.
      assert DeviceCerts.verify_request(device.certificate, %{client_id: device.client_id}, []) ==
               {:error, :client_mismatch}

      # Nor does any context but a device context a proof produced.
      for other <- [
            session_ctx,
            %{session_ctx | client_id: device.client_id},
            %{ctx | authenticated: false},
            %{ctx | auth_method: :oidc}
          ] do
        assert DeviceCerts.verify_request(device.certificate, other, []) ==
                 {:error, :client_mismatch}
      end

      # A device context verifies the certificate it was established
      # under, and no other of the same client.
      assert {:ok, _ctx} = DeviceCerts.verify_request(device.certificate, ctx, [])
      later = %{ctx | credential_deadline: DateTime.add(ctx.credential_deadline, 1, :second)}

      assert DeviceCerts.verify_request(device.certificate, later, []) ==
               {:error, :client_mismatch}
    end

    test "expiry is strict on this home's clock: at it, within the tolerance and past it", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      {:ok, ctx} = connect(device)
      expires_at = device.certificate.expires_at

      assert {:ok, _ctx} =
               DeviceCerts.verify_request(device.certificate, ctx, now: expires_at - 1)

      for now <- [expires_at, expires_at + 30_000, expires_at + 120_000] do
        assert DeviceCerts.verify_request(device.certificate, ctx, now: now) == {:error, :expired},
               "now = expires_at + #{now - expires_at} ms"
      end
    end

    test "not-before takes the clock tolerance: inside it accepted, beyond it refused", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      {:ok, ctx} = connect(device)
      not_before = device.certificate.not_before

      # This home's clock 30 s behind the issuer's, inside the 60 s tolerance.
      assert {:ok, _ctx} =
               DeviceCerts.verify_request(device.certificate, ctx, now: not_before - 30_000)

      # 120 s behind, beyond it.
      assert DeviceCerts.verify_request(device.certificate, ctx, now: not_before - 120_000) ==
               {:error, :not_yet_valid}
    end

    test "a certificate chained to a key the person's row no longer names is refused", %{
      session_ctx: session_ctx,
      user: user
    } do
      device = pair!(session_ctx)
      {:ok, ctx} = connect(device)
      before = live_key(user.id)
      rotate_live_key!(user.id)
      refute live_key(user.id) == before

      assert DeviceCerts.verify_request(device.certificate, ctx, []) == {:error, :bad_signature}
    end

    test "a certificate for another home is refused", %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      {:ok, ctx} = connect(device)
      Application.put_env(:sanctum, :public_url, "https://elsewhere.example")
      refute Person.home() == device.certificate.audience

      assert DeviceCerts.verify_request(device.certificate, ctx, []) == {:error, :wrong_audience}
    end

    test "the key is read from the certificate's own subject, never the connection's claim", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      other = seated!()
      {:ok, ctx} = connect(device)
      {_key, forged_private} = :crypto.generate_key(:eddsa, :ed25519)

      # The person's own certificate, signed by no key of theirs.
      forged = device.certificate |> Map.put(:sig, nil) |> DeviceCert.sign(forged_private)
      assert DeviceCerts.verify_request(forged, ctx, []) == {:error, :bad_signature}

      # At connect: a certificate naming another person, and one naming a
      # subject no person of this home holds keys for, each proven by the
      # device key it names.
      for {subject, refused} <- [
            {other.user.id, :bad_signature},
            {Prima.UUID7.generate_id("usr"), :unknown_subject}
          ] do
        certificate =
          %{device.certificate | subject: %{kind: :local, user_id: subject}}
          |> Map.put(:sig, nil)
          |> DeviceCert.sign(forged_private)

        challenge = challenge(%{device | certificate: certificate}, :connect)

        assert DeviceCerts.verify_connect(
                 %{client_id: device.client_id, certificate: certificate, source: @source},
                 Proof.sign(challenge, device.private),
                 challenge
               ) == {:error, refused}
      end
    end

    test "the certificate must name the client, athanor and person the context stands for", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      second = pair!(session_ctx)
      {:ok, ctx} = connect(device)

      # The second device's certificate under the first one's context.
      assert DeviceCerts.verify_request(second.certificate, ctx, []) == {:error, :client_mismatch}

      assert DeviceCerts.verify_request(device.certificate, %{ctx | athanor_id: "ath_other"}, []) ==
               {:error, :client_mismatch}

      assert DeviceCerts.verify_request(device.certificate, %{ctx | user_id: "usr_other"}, []) ==
               {:error, :client_mismatch}
    end

    test "an identity subject naming no person this home admitted from another home is refused",
         %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      {_key, private} = :crypto.generate_key(:eddsa, :ed25519)

      remote =
        %{
          device.certificate
          | subject: %{
              kind: :identity,
              identifier: "per_" <> String.duplicate("ab", 32),
              key_epoch: "sha256:" <> String.duplicate("cd", 32)
            }
        }
        |> Map.put(:sig, nil)
        |> DeviceCert.sign(private)

      challenge = challenge(%{device | certificate: remote}, :connect)

      assert DeviceCerts.verify_connect(
               %{client_id: device.client_id, certificate: remote, source: @source},
               Proof.sign(challenge, device.private),
               challenge
             ) == {:error, :unknown_subject}
    end

    test "standing is read anew on every request: revoked, denied, left and archived", %{
      session_ctx: session_ctx,
      user: user,
      athanor: athanor
    } do
      # Revoked: the pairing's own end.
      revoked = pair!(session_ctx)
      {:ok, ctx} = connect(revoked)
      assert {:ok, _} = DeviceCerts.verify_request(revoked.certificate, ctx, [])
      {:ok, _row} = revoke!(session_ctx, revoked.client_id)
      assert DeviceCerts.verify_request(revoked.certificate, ctx, []) == {:error, :revoked}

      # Left: a second member keeps the group open while the person leaves,
      # and the leave revokes the client they paired there with the seat.
      left = pair!(session_ctx)
      {:ok, ctx} = connect(left)
      other = seated!()
      {:ok, _} = Members.ensure(other.user.id, scope: "athanor", athanor_id: athanor.id)
      :ok = Members.remove_member(athanor, user_id: user.id)
      assert DeviceCerts.verify_request(left.certificate, ctx, []) == {:error, :revoked}
      assert DeviceCerts.client_standing(ctx) == {:error, :revoked}
    end

    test "a denied person's device stands for nothing", %{session_ctx: session_ctx, user: user} do
      device = pair!(session_ctx)
      {:ok, ctx} = connect(device)
      {:ok, _} = Users.deny(user)

      assert {:error, reason} = DeviceCerts.verify_request(device.certificate, ctx, [])
      assert reason in [:revoked, :not_standing]
      assert {:error, _} = DeviceCerts.client_standing(ctx)
    end

    test "an archived athanor's devices stand for nothing", %{
      session_ctx: session_ctx,
      athanor: athanor
    } do
      device = pair!(session_ctx)
      {:ok, ctx} = connect(device)
      {:ok, _} = Athanors.archive(athanor)

      assert {:error, reason} = DeviceCerts.verify_request(device.certificate, ctx, [])
      assert reason in [:revoked, :not_standing]
    end

    test "a verified request answers the client's context, validated now", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      {:ok, ctx} = connect(device)
      stale = %{ctx | validated_at: ~U[2020-01-01 00:00:00Z], request_id: "req_held"}

      assert {:ok, fresh} = DeviceCerts.verify_request(device.certificate, stale, [])
      assert DateTime.compare(fresh.validated_at, stale.validated_at) == :gt
      assert fresh.client_id == device.client_id
      assert fresh.request_id == "req_held"
    end
  end

  # ---------------------------------------------------------------------------
  # Where the context is built
  # ---------------------------------------------------------------------------

  describe "Sanctum.Caller.establish_device/2" do
    test "builds the verified device's interactive context, with the connection's correlation", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      credential = device_credential(device)

      assert {:ok, %Context{} = ctx} =
               Sanctum.Caller.establish_device(credential,
                 request_id: "req_device",
                 client_ip: @source
               )

      assert {ctx.auth_method, ctx.client_id, ctx.origin} ==
               {:device, device.client_id, :interactive}

      assert {ctx.request_id, ctx.client_ip} == {"req_device", @source}
      assert ctx.authenticated and ctx.plane == :external
      assert %DateTime{} = ctx.validated_at

      assert ctx.credential_deadline ==
               DateTime.from_unix!(device.certificate.expires_at, :millisecond)

      # A renewal's context: no certificate, so no deadline of its own.
      assert {:ok, renewal} =
               Sanctum.Caller.establish_device(%{credential | certificate: nil}, [])

      assert renewal.credential_deadline == nil

      # The verifier's contexts are these.
      assert {:ok, verified} = connect(device)

      assert Map.take(verified, [:user_id, :athanor_id, :client_id, :auth_method, :origin]) ==
               Map.take(ctx, [:user_id, :athanor_id, :client_id, :auth_method, :origin])
    end

    test "refuses rows that disagree with each other", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      other = pair!(session_ctx)
      credential = device_credential(device)
      stranger = seated!()
      {other_key, _} = :crypto.generate_key(:eddsa, :ed25519)

      for {what, changed} <- [
            revoked_client: put_in(credential.client.standing, "revoked"),
            not_a_device: put_in(credential.client.source_kind, "session"),
            another_clients_certificate: %{credential | certificate: other.certificate},
            another_key: put_in(credential.certificate.device_key, other_key),
            denied_person: put_in(credential.user.status, "denied"),
            another_person: %{credential | user: stranger.user},
            archived_athanor: put_in(credential.athanor.status, "archived"),
            another_athanor: %{credential | athanor: stranger.athanor},
            another_seat: %{
              credential
              | seat: %{credential.seat | athanor_id: stranger.athanor.id}
            },
            ended_seat: put_in(credential.seat.status, "removed"),
            an_identity_row_on_a_local_certificate:
              Map.put(credential, :identity, %{
                user_id: credential.client.user_id,
                provenance: "remote",
                identifier: "per_" <> Prima.Digest.sha256_hex("local-#{System.unique_integer()}")
              })
          ] do
        assert Sanctum.Caller.establish_device(changed, []) == {:error, :unauthenticated},
               inspect(what)
      end
    end
  end

  describe "establish/2" do
    test "takes no device credential: the device branch is establish_device/2's alone", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)

      # Called as a Host module would, through `apply/3`, since no
      # clause of `establish/2` takes it and the compiler says so.
      assert_raise FunctionClauseError, fn ->
        apply(Sanctum.Caller, :establish, [{:device, device_credential(device)}])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Revalidation
  # ---------------------------------------------------------------------------

  describe "revalidating a device context" do
    test "answers it validated again while its client stands", %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      {:ok, ctx} = connect(device)
      stale = %{ctx | validated_at: ~U[2020-01-01 00:00:00Z]}

      assert {:ok, fresh} = Sanctum.Caller.revalidate_session(stale)
      assert fresh.client_id == device.client_id
      assert DateTime.compare(fresh.validated_at, stale.validated_at) == :gt
    end

    test "refuses it once the client is revoked, and as expired past its certificate", %{
      session_ctx: session_ctx,
      user: user
    } do
      device = pair!(session_ctx)
      {:ok, ctx} = connect(device)

      expired = %{ctx | credential_deadline: DateTime.add(DateTime.utc_now(), -1, :second)}
      assert Sanctum.Caller.revalidate_session(expired) == {:error, :unauthenticated}

      {:ok, _row} = revoke!(session_ctx, device.client_id)
      assert Sanctum.Caller.revalidate_session(ctx) == {:error, :not_standing}

      # And a denied person's.
      other = pair!(session_ctx)
      {:ok, other_ctx} = connect(other)
      {:ok, _} = Users.deny(user)
      assert Sanctum.Caller.revalidate_session(other_ctx) == {:error, :not_standing}
    end

    test "an OAuth grant a device started is refused at its recheck once the device is revoked",
         %{session_ctx: session_ctx} do
      # A provider with no preset names its endpoints, here a token URL
      # nothing answers.
      entering =
        Sanctum.TestContext.confirmed(session_ctx, :credential_entry, %{
          operation: "oauth.set_client",
          arguments: %{provider: "acme-mail", client_id: "cid", client_secret: "csec"},
          resource: "acme-mail"
        })

      :ok = Sanctum.ProviderCredentials.put(entering, "acme-mail", "cid", "csec")

      # Starting a grant enters a credential: each under the confirmation
      # the device's person proved.
      grant = fn ctx ->
        name = "Mail #{System.unique_integer([:positive])}"

        params = %{
          name: name,
          provider: "acme-mail",
          scopes: ["mail"],
          endpoints: %{
            "authorize_url" => "https://acme-mail.example/authorize",
            "token_url" => "https://127.0.0.1:9/token"
          },
          destination: %{"hosts" => ["mail.acme-mail.example"]}
        }

        confirmed =
          Sanctum.TestContext.confirmed(ctx, :credential_entry, %{
            operation: "vault.authorize",
            arguments: params,
            resource: name
          })

        {:ok, started} = Sanctum.Vault.OAuthGrant.authorize_url(confirmed, params)
        started
      end

      # A device that still stands gets past the recheck, as far as the
      # provider, which nothing answers here.
      standing = pair!(session_ctx)
      {:ok, standing_ctx} = connect(standing)
      started = grant.(standing_ctx)

      assert {:error, reason} =
               Sanctum.Vault.OAuthGrant.complete(started.state, "code", started.redirect_uri)

      refute reason in [:unauthenticated, :unavailable]

      # The reviewer's demonstration: `vault.authorize` started under a
      # device, the device revoked, then the callback. The recheck refuses
      # before the provider is asked, and nothing is sealed.
      revoked = pair!(session_ctx)
      {:ok, revoked_ctx} = connect(revoked)
      started = grant.(revoked_ctx)
      {:ok, _row} = revoke!(session_ctx, revoked.client_id)

      assert Sanctum.Vault.OAuthGrant.complete(started.state, "code", started.redirect_uri) ==
               {:error, :unauthenticated}

      # And a device whose certificate expired since.
      expiring = pair!(session_ctx)
      {:ok, expiring_ctx} = connect(expiring)

      started =
        grant.(%{
          expiring_ctx
          | credential_deadline: DateTime.add(DateTime.utc_now(), 1, :second)
        })

      Process.sleep(1_100)

      assert Sanctum.Vault.OAuthGrant.complete(started.state, "code", started.redirect_uri) ==
               {:error, :unauthenticated}

      assert Arca.Repo.all(
               from(v in Arca.Schemas.VaultEntry, where: v.athanor_id == ^session_ctx.athanor_id)
             ) == []
    end
  end

  describe "client_standing/1" do
    test "a device context's client stands while it and its person do", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      {:ok, ctx} = connect(device)

      assert DeviceCerts.client_standing(ctx) == :ok

      # Its certificate's deadline passed.
      past = %{ctx | credential_deadline: DateTime.add(DateTime.utc_now(), -1, :second)}
      assert DeviceCerts.client_standing(past) == {:error, :not_standing}

      # A context of any other kind stands for no paired client.
      assert DeviceCerts.client_standing(session_ctx) == {:error, :not_standing}

      {:ok, _} = revoke!(session_ctx, device.client_id)
      assert DeviceCerts.client_standing(ctx) == {:error, :revoked}
    end
  end

  # ---------------------------------------------------------------------------
  # Issuing for another home
  # ---------------------------------------------------------------------------

  describe "a certificate for another home" do
    test "needs an enrolled identifier: an unenrolled person is refused", %{user: user} do
      {device_key, _} = :crypto.generate_key(:eddsa, :ed25519)

      assert Person.issue_device_cert(user.id, device_key, "pcl_remote", %{
               subject: :identity,
               audience: "https://hub.example",
               athanor: "ath_remote"
             }) == {:error, :not_enrolled}
    end
  end

  # ---------------------------------------------------------------------------
  # The verification bounds
  # ---------------------------------------------------------------------------

  describe "refuse_unattributed/2" do
    test "20 a minute from one source, and another source is not charged for it" do
      for _ <- 1..20 do
        assert DeviceCerts.refuse_unattributed("203.0.113.1", :invalid_invitation) ==
                 {:error, :invalid_invitation}
      end

      assert {:error, {:rate_limited, retry_after_ms}} =
               DeviceCerts.refuse_unattributed("203.0.113.1", :invalid_invitation)

      assert retry_after_ms in 1..60_000

      assert DeviceCerts.refuse_unattributed("203.0.113.2", :invalid_invitation) ==
               {:error, :invalid_invitation}

      # In the completion and renewal buckets alone.
      assert window(:device_connect_source, "203.0.113.1") == nil
    end

    test "the cell's count holds for a member whose own count is fresh" do
      for _ <- 1..20,
          do: {:error, :refused} = DeviceCerts.refuse_unattributed("203.0.113.3", :refused)

      # Another member: its node count starts empty, the cell's does not.
      Prima.RateLimiter.reset()

      assert {:error, {:rate_limited, _}} =
               DeviceCerts.refuse_unattributed("203.0.113.3", :refused)
    end

    test "a flood past the node's bound reaches no database write" do
      for _ <- 1..20,
          do: {:error, :refused} = DeviceCerts.refuse_unattributed("203.0.113.4", :refused)

      assert %{count: 20} = window(:device_verification_source, "203.0.113.4")
      watch_sources!()

      for _ <- 1..50 do
        assert {:error, {:rate_limited, _}} =
                 DeviceCerts.refuse_unattributed("203.0.113.4", :refused)
      end

      assert sources() == []
      assert %{count: 20} = window(:device_verification_source, "203.0.113.4")
    end

    test "the installation's bound holds across many sources and two members: the 201st is refused" do
      for n <- 1..200 do
        # Half the sources reach one member, half another.
        if n == 101, do: Prima.RateLimiter.reset()
        source = "10.1.#{div(n, 250)}.#{rem(n, 250)}"
        assert DeviceCerts.refuse_unattributed(source, :refused) == {:error, :refused}
      end

      assert {:error, {:rate_limited, retry_after_ms}} =
               DeviceCerts.refuse_unattributed("10.9.9.8", :refused)

      assert retry_after_ms in 1..60_000
      Prima.RateLimiter.reset()

      assert {:error, {:rate_limited, _}} =
               DeviceCerts.refuse_unattributed("10.9.9.9", :refused)

      assert %{count: 200} = window(:device_verification_installation, "installation")
    end

    test "past this member's installation count, a flood from fresh addresses writes nothing" do
      for n <- 1..200 do
        source = "10.2.#{div(n, 250)}.#{rem(n, 250)}"
        assert DeviceCerts.refuse_unattributed(source, :refused) == {:error, :refused}
      end

      watch_sources!()

      for n <- 1..20 do
        assert {:error, {:rate_limited, _}} =
                 DeviceCerts.refuse_unattributed("10.3.0.#{n}", :refused)
      end

      assert sources() == []
    end

    test "a source the ingress did not know is charged to one shared bucket" do
      for _ <- 1..20, do: {:error, :refused} = DeviceCerts.refuse_unattributed(nil, :refused)
      assert {:error, {:rate_limited, _}} = DeviceCerts.refuse_unattributed(nil, :refused)
      assert window(:device_verification_source, "unknown")
      assert {:error, {:rate_limited, _}} = DeviceCerts.verification_room(nil)
    end
  end

  describe "claim_attributed/1" do
    test "20 a minute per name, never the address's or the installation's, and a spent name refuses with its retry" do
      for _ <- 1..20, do: assert(DeviceCerts.claim_attributed({:person, "usr_one"}) == :ok)
      assert %{count: 20} = window(:device_verification_person, "usr_one")

      assert {:error, {:rate_limited, retry_after_ms}} =
               DeviceCerts.claim_attributed({:person, "usr_one"})

      assert retry_after_ms in 1..60_000

      # Another member reads the cell's count.
      Prima.RateLimiter.reset()
      assert {:error, {:rate_limited, _}} = DeviceCerts.claim_attributed({:person, "usr_one"})

      # Another name, and a client of the same spelling, have their own.
      assert DeviceCerts.claim_attributed({:person, "usr_two"}) == :ok
      assert DeviceCerts.claim_attributed({:client, "usr_one"}) == :ok

      assert window(:device_verification_installation, "installation") == nil
      assert window(:device_verification_source, "unknown") == nil
    end
  end

  describe "verification_room/2" do
    test "reads and never counts; on this node alone it reads no database" do
      source = "192.0.2.70"
      for _ <- 1..5, do: assert(DeviceCerts.verification_room(source) == :ok)
      assert window(:device_verification_source, source) == nil

      for _ <- 1..19, do: {:error, :refused} = DeviceCerts.refuse_unattributed(source, :refused)
      assert DeviceCerts.verification_room(source) == :ok
      assert %{count: 19} = window(:device_verification_source, source)

      {:error, :refused} = DeviceCerts.refuse_unattributed(source, :refused)
      assert {:error, {:rate_limited, _}} = DeviceCerts.verification_room(source)
      assert {:error, {:rate_limited, _}} = DeviceCerts.verification_room(source, :node)
      assert %{count: 20} = window(:device_verification_source, source)

      # Another member: this node's own read has room and asks no database;
      # the cell's read refuses.
      Prima.RateLimiter.reset()
      watch_sources!()
      assert DeviceCerts.verification_room(source, :node) == :ok
      assert sources() == []
      assert {:error, {:rate_limited, _}} = DeviceCerts.verification_room(source)
    end
  end

  # ---------------------------------------------------------------------------
  # A remote person's device
  # ---------------------------------------------------------------------------

  describe "a device of a person whose keys are at another home" do
    setup %{session_ctx: session_ctx, user: user, athanor: athanor} do
      alias Sanctum.Test.DirectoryServer

      tls = DirectoryServer.tls()
      DirectoryServer.listen!()
      DirectoryServer.seam!(tls)

      on_exit(fn ->
        Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
      end)

      directory = DirectoryServer.start!(tls)
      identity = DirectoryServer.identity!(directory.dir, directory.url)

      # Paired at this home under their home's certificate: the invitation
      # opened under the person's proof here, then they are remote.
      {:ok, invitation} = begin!(session_ctx)
      :ok = DirectoryServer.remote_person!(user.id, identity)
      {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)
      certificate = remote_certificate(identity, invitation.client_id, device_key, athanor)
      glass = Context.build(%{authenticated: false, client_ip: @source})
      submission = %{device_key: device_key, certificate: certificate}

      {:ok, %{challenge: challenge}} =
        Pairing.complete(glass, invitation.invitation_secret, submission)

      {:ok, %{client_id: client_id}} =
        Pairing.complete(
          glass,
          invitation.invitation_secret,
          Map.put(submission, :proof, Proof.sign(challenge, private))
        )

      device = %{
        client_id: client_id,
        certificate: certificate,
        device_key: device_key,
        private: private
      }

      %{directory: directory, identity: identity, device: device}
    end

    defp remote_certificate(identity, client_id, device_key, athanor) do
      now = System.os_time(:millisecond)

      {:ok, certificate} =
        DeviceCert.new(
          device_key: device_key,
          client_id: client_id,
          subject: %{
            kind: :identity,
            identifier: identity.identifier,
            key_epoch: Sanctum.Test.DirectoryServer.key_epoch(identity)
          },
          issuer: "https://a.example",
          audience: Person.home(),
          athanor: athanor.id,
          not_before: now,
          expires_at: now + 3_600_000
        )

      DeviceCert.sign(certificate, elem(identity.live, 1))
    end

    defp remote_connect(device) do
      challenge = challenge(device, :connect)

      DeviceCerts.verify_connect(
        %{client_id: device.client_id, certificate: device.certificate, source: @source},
        Proof.sign(challenge, device.private),
        challenge
      )
    end

    test "connects under their home's certificate, checked against their head; this home never calls their home",
         %{device: device, user: user} do
      assert {:ok, %Context{auth_method: :device, user_id: user_id} = ctx} =
               remote_connect(device)

      assert user_id == user.id

      assert {:ok, %Context{client_id: client_id}} =
               DeviceCerts.verify_request(device.certificate, ctx, [])

      assert client_id == device.client_id

      # Only the directory was asked, never `https://a.example`.
      refute Enum.any?(Sanctum.Test.DirectoryServer.requests(), &(&1.target =~ "a.example"))
    end

    test "a forged certificate naming their client and identifier: past the installation's bound no head or directory is read, under it the word it always got",
         %{device: device, identity: identity} do
      # The cached head past its bound: checking the certificate's subject
      # would read the directory again.
      {1, _} =
        Arca.Repo.update_all(
          from(h in Arca.Schemas.DirectoryHead, where: h.identifier == ^identity.identifier),
          set: [verified_at: DateTime.add(DateTime.utc_now(), -400, :second)]
        )

      _before = Sanctum.Test.DirectoryServer.requests()

      # Under the bound it is checked as every connect always was, and
      # refused for what its certificate is.
      assert connect(forged(device), "192.0.2.89") == {:error, :bad_signature}
      _refreshed = Sanctum.Test.DirectoryServer.requests()

      # Past it, a certificate this home cannot tie to the client's key
      # leads nowhere near the person's head.
      {1, _} =
        Arca.Repo.update_all(
          from(h in Arca.Schemas.DirectoryHead, where: h.identifier == ^identity.identifier),
          set: [verified_at: DateTime.add(DateTime.utc_now(), -400, :second)]
        )

      spend!(:device_connect_installation, "installation", 199, 200)
      watch_sources!()

      assert {:error, {:rate_limited, _}} = connect(forged(device), "192.0.2.90")

      assert Enum.sort(sources()) == ["paired_clients", "request_rate_windows"]
      assert Sanctum.Test.DirectoryServer.requests() == []
      assert window(:device_connect_client, device.client_id) == nil

      # The device itself, proving its key, is checked as ever: its head is
      # read again past the bound.
      assert {:ok, _ctx} = connect(device, "192.0.2.91")
      assert Sanctum.Test.DirectoryServer.requests() != []
    end

    test "the context is established only where the certificate, the identity row read for it and the client name one person",
         %{device: device, user: user, identity: identity} do
      athanor_id = device.certificate.athanor
      {:ok, client} = DeviceCerts.paired_client(athanor_id, user.id, device.client_id)
      {:ok, standing} = DeviceCerts.standing(user.id, athanor_id)

      {:ok, row} =
        Arca.PersonIdentities.lookup_identifier(Prima.Actor.system(), identity.identifier)

      credential = %{
        certificate: device.certificate,
        client: client,
        identity: Map.take(row, [:user_id, :provenance, :identifier]),
        user: standing.user,
        athanor: standing.athanor,
        seat: standing.seat,
        platform_admin: standing.platform_admin
      }

      assert {:ok, %Context{user_id: user_id, client_id: client_id}} =
               Sanctum.Caller.establish_device(credential, [])

      assert {user_id, client_id} == {user.id, device.client_id}

      another = "per_" <> Prima.Digest.sha256_hex("another-#{System.unique_integer()}")
      stranger = seated!()

      for {what, changed} <- [
            another_identifier: put_in(credential.identity.identifier, another),
            another_persons_row: put_in(credential.identity.user_id, stranger.user.id),
            a_local_row: put_in(credential.identity.provenance, "local"),
            no_row: %{credential | identity: nil},
            no_row_at_all: Map.delete(credential, :identity)
          ] do
        assert Sanctum.Caller.establish_device(changed, []) == {:error, :unauthenticated},
               inspect(what)
      end
    end

    test "a head that moved retires the certificate: its next request is refused, the glass certified again at their home",
         %{device: device, directory: directory, identity: identity} do
      {:ok, ctx} = remote_connect(device)
      Sanctum.Test.DirectoryServer.rotate!(directory.dir, identity)
      {:ok, _} = Sanctum.IdentityFreshness.fresh!(identity.identifier)

      assert {:error, :bad_signature} = DeviceCerts.verify_request(device.certificate, ctx, [])
      assert {:error, _refused} = remote_connect(device)

      # A remote certificate is not renewed here.
      challenge = challenge(device, :renew)

      assert DeviceCerts.verify_connect(
               %{client_id: device.client_id, certificate: device.certificate, source: @source},
               Proof.sign(challenge, device.private),
               challenge
             ) == {:error, :remote_identity_unavailable}
    end

    test "past the freshness bound with the directory unreachable, the device pauses as a session does; the pairing stands",
         %{device: device, directory: directory, identity: identity} do
      {:ok, ctx} = remote_connect(device)
      Sanctum.Test.DirectoryServer.Server.stop(directory.server)

      {1, _} =
        Arca.Repo.update_all(
          from(h in Arca.Schemas.DirectoryHead, where: h.identifier == ^identity.identifier),
          set: [verified_at: DateTime.add(DateTime.utc_now(), -400, :second)]
        )

      # Revalidation (`Sanctum.Caller.revalidate_device/1`) pauses it.
      assert {:error, :identity_stale} =
               Sanctum.Caller.revalidate_session(%{ctx | validated_at: nil})

      assert {:error, :identity_stale} = DeviceCerts.verify_request(device.certificate, ctx, [])

      # Its pause is no failed proof: nothing is counted against the bounds.
      assert {:error, :identity_stale} = remote_connect(device)

      assert {:ok, [%{standing: "active"}]} =
               Arca.PairedClients.list(Prima.Actor.in_athanor(ctx.athanor_id),
                 user_id: ctx.user_id,
                 standing: :all
               )
    end
  end
end
