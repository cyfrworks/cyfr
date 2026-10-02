# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.PersonTest do
  @moduledoc """
  The `person` tool through the gate, as the wire reaches it: enrollment
  and its kit, an unfinished enrollment abandoned, another printed kit, a door's link and unlink, a device
  certificate for another home, and the sign-in carry. Each sensitive
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
  alias Sanctum.Tenancy.{Athanors, Users}

  # A directory this home cannot reach: a loopback port nothing listens on.
  @unreachable "https://localhost:1"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.RateLimiter.reset()
    directory = Application.fetch_env(:sanctum, :directory_url)

    on_exit(fn ->
      case directory do
        {:ok, value} -> Application.put_env(:sanctum, :directory_url, value)
        :error -> Application.delete_env(:sanctum, :directory_url)
      end

      Prima.RateLimiter.reset()
    end)

    Application.put_env(:sanctum, :directory_url, @unreachable)
    :ok
  end

  defp seated! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
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
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)
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

  defp request_id, do: "req_#{System.unique_integer([:positive])}"
  defp call(ctx, args), do: Grimoire.call_external("person", ctx, args)
  defp refusal({:error, reason}), do: Grimoire.Error.classify(reason)

  defp enroll_args(seed, id),
    do: %{"action" => "enroll", "recovery_secret" => Encoding.b64(seed), "request_id" => id}

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

  describe "person.enroll" do
    test "a session alone is asked for recovery_material and opens nothing" do
      person = seated!()
      seed = :crypto.strong_rand_bytes(32)

      assert {:error, {:confirmation_required, %{operation: "person.enroll"}}} =
               call(person.ctx, enroll_args(seed, request_id()))

      assert attempts(person.user.id, "enrollment") == []
      assert [%{action: "recovery_material", state: "pending"}] = confirmations(person.user.id)
    end

    test "a seed is required by its declaration" do
      person = seated!()

      assert %Prima.Refusal{class: :invalid_argument} =
               refusal(call(person.ctx, %{"action" => "enroll", "request_id" => request_id()}))

      assert attempts(person.user.id, "enrollment") == []
    end

    test "under its proof the attempt opens with the proof consumed, and a retry resumes it" do
      person = seated!()
      seed = :crypto.strong_rand_bytes(32)
      id = request_id()

      {answer, _log} =
        with_log(fn -> TestContext.confirming(person.ctx, &call(&1, enroll_args(seed, id))) end)

      assert %Prima.Refusal{class: :unavailable, message: message} = refusal(answer)
      assert message =~ "retry shortly"
      assert [%{phase: "submitted"} = attempt] = attempts(person.user.id, "enrollment")
      assert [%{state: "consumed"}] = confirmations(person.user.id)

      # The retry needs no second proof and opens no second attempt.
      {_answer, _log} = with_log(fn -> call(person.ctx, enroll_args(seed, id)) end)
      assert [%{id: same}] = attempts(person.user.id, "enrollment")
      assert same == attempt.id
      assert [%{state: "consumed"}] = confirmations(person.user.id)

      # Once the directory's acceptance is recorded, the retry answers the kit.
      as = %Prima.Actor{user_id: person.user.id}
      {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "submitted", "accepted")

      assert {:ok, %{phase: "accepted", kit: kit, attempt_id: attempt_id}} =
               call(person.ctx, enroll_args(seed, id))

      assert kit.recovery_secret == Encoding.b64(seed)
      assert kit.directory_url == @unreachable

      # The kit again needs a fresh proof each time; the acknowledgment
      # erases it.
      kit_args = %{"action" => "kit", "attempt_id" => attempt_id}

      assert {:error, {:confirmation_required, %{operation: "person.kit"}}} =
               call(person.ctx, kit_args)

      assert {:ok, %{kit: ^kit}} = TestContext.confirming(person.ctx, &call(&1, kit_args))

      assert {:ok, %{phase: "completed"}} =
               call(person.ctx, %{"action" => "kit_ack", "attempt_id" => attempt_id})

      assert %Prima.Refusal{class: :conflict, message: gone} =
               refusal(call(person.ctx, kit_args))

      assert gone =~ "seed is gone"
    end

    test "with no directory pinned, enrollment says what the operator owes" do
      person = seated!()
      Application.delete_env(:sanctum, :directory_url)

      assert %Prima.Refusal{class: :setup_required, message: message} =
               refusal(call(person.ctx, enroll_args(:crypto.strong_rand_bytes(32), request_id())))

      assert message =~ "CYFR_DIRECTORY_URL"
    end

    test "the preview it asks under says what enrolling commits to, at the pinned directory" do
      person = seated!()

      assert {:error, {:confirmation_required, _}} =
               call(person.ctx, enroll_args(:crypto.strong_rand_bytes(32), request_id()))

      [preview] =
        Arca.Repo.all(
          from(c in "pending_confirmations",
            where: c.user_id == ^person.user.id,
            select: c.preview
          )
        )

      %{"details" => %{"directory" => directory, "effect" => effect}} = Jason.decode!(preview)
      assert directory == @unreachable
      assert effect =~ @unreachable
      assert effect =~ "cannot be reached"
      assert effect =~ "If every kit is lost, nothing can add one"
      assert effect =~ "never your private data or the homes your devices saved"
    end
  end

  describe "person.status" do
    test "reads the identity as its settings show it, and no seed or sealed value" do
      person = seated!()

      assert {:ok, status} = call(person.ctx, %{"action" => "status"})
      assert status.provenance == "local"
      assert status.identifier == nil
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

      # Acknowledged, the kit is no longer in progress.
      assert {:ok, %{phase: "completed"}} =
               call(enrolled.ctx, %{"action" => "kit_ack", "attempt_id" => id})

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

  describe "person.enroll_abandon" do
    test "ends an enrollment the directory has not accepted, asking nothing, and names it" do
      person = seated!()
      seed = :crypto.strong_rand_bytes(32)
      id = request_id()

      # Begun under its proof, the directory's answer lost.
      {_answer, _log} =
        with_log(fn -> TestContext.confirming(person.ctx, &call(&1, enroll_args(seed, id))) end)

      assert [%{phase: "submitted"}] = attempts(person.user.id, "enrollment")
      asked = confirmations(person.user.id)

      assert {:ok, %{request_id: ^id, phase: "superseded"}} =
               call(person.ctx, %{"action" => "enroll_abandon"})

      assert confirmations(person.user.id) == asked

      assert [%{phase: "superseded", kit_seed_sealed: nil}] =
               attempts(person.user.id, "enrollment")

      assert {:ok, %{enrollment: "none", identifier: nil, kits: []}} =
               call(person.ctx, %{"action" => "status"})

      # A retry under the abandoned request id is told so.
      assert %Prima.Refusal{class: :conflict, message: abandoned} =
               refusal(call(person.ctx, enroll_args(seed, id)))

      assert abandoned =~ "was abandoned"

      # Nothing is left to abandon.
      assert %Prima.Refusal{class: :not_found, message: nothing} =
               refusal(call(person.ctx, %{"action" => "enroll_abandon"}))

      assert nothing =~ "no unfinished enrollment"
    end

    test "an accepted enrollment is registered: refused, its kit still offered" do
      person = enrolled!()

      assert %Prima.Refusal{class: :conflict, message: message} =
               refusal(call(person.ctx, %{"action" => "enroll_abandon"}))

      assert message == "Your identity is registered; show its kit with person.kit."

      assert {:ok, %{enrollment: "enrolled", identifier: identifier, kits: [kit]}} =
               call(person.ctx, %{"action" => "status"})

      assert identifier == person.identifier
      assert %{kind: "enrollment", phase: "accepted", deliverable: true} = kit
    end
  end

  describe "person.enroll_holder" do
    test "a device as holder is refused by the declaration; only a printed kit is one" do
      person = enrolled!()

      args = %{
        "action" => "enroll_holder",
        "recovery_secret" => Encoding.b64(:crypto.strong_rand_bytes(32)),
        "holder" => %{
          "kind" => "device",
          "recovery_secret" => Encoding.b64(:crypto.strong_rand_bytes(32))
        },
        "request_id" => request_id()
      }

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
      # this home does not hold, and one whose head has moved since.
      assert %Prima.Refusal{class: :unauthenticated} =
               refusal(call(device, Map.put(renew, "proof", proof)))

      assert %Prima.Refusal{class: :not_found} =
               refusal(
                 call(device, %{renew | "certificate" => %{certificate | "client_id" => "pcl_x"}})
               )

      {1, _} =
        Arca.Repo.update_all(
          from(p in PersonIdentity, where: p.user_id == ^person.user.id),
          set: [head_hash: Prima.Digest.sha256("rotated")]
        )

      assert %Prima.Refusal{class: :conflict, reason: :certification_ended, message: message} =
               refusal(call(device, renew))

      assert message =~ "certify it again"
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

      assert message =~ "sign in with that door again"

      assert %Prima.Refusal{class: :invalid_argument} =
               refusal(call(person.ctx, %{args | "provider" => "email"}))
    end

    test "the last door stays while the person holds no passkey here" do
      person = seated!()
      {:ok, [door]} = Arca.Users.identities(Prima.Actor.system(), person.user.id)

      assert %Prima.Refusal{class: :conflict, message: message} =
               refusal(call(person.ctx, %{"action" => "unlink_door", "door" => door.key}))

      assert message =~ "hold no passkey"
      assert message =~ "link another door"
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
  end
end
