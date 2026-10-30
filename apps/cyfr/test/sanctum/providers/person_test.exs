# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.PersonTest do
  @moduledoc """
  The `person` tool through the gate, as the wire reaches it: the recovery
  code an admission enrolled the person with, another recovery code, a
  door's link and unlink, a device certificate for another home, and the
  sign-in carry. Each sensitive
  action meets its confirmation before it changes anything, each refusal
  reads as the refusal table's sentence, and no declared action answers
  that it is not built.

  The directory's own answers are `Sanctum.RecoveryTest`'s, against a
  scripted directory; here the pinned directory is one this home cannot
  reach, and an acceptance is recorded on the attempt as a later retry
  would record it.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Arca.Schemas.{IdentityAttempt, PersonIdentity}
  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry}
  alias Sanctum.{Cipher, CipherAAD, Context, TestContext}
  alias Sanctum.Tenancy.Athanors

  # A directory this home cannot reach: a loopback port nothing listens on.
  @unreachable "https://localhost:1"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    directory = Application.fetch_env(:sanctum, :directory_url)

    on_exit(fn ->
      case directory do
        {:ok, value} -> Application.put_env(:sanctum, :directory_url, value)
        :error -> Application.delete_env(:sanctum, :directory_url)
      end

      Prima.Test.RateLimiter.reset!()
    end)

    Application.put_env(:sanctum, :directory_url, @unreachable)
    :ok
  end

  defp seated! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|person-tool-#{n}",
        provider: "github",
        email: "person-tool#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Person tool #{n}")

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
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)
    %{user: user, ctx: ctx}
  end

  # The seated person, enrolled: their genesis, accepted.
  defp enrolled! do
    %{user: user} = person = seated!()
    keys = Arca.Repo.get_by!(PersonIdentity, user_id: user.id)

    {:ok, operational} =
      Cipher.decrypt(keys.operational_key_sealed, CipherAAD.person_key(user.id, :operational))

    {recovery, _} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, genesis} =
      Entry.genesis(
        live_key: keys.live_public_key,
        operational_key: keys.operational_public_key,
        recovery_keys: [recovery],
        directory: @unreachable
      )

    genesis = Identity.sign(genesis, operational)
    as = %Prima.Actor{user_id: user.id}

    {:ok, attempt} =
      Arca.IdentityAttempts.open(as, %{
        kind: "enrollment",
        request_id: request_id(),
        user_id: user.id,
        identifier: Identity.identifier(genesis),
        directory_url: @unreachable,
        genesis: Identity.canonical(genesis),
        request_digest: Identity.hash(genesis),
        kit_seed_sealed: "sealed-kit-seed"
      })

    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "staged", "submitted")
    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "submitted", "accepted")
    Map.put(person, :identifier, Identity.identifier(genesis))
  end

  defp named!(person, name) do
    {:ok, user} = Sanctum.Tenancy.Users.get(person.user.id)
    {:ok, _named} = Sanctum.Tenancy.Users.set_namespace(user, name)
    :ok
  end

  defp request_id, do: "req_#{System.unique_integer([:positive])}"
  defp call(ctx, args), do: Sanctum.Gate.call_external("person", ctx, args)
  defp refusal({:error, reason}), do: Sanctum.Refusals.classify(reason)

  # A renewal's challenge for `renew`, signed by `private`: the proof its
  # second call carries.
  defp proved(device, renew, private) do
    {:ok, %{challenge: challenge}} = call(device, renew)
    {:ok, held} = Prima.DeviceCert.Challenge.decode(challenge)
    Prima.DeviceCert.Proof.encode(Prima.DeviceCert.Proof.sign(held, private))
  end

  defp add_args(code, id) do
    %{
      "action" => "recovery_code_add",
      "recovery_code" => code,
      "holder" => %{"recovery_secret" => Encoding.b64(:crypto.strong_rand_bytes(32))},
      "request_id" => id
    }
  end

  defp attempts(user_id, kind) do
    Arca.Repo.all(from(a in IdentityAttempt, where: a.user_id == ^user_id and a.kind == ^kind))
  end

  defp confirmations(user_id) do
    Arca.Repo.all(
      from(c in "pending_confirmations",
        where: c.user_id == ^user_id,
        select: %{action: c.action, state: c.state}
      )
    )
  end

  describe "the recovery code" do
    test "is shown only under a fresh proof, saved only once the name is recorded, and then gone" do
      person = seated!()
      identity = Sanctum.Test.Newcomers.identity()
      :ok = Sanctum.Recovery.open_at_admission(person.user.id, identity, @unreachable)
      [attempt] = attempts(person.user.id, "enrollment")
      as = %Prima.Actor{user_id: person.user.id}
      {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "staged", "submitted")
      {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "submitted", "accepted")
      code = Prima.RecoveryCode.encode(attempt.identifier, identity.recovery_secret)
      code_args = %{"action" => "recovery_code", "attempt_id" => attempt.id}
      saved_args = %{"action" => "recovery_code_saved", "attempt_id" => attempt.id}

      assert {:error, {:confirmation_required, %{operation: "person.recovery_code"}}} =
               call(person.ctx, code_args)

      assert {:ok, %{code: ^code} = shown} =
               TestContext.confirming(person.ctx, &call(&1, code_args))

      assert shown == %{attempt_id: attempt.id, code: code}

      assert %Prima.Refusal{class: :conflict, message: unnamed} =
               refusal(call(person.ctx, saved_args))

      assert unnamed == "Your name is not recorded yet, so your recovery code cannot be saved."

      named!(person, identity.name)
      assert {:ok, %{phase: "completed"}} = call(person.ctx, saved_args)

      assert %Prima.Refusal{class: :conflict, message: gone} =
               refusal(call(person.ctx, code_args))

      assert gone == "You said your recovery code is saved, so it is gone and cannot be shown."
    end
  end

  describe "person.status" do
    test "reads the identity as its settings show it, and no seed or sealed value" do
      person = seated!()

      assert {:ok, status} = call(person.ctx, %{"action" => "status"})
      assert status.provenance == "local"
      assert status.identifier == nil
      assert status.name == nil
      assert status.enrollment == "none"
      assert status.key_epoch == nil
      assert status.directory_url == @unreachable
      assert status.kits == []
      assert status.rotation == nil
      assert [%{provider: "github", key: "github|" <> _, subject: _, issuer: _}] = status.doors

      enrolled = enrolled!()

      assert {:ok, status} = call(enrolled.ctx, %{"action" => "status"})
      assert status.enrollment == "enrolled"
      assert status.identifier == enrolled.identifier
      assert is_binary(status.key_epoch)

      assert [%{kind: "enrollment", phase: "accepted", deliverable: true, attempt_id: id}] =
               status.kits

      refute inspect(status) =~ "sealed-kit-seed"
      refute Enum.any?(status.kits, &Map.has_key?(&1, :kit_seed_sealed))

      # Named, then saved, the code is no longer in progress.
      named!(enrolled, "enrolled-#{System.unique_integer([:positive])}")
      assert {:ok, %{name: "enrolled-" <> _}} = call(enrolled.ctx, %{"action" => "status"})

      assert {:ok, %{phase: "completed"}} =
               call(enrolled.ctx, %{"action" => "recovery_code_saved", "attempt_id" => id})

      assert {:ok, %{kits: []}} = call(enrolled.ctx, %{"action" => "status"})
    end

    test "names no directory where this home pins none, and reads only the person's own" do
      person = seated!()
      _other = enrolled!()
      Application.delete_env(:sanctum, :directory_url)

      assert {:ok, %{directory_url: nil, kits: [], identifier: nil}} =
               call(person.ctx, %{"action" => "status"})
    end
  end

  describe "person.recovery_code_add" do
    test "a signing code that does not read is refused in the person's words, asking and opening nothing" do
      person = enrolled!()
      asked = confirmations(person.user.id)
      code = Prima.RecoveryCode.encode(person.identifier, :crypto.strong_rand_bytes(32))
      {kept, last} = String.split_at(code, -1)
      typo = kept <> if(last == "0", do: "1", else: "0")

      assert %Prima.Refusal{class: :invalid_argument, reason: :typo, message: message} =
               refusal(call(person.ctx, add_args(typo, request_id())))

      assert message == "That recovery code has a typo. Check it against the one you saved."

      for text <- ["per_" <> String.duplicate("0", 64), "CYFR-" <> String.duplicate("0", 8)] do
        assert %Prima.Refusal{class: :invalid_argument, reason: :not_a_code, message: message} =
                 refusal(call(person.ctx, add_args(text, request_id())))

        assert message == "That is not a recovery code. A recovery code starts with CYFR-."
      end

      assert confirmations(person.user.id) == asked
      assert attempts(person.user.id, "holder") == []
    end

    test "a code of another identity is no holder of this person's, asking nothing" do
      person = enrolled!()
      other = "per_" <> String.duplicate("ab", 32)
      asked = confirmations(person.user.id)
      code = Prima.RecoveryCode.encode(other, :crypto.strong_rand_bytes(32))

      assert %Prima.Refusal{class: :forbidden, reason: :not_a_holder, message: message} =
               refusal(call(person.ctx, add_args(code, request_id())))

      assert message ==
               "The recovery code that signs this is not one of your identity's codes now."

      assert confirmations(person.user.id) == asked
      assert attempts(person.user.id, "holder") == []
    end

    test "the code that signs is required by its declaration" do
      person = enrolled!()
      args = Map.delete(add_args("unused", request_id()), "recovery_code")

      assert %Prima.Refusal{class: :invalid_argument} = refusal(call(person.ctx, args))
      assert attempts(person.user.id, "holder") == []
    end
  end

  describe "person.certify" do
    test "a certificate for another home, naming the identity, under its proof" do
      person = enrolled!()
      {device_key, _} = :crypto.generate_key(:eddsa, :ed25519)

      args = %{
        "action" => "certify",
        "device_key" => Encoding.b64(device_key),
        "audience" => "https://hub.example",
        "athanor" => "ath_hub",
        "client_id" => "pcl_hub"
      }

      assert {:error, {:confirmation_required, %{operation: "person.certify"}}} =
               call(person.ctx, args)

      assert {:ok, %{certificate: certificate}} =
               TestContext.confirming(person.ctx, &call(&1, args))

      assert {:ok, cert} = Prima.DeviceCert.decode(certificate)
      assert cert.audience == "https://hub.example"
      assert cert.device_key == device_key
      assert cert.subject.identifier == person.identifier

      assert cert.subject.key_epoch ==
               Arca.Repo.get_by!(PersonIdentity, user_id: person.user.id).head_hash

      # What it certified is recorded here, under that head.
      assert [record] =
               Arca.Repo.all(
                 from(c in Arca.Schemas.DeviceCertification, where: c.user_id == ^person.user.id)
               )

      assert {record.audience_home, record.client_id, record.key_epoch} ==
               {"https://hub.example", "pcl_hub", cert.subject.key_epoch}
    end

    test "person.renew_certificate is anonymous: the device key's proof over this home's challenge is its only credential" do
      person = enrolled!()
      {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)

      certify = %{
        "action" => "certify",
        "device_key" => Encoding.b64(device_key),
        "audience" => "https://hub.example",
        "athanor" => "ath_hub",
        "client_id" => "pcl_hub"
      }

      {:ok, %{certificate: certificate}} = TestContext.confirming(person.ctx, &call(&1, certify))

      # A caller holding no session of this home's: the device at the hub.
      device = Context.build(%{authenticated: false, client_ip: "198.51.100.61"})
      renew = %{"action" => "renew_certificate", "certificate" => certificate}

      assert {:ok, %{challenge: challenge}} = call(device, renew)
      {:ok, held} = Prima.DeviceCert.Challenge.decode(challenge)
      proof = Prima.DeviceCert.Proof.encode(Prima.DeviceCert.Proof.sign(held, private))

      assert {:ok, %{certificate: replacement}} = call(device, Map.put(renew, "proof", proof))
      assert {:ok, renewed} = Prima.DeviceCert.decode(replacement)
      assert renewed.device_key == device_key

      # The refusals a device reads: a proof used again, a certification
      # this home does not hold, and one whose head has moved since. The
      # challenge reads nothing, so those that need the certification are
      # the proof's.
      assert %Prima.Refusal{class: :unauthenticated} =
               refusal(call(device, Map.put(renew, "proof", proof)))

      unknown = %{renew | "certificate" => %{certificate | "client_id" => "pcl_x"}}
      assert {:ok, %{challenge: _}} = call(device, unknown)

      assert %Prima.Refusal{class: :not_found} =
               refusal(call(device, Map.put(unknown, "proof", proved(device, unknown, private))))

      {1, _} =
        Arca.Repo.update_all(
          from(p in PersonIdentity, where: p.user_id == ^person.user.id),
          set: [head_hash: Prima.Digest.sha256("rotated")]
        )

      assert %Prima.Refusal{class: :conflict, reason: :certification_ended, message: message} =
               refusal(call(device, Map.put(renew, "proof", proved(device, renew, private))))

      assert message =~ "certify it again"
    end

    test "a rate-limited renewal answers its retry in whole seconds, never more than a minute" do
      person = enrolled!()
      {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)

      certify = %{
        "action" => "certify",
        "device_key" => Encoding.b64(device_key),
        "audience" => "https://hub.example",
        "athanor" => "ath_hub",
        "client_id" => "pcl_hub"
      }

      {:ok, %{certificate: certificate}} = TestContext.confirming(person.ctx, &call(&1, certify))
      device = Context.build(%{authenticated: false, client_ip: "198.51.100.62"})
      renew = %{"action" => "renew_certificate", "certificate" => certificate}
      valid = proved(device, renew, private)

      # Proofs no key of the certification made are no one's: they spend
      # the address's bound.
      {_stranger, stranger} = :crypto.generate_key(:eddsa, :ed25519)
      bogus = Map.put(renew, "proof", proved(device, renew, stranger))

      for _ <- 1..20 do
        assert %Prima.Refusal{class: :unauthenticated} = refusal(call(device, bogus))
      end

      # The challenge and the device's own proof from that address are
      # refused, each with when to retry in seconds.
      for args <- [renew, Map.put(renew, "proof", valid)] do
        assert %Prima.Refusal{class: :rate_limited, message: message} =
                 refusal(call(device, args))

        assert [_, seconds] = Regex.run(~r/retry in (\d+) s/, message)
        assert String.to_integer(seconds) in 1..60
      end
    end

    test "this home is refused as the audience, and an unenrolled person certifies nothing" do
      person = enrolled!()
      {device_key, _} = :crypto.generate_key(:eddsa, :ed25519)

      here = %{
        "action" => "certify",
        "device_key" => Encoding.b64(device_key),
        "audience" => Sanctum.Person.home(),
        "athanor" => "ath_here",
        "client_id" => "pcl_here"
      }

      assert %Prima.Refusal{class: :invalid_argument, message: message} =
               refusal(call(person.ctx, here))

      assert message =~ "through pairing"

      unenrolled = seated!()
      elsewhere = %{here | "audience" => "https://hub.example"}

      assert %Prima.Refusal{class: :conflict, message: message} =
               refusal(call(unenrolled.ctx, elsewhere))

      assert message =~ "enroll first"
      assert confirmations(unenrolled.user.id) == []
    end
  end

  describe "the sign-in carry" do
    test "begins at this home for one other, and its outcome is recorded once" do
      person = enrolled!()

      assert {:ok, %{action_id: action_id, fragment: fragment, return_url: return_url}} =
               call(person.ctx, %{
                 "action" => "carry_begin",
                 "destination" => "https://hub.example"
               })

      assert return_url == Sanctum.Person.home() <> "/carry"
      assert {:ok, _} = Prima.Carry.parse_fragment(fragment)

      complete = %{
        "action" => "carry_complete",
        "action_id" => action_id,
        "outcome" => "admitted"
      }

      assert {:ok, %{phase: "completed", outcome: "admitted"}} = call(person.ctx, complete)
      assert {:ok, %{phase: "completed", outcome: "admitted"}} = call(person.ctx, complete)

      assert %Prima.Refusal{class: :conflict} =
               refusal(call(person.ctx, %{complete | "outcome" => "refused"}))
    end
  end

  describe "the doors" do
    test "a door is linked by its ticket alone, and a made-up one links nothing" do
      person = seated!()

      args = %{
        "action" => "link_door",
        "provider" => "oidcc",
        "ticket" => Encoding.b64(:crypto.strong_rand_bytes(32))
      }

      assert %Prima.Refusal{class: :invalid_argument, message: message} =
               refusal(call(person.ctx, args))

      assert message =~ "sign in with that sign-in method again"

      assert %Prima.Refusal{class: :invalid_argument} =
               refusal(call(person.ctx, %{args | "provider" => "email"}))
    end

    test "the last door stays while the person holds no passkey here" do
      person = seated!()
      {:ok, [door]} = Arca.Users.identities(Prima.Actor.system(), person.user.id)

      assert %Prima.Refusal{class: :conflict, message: message} =
               refusal(call(person.ctx, %{"action" => "unlink_door", "door" => door.key}))

      assert message =~ "hold no passkey"
      assert message =~ "link another sign-in method"
    end
  end

  test "no declared person action answers that it is not built" do
    person = seated!()
    %{operations: operations} = Sanctum.Providers.Person.definition()

    # `assert` is `Sanctum.Providers.Assertion`'s, which the CYFR door fills.
    for %{action: action} <- operations, action != "assert" do
      {result, _log} =
        with_log(fn -> Sanctum.Providers.Person.handle(person.ctx, %{"action" => action}) end)

      refute result == {:error, :not_built}, "person.#{action} answers :not_built"
    end

    for action <- ["recovery_code", "recovery_code_saved"] do
      assert Sanctum.Providers.Person.handle(person.ctx, %{"action" => action}) ==
               {:error, {:invalid_argument, "#{action} needs the code's attempt_id"}}
    end
  end
end
