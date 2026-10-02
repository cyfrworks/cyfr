# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.RemoteCertificationTest do
  @moduledoc """
  A person's devices at other homes, certified at the home that holds the
  person's keys: a certification only under a fresh `device_pairing`
  proof, recorded with that proof's consumption under the person's head;
  and its renewal by the device key's proof over a challenge only this
  home makes, used once, while the person, the record and the head stand.
  A changed head ends every certification made under the old one. The
  challenge reads nothing; a proof the certification's key made counts
  against its person, any other against its address and the
  installation, so a flood naming the person never stops their device.
  """

  # The rate limiter's table is the node's.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{DeviceCertification, PersonIdentity, User}
  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry}
  alias Sanctum.{Context, Person, RemoteCertification, TestContext}
  alias Sanctum.Tenancy.{Athanors, Users}

  @directory "https://dir.example"
  @hub "https://hub.example"
  @source "198.51.100.40"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    Prima.RateLimiter.reset()
    on_exit(fn -> Prima.RateLimiter.reset() end)
    enrolled!()
  end

  # ---- fixtures ----------------------------------------------------------------

  # A person signed in at their own home and enrolled there: their genesis,
  # signed by their operational key, accepted.
  defp enrolled! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|remote-cert-#{n}",
        provider: "github",
        email: "remote-cert#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Certify #{n}")

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

    {:ok, session} = TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

    keys = Arca.Repo.get_by!(PersonIdentity, user_id: user.id)

    {:ok, operational} =
      Sanctum.Cipher.decrypt(
        keys.operational_key_sealed,
        Sanctum.CipherAAD.person_key(user.id, :operational)
      )

    {recovery, _} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, genesis} =
      Entry.genesis(
        live_key: keys.live_public_key,
        operational_key: keys.operational_public_key,
        recovery_keys: [recovery],
        directory: @directory
      )

    genesis = Identity.sign(genesis, operational)
    as = %Prima.Actor{user_id: user.id}

    {:ok, attempt} =
      Arca.IdentityAttempts.open(as, %{
        kind: "enrollment",
        request_id: "req_#{System.unique_integer([:positive])}",
        user_id: user.id,
        identifier: Identity.identifier(genesis),
        directory_url: @directory,
        genesis: Identity.canonical(genesis),
        request_digest: Identity.hash(genesis),
        kit_seed_sealed: "sealed-kit-seed"
      })

    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "staged", "submitted")
    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "submitted", "accepted")

    {device_key, device_private} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      user: user,
      ctx: ctx,
      identifier: Identity.identifier(genesis),
      device: {device_key, device_private}
    }
  end

  defp args({device_key, _private}, overrides \\ %{}) do
    Map.merge(
      %{
        "device_key" => Encoding.b64(device_key),
        "audience" => @hub,
        "athanor" => "ath_hub",
        "client_id" => "pcl_hub"
      },
      overrides
    )
  end

  defp head(user), do: Arca.Repo.get_by!(PersonIdentity, user_id: user.id).head_hash

  defp records(user),
    do: Arca.Repo.all(from(c in DeviceCertification, where: c.user_id == ^user.id))

  defp certified!(%{ctx: ctx, device: device}) do
    {:ok, %{certificate: certificate}} =
      TestContext.confirming(ctx, &RemoteCertification.certify(&1, args(device)))

    certificate
  end

  defp glass(source \\ @source), do: Context.build(%{authenticated: false, client_ip: source})

  defp renew(certificate, proof \\ nil, source \\ @source) do
    args =
      if proof,
        do: %{"certificate" => certificate, "proof" => proof},
        else: %{"certificate" => certificate}

    RemoteCertification.renew(glass(source), args)
  end

  # The device's two calls: the challenge, then its proof over it.
  defp renewed(certificate, {_key, private}, source \\ @source) do
    with {:ok, %{challenge: challenge}} <- renew(certificate, nil, source) do
      {:ok, challenge} = Challenge.decode(challenge)
      renew(certificate, Proof.encode(Proof.sign(challenge, private)), source)
    end
  end

  # The cell's verification window `bucket` holds for `key`, or nil.
  defp window(bucket, key) do
    hash = Prima.Digest.sha256(key)

    Arca.Repo.one(
      from(w in Arca.Schemas.RequestRateWindow,
        where: w.bucket == ^Atom.to_string(bucket) and w.key_hash == ^hash
      )
    )
  end

  # The tables this process's statements read or write from here on.
  defp watch_sources! do
    handler = "remote-certification-sources-#{System.unique_integer([:positive])}"
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

  defp move_head!(user) do
    moved = Prima.Digest.sha256("rotated-#{System.unique_integer()}")

    {1, _} =
      Arca.Repo.update_all(from(p in PersonIdentity, where: p.user_id == ^user.id),
        set: [head_hash: moved]
      )

    moved
  end

  # ---- certifying ----------------------------------------------------------------

  describe "certify/2" do
    test "waits for a fresh proof, then answers the certificate and records what it certified",
         %{ctx: ctx, user: user, device: {device_key, _} = device, identifier: identifier} do
      assert {:error, {:confirmation_required, %{operation: "person.certify"}}} =
               RemoteCertification.certify(ctx, args(device))

      assert records(user) == []

      certificate = certified!(%{ctx: ctx, device: device})
      assert {:ok, cert} = DeviceCert.decode(certificate)
      assert cert.issuer == Person.home()
      assert cert.audience == @hub
      assert cert.athanor == "ath_hub"
      assert cert.client_id == "pcl_hub"
      assert cert.device_key == device_key
      assert cert.subject == %{kind: :identity, identifier: identifier, key_epoch: head(user)}

      assert [record] = records(user)
      assert record.key_epoch == head(user)
      assert record.device_public_key == device_key

      assert {record.audience_home, record.audience_athanor, record.client_id} ==
               {@hub, "ath_hub", "pcl_hub"}

      assert DateTime.to_unix(record.expires_at, :millisecond) == cert.expires_at
    end

    test "the confirmation is consumed with the record: a proof given for one certification certifies no other",
         %{ctx: ctx, user: user, device: device} do
      {:error, {:confirmation_required, %{id: id}}} =
        RemoteCertification.certify(ctx, args(device))

      TestContext.prove!(ctx, id)
      confirmed = %{ctx | confirmation_id: id}

      other = args(device, %{"client_id" => "pcl_other"})
      assert {:error, _refused} = RemoteCertification.certify(confirmed, other)
      assert records(user) == []

      assert {:ok, _} = RemoteCertification.certify(confirmed, args(device))
      assert {:error, _spent} = RemoteCertification.certify(confirmed, args(device))
      assert length(records(user)) == 1
    end

    test "this home, a malformed request and an unenrolled person certify nothing",
         %{ctx: ctx, device: device} do
      assert {:error, {:invalid_argument, message}} =
               RemoteCertification.certify(ctx, args(device, %{"audience" => Person.home()}))

      assert message =~ "through pairing"

      assert {:error, {:invalid_argument, _}} =
               RemoteCertification.certify(ctx, args(device, %{"device_key" => "short"}))

      assert {:error, {:invalid_argument, _}} =
               RemoteCertification.certify(ctx, args(device, %{"athanor" => "not an id!"}))
    end
  end

  # ---- renewing ------------------------------------------------------------------

  describe "renew/2" do
    setup context do
      %{certificate: certified!(context)}
    end

    test "answers this home's renew challenge for the record, then the replacement for the device key's proof",
         %{certificate: certificate, device: {device_key, _} = device, user: user} do
      assert {:ok, %{challenge: challenge}} = renew(certificate)
      assert {:ok, held} = Challenge.decode(challenge)
      assert held.purpose == :renew
      assert held.home == Person.home()
      assert held.athanor == "ath_hub"
      assert held.client_id == "pcl_hub"
      assert held.device_key == device_key

      [before] = records(user)
      Process.sleep(5)
      assert {:ok, %{certificate: replacement}} = renewed(certificate, device)
      assert {:ok, cert} = DeviceCert.decode(replacement)
      assert cert.device_key == device_key
      assert cert.subject.key_epoch == head(user)
      assert cert.expires_at > certificate["expires_at"]

      [after_renewal] = records(user)
      assert DateTime.to_unix(after_renewal.expires_at, :millisecond) == cert.expires_at
      assert DateTime.compare(after_renewal.expires_at, before.expires_at) == :gt
    end

    test "an expired certificate locates its record as well as a current one",
         %{certificate: certificate, device: device} do
      expired = Map.merge(certificate, %{"not_before" => 1, "expires_at" => 2})
      assert {:ok, %{certificate: _}} = renewed(expired, device)
    end

    test "a proof is used once; another key's proof, or a challenge this home did not make, renews nothing",
         %{certificate: certificate, device: {_key, private} = device} do
      {:ok, %{challenge: challenge}} = renew(certificate)
      {:ok, held} = Challenge.decode(challenge)
      proof = Proof.encode(Proof.sign(held, private))
      assert {:ok, %{certificate: _}} = renew(certificate, proof)
      assert {:error, :replayed} = renew(certificate, proof)

      {_other, stranger} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, %{challenge: challenge}} = renew(certificate)
      {:ok, held} = Challenge.decode(challenge)

      assert {:error, :proof_refused} =
               renew(certificate, Proof.encode(Proof.sign(held, stranger)))

      # A nonce of the device's own making, or a challenge stretched past
      # this home's window, was never issued here.
      forged = %{held | nonce: :crypto.strong_rand_bytes(32)}

      assert {:error, :proof_refused} =
               renew(certificate, Proof.encode(Proof.sign(forged, private)))

      stretched = %{held | expires_at: held.expires_at + 10 * Challenge.lifetime_ms()}

      assert {:error, :proof_refused} =
               renew(certificate, Proof.encode(Proof.sign(stretched, private)))

      assert {:ok, _} = renewed(certificate, device)
    end

    # A member whose clock lags holds the challenge current for as long as
    # the tolerance; the nonce stays used that long too.
    test "a used nonce stays used for the challenge's life and the configured clock tolerance",
         %{certificate: certificate, device: device} do
      Sanctum.Test.Settings.put("clock_skew_seconds", 7)
      assert {:ok, %{certificate: _}} = renewed(certificate, device)

      assert [window_ms] =
               Arca.Repo.all(
                 from(w in Arca.Schemas.RequestRateWindow,
                   where: w.bucket == "remote_renewal_proof",
                   select: w.window_ms
                 )
               )

      assert window_ms == Challenge.lifetime_ms() + 7_000
    end

    test "a changed head ends the certification: the challenge is still answered, the proof refused",
         %{certificate: certificate, device: device, user: user} do
      {:ok, %{challenge: challenge}} = renew(certificate)
      move_head!(user)

      {:ok, held} = Challenge.decode(challenge)
      {_key, private} = device

      assert {:error, :certification_ended} =
               renew(certificate, Proof.encode(Proof.sign(held, private)))

      # The challenge reads nothing, so it cannot know; the proof over it
      # is refused the same way.
      assert {:error, :certification_ended} = renewed(certificate, device)
    end

    test "what the certificate locates must stand here: another issuer, client, device key or a denied person renews nothing",
         %{certificate: certificate, device: device, user: user} do
      # Another issuer is refused from what the certificate says alone.
      assert {:error, :not_found} =
               renew(%{certificate | "issuer" => "https://elsewhere.example"})

      # The rest need the record, so the proof call refuses them.
      assert {:error, :not_found} = renewed(%{certificate | "client_id" => "pcl_unknown"}, device)

      {other_key, other_private} = :crypto.generate_key(:eddsa, :ed25519)

      assert {:error, :binding_changed} =
               renewed(
                 %{certificate | "device_key" => Encoding.b64(other_key)},
                 {other_key, other_private}
               )

      assert {:error, {:invalid_argument, _}} = renew(%{"not" => "a certificate"})
      assert {:error, {:invalid_argument, _}} = RemoteCertification.renew(glass(), %{})

      {1, _} =
        Arca.Repo.update_all(from(u in User, where: u.id == ^user.id), set: [status: "denied"])

      assert {:error, :not_standing} = renewed(certificate, device)
    end

    test "the challenge call reads nothing and counts nothing",
         %{certificate: certificate} do
      watch_sources!()

      for _ <- 1..30,
          do: assert({:ok, %{challenge: _}} = renew(certificate, nil, "198.51.100.77"))

      assert sources() == []
      assert window(:device_verification_source, "198.51.100.77") == nil
    end

    test "a proof call nothing attributes counts against its address, and a spent address refuses both calls",
         %{certificate: certificate, device: device} do
      {_key, private} = device
      {:ok, %{challenge: challenge}} = renew(certificate)
      {:ok, held} = Challenge.decode(challenge)
      {_stranger, stranger} = :crypto.generate_key(:eddsa, :ed25519)
      bogus = Proof.encode(Proof.sign(held, stranger))

      for _ <- 1..20 do
        assert {:error, :proof_refused} = renew(certificate, bogus, "198.51.100.78")
      end

      assert %{count: 20} = window(:device_verification_source, "198.51.100.78")

      assert {:error, {:rate_limited, retry_after_ms}} =
               renew(certificate, bogus, "198.51.100.78")

      assert retry_after_ms in 1..60_000

      # Read before anything, on this member's own count: the device's
      # own proof and the challenge call from that address are refused too.
      assert {:error, {:rate_limited, _}} = renew(certificate, nil, "198.51.100.78")

      assert {:error, {:rate_limited, _}} =
               renew(certificate, Proof.encode(Proof.sign(held, private)), "198.51.100.78")

      assert {:error, {:rate_limited, _}} = renew(%{"bogus" => true}, nil, "198.51.100.78")
    end

    test "a flood naming the person and the client, from 200 addresses across two members, leaves the device renewing",
         %{certificate: certificate, device: device, user: user} do
      # Each sends the certificate under a key of its own: the challenge is
      # answered for that binding and its proof verifies, and only the
      # certification can tell it is not the device's.
      for n <- 1..200 do
        if n == 101, do: Prima.RateLimiter.reset()
        {key, private} = :crypto.generate_key(:eddsa, :ed25519)
        forged = %{certificate | "device_key" => Encoding.b64(key)}
        source = "10.8.#{div(n, 250)}.#{rem(n, 250)}"

        assert {:error, :binding_changed} = renewed(forged, {key, private}, source)
      end

      # The installation's ceiling holds for what no person proved.
      {key, private} = :crypto.generate_key(:eddsa, :ed25519)
      forged = %{certificate | "device_key" => Encoding.b64(key)}

      assert {:error, {:rate_limited, retry_after_ms}} =
               renewed(forged, {key, private}, "10.9.0.1")

      assert retry_after_ms in 1..60_000
      Prima.RateLimiter.reset()
      assert {:error, {:rate_limited, _}} = renewed(forged, {key, private}, "10.9.0.2")
      assert %{count: 200} = window(:device_verification_installation, "installation")

      # Named 200 times, the person spent nothing of their own, and their
      # device renews from its own address.
      assert window(:device_verification_person, user.id) == nil
      assert {:ok, %{certificate: _}} = renewed(certificate, device, "10.9.0.3")
      assert %{count: 1} = window(:device_verification_person, user.id)
    end

    test "the challenge binds the identifier, the other home and the key_epoch: a proof over it renews no other",
         %{certificate: certificate, device: {_key, private}, user: user} do
      {:ok, %{challenge: challenge}} = renew(certificate)
      {:ok, held} = Challenge.decode(challenge)
      proof = Proof.encode(Proof.sign(held, private))

      another = "per_" <> Prima.Digest.sha256_hex("another-#{System.unique_integer()}")

      for {what, claimed} <- [
            identifier: put_in(certificate, ["subject", "identifier"], another),
            audience: %{certificate | "audience" => "https://other-hub.example"},
            key_epoch: put_in(certificate, ["subject", "key_epoch"], Prima.Digest.sha256("e"))
          ] do
        assert {:ok, _} = DeviceCert.decode(claimed)
        assert renew(claimed, proof) == {:error, :proof_refused}, inspect(what)
      end

      # The proof is still the device's own, for what it was asked for.
      assert head(user) == certificate["subject"]["key_epoch"]
      assert {:ok, %{certificate: _}} = renew(certificate, proof)
    end

    test "a proof call reads nothing before the challenge's HMAC and the proof's signature are checked",
         %{certificate: certificate, device: {_key, private}} do
      {:ok, %{challenge: challenge}} = renew(certificate)
      {:ok, held} = Challenge.decode(challenge)
      {_stranger, stranger} = :crypto.generate_key(:eddsa, :ed25519)
      forged_nonce = %{held | nonce: :crypto.strong_rand_bytes(32)}

      watch_sources!()

      # Another key's signature, and a challenge this home did not make.
      assert {:error, :proof_refused} =
               renew(certificate, Proof.encode(Proof.sign(held, stranger)), "198.51.100.90")

      assert {:error, :proof_refused} =
               renew(
                 certificate,
                 Proof.encode(Proof.sign(forged_nonce, private)),
                 "198.51.100.91"
               )

      # Only the address's windows: no person, no certification.
      assert sources() == ["request_rate_windows"]
    end

    test "the record is held to the key_epoch the certificate claims, which the challenge covered",
         %{certificate: certificate, device: device, user: user} do
      claimed =
        put_in(certificate, ["subject", "key_epoch"], Prima.Digest.sha256("not-the-record"))

      refute claimed["subject"]["key_epoch"] == head(user)
      assert {:ok, _} = DeviceCert.decode(claimed)

      assert renewed(claimed, device, "198.51.100.92") == {:error, :certification_ended}

      # No one's: the address paid for it, the person not.
      assert window(:device_verification_person, user.id) == nil
      assert %{count: 1} = window(:device_verification_source, "198.51.100.92")
    end

    test "a challenge issued before the record moved to another key_epoch renews nothing",
         %{certificate: certificate, device: {_key, private}, user: user} do
      {:ok, %{challenge: challenge}} = renew(certificate)
      {:ok, held} = Challenge.decode(challenge)
      [before] = records(user)

      # The certification made again under a new head, for the same device
      # key, other home, athanor and client.
      moved = move_head!(user)

      {1, _} =
        Arca.Repo.update_all(from(c in DeviceCertification, where: c.user_id == ^user.id),
          set: [key_epoch: moved]
        )

      assert renew(certificate, Proof.encode(Proof.sign(held, private))) ==
               {:error, :certification_ended}

      # Nothing was minted: the record's expiry did not move.
      [record] = records(user)
      assert record.expires_at == before.expires_at
      assert window(:device_verification_person, user.id) == nil
    end

    test "a revoked certification's key cannot spend the person's own budget",
         %{certificate: certificate, device: device, ctx: ctx, user: user} do
      other = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, %{certificate: other_certificate}} =
        TestContext.confirming(
          ctx,
          &RemoteCertification.certify(&1, args(other, %{"client_id" => "pcl_two"}))
        )

      {1, _} =
        Arca.Repo.update_all(
          from(c in DeviceCertification,
            where: c.user_id == ^user.id and c.client_id == "pcl_hub"
          ),
          set: [state: "revoked"]
        )

      for n <- 1..20 do
        assert {:error, :revoked} = renewed(certificate, device, "10.20.0.#{n}")
      end

      assert window(:device_verification_person, user.id) == nil
      assert %{count: 20} = window(:device_verification_installation, "installation")

      # The person's standing device, from an address of its own.
      assert {:ok, %{certificate: _}} = renewed(other_certificate, other, "10.21.0.1")
    end

    test "an ended certification's key cannot spend the person's own budget either",
         %{certificate: certificate, device: device, user: user} do
      move_head!(user)

      for n <- 1..20 do
        assert {:error, :certification_ended} = renewed(certificate, device, "10.22.0.#{n}")
      end

      assert window(:device_verification_person, user.id) == nil
      assert %{count: 20} = window(:device_verification_installation, "installation")
    end

    test "a person past their own budget is refused with its retry bound, on every member",
         %{certificate: certificate, device: device, user: user} do
      for n <- 1..20, do: assert({:ok, _} = renewed(certificate, device, "10.10.0.#{n}"))
      assert %{count: 20} = window(:device_verification_person, user.id)

      assert {:error, {:rate_limited, retry_after_ms}} =
               renewed(certificate, device, "10.10.1.1")

      assert retry_after_ms in 1..60_000
      Prima.RateLimiter.reset()
      assert {:error, {:rate_limited, _}} = renewed(certificate, device, "10.10.1.2")

      # Nothing of it was the address's or the installation's.
      assert window(:device_verification_source, "10.10.0.1") == nil
      assert window(:device_verification_installation, "installation") == nil
    end
  end
end
