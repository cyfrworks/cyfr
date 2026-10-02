# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.PersonRotationTest do
  @moduledoc """
  `person.rotate` through the gate, as the wire reaches it.

  The live key's rotation is a sensitive change: a session alone is asked
  for `key_rotation` and opens nothing. Under its proof the rotation reads
  the person's own directory, the one their genesis names, before it
  stages anything; an unreachable directory stages nothing and leaves the
  proof for the repeat. Every attempt is durable under its request id: a
  retry resumes the attempt that stands, signing no second key and asking
  no second proof, and an attempt that ended answers its recorded outcome.

  The directory's own answers (acceptance, a lost reply, a superseding
  recovery, a stale head) are driven against a scripted directory in
  `Sanctum.IdentityFreshnessTest`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Arca.Schemas.{IdentityAttempt, PersonIdentity}
  alias Prima.Identity
  alias Prima.Identity.Entry
  alias Sanctum.{Cipher, CipherAAD, Context}
  alias Sanctum.Tenancy.{Athanors, Users}

  # A directory this home cannot reach: a loopback port nothing listens on.
  @unreachable "https://localhost:1"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.RateLimiter.reset()
    on_exit(fn -> Prima.RateLimiter.reset() end)
    :ok
  end

  # A person seated in a group of their own, and the context their session
  # establishes there.
  defp seated! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|rotation-tool-#{n}",
        provider: "github",
        email: "rotation-tool#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Rotation tool #{n}")

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
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)
    %{user: user, athanor: athanor, ctx: ctx}
  end

  # The seated person, enrolled at a directory this home cannot reach:
  # their genesis names their own keys, signed by their operational key.
  defp enrolled! do
    %{user: user} = person = seated!()
    row = row(user.id)

    {:ok, operational} =
      Cipher.decrypt(row.operational_key_sealed, CipherAAD.person_key(user.id, :operational))

    {recovery, _} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, genesis} =
      Entry.genesis(
        live_key: row.live_public_key,
        operational_key: row.operational_public_key,
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

  # A rotation attempt of `person` opened as a call under `request_id`
  # left it: its entry signed and its key staged, at `staged`, then moved
  # along `phases`.
  defp attempt!(person, request_id, phases \\ []) do
    as = %Prima.Actor{user_id: person.user.id}
    {:ok, staged} = Sanctum.Person.sign_rotate(person.user.id, row(person.user.id).head_hash)

    {:ok, attempt} =
      Arca.IdentityAttempts.open(as, %{
        kind: "rotation",
        request_id: request_id,
        user_id: person.user.id,
        entry: staged.entry,
        entry_hash: staged.entry_hash,
        expected_head: row(person.user.id).head_hash,
        staged_live_public_key: staged.staged_live_public_key,
        staged_live_key_sealed: staged.staged_live_key_sealed
      })

    Enum.reduce(phases, attempt, fn {to, attrs}, attempt ->
      {:ok, moved} = Arca.IdentityAttempts.advance(as, attempt.id, attempt.phase, to, attrs)
      moved
    end)
  end

  defp row(user_id), do: Arca.Repo.get_by!(PersonIdentity, user_id: user_id)
  defp request_id, do: "req_#{System.unique_integer([:positive])}"

  defp rotations(user_id) do
    Arca.Repo.aggregate(
      from(a in IdentityAttempt, where: a.user_id == ^user_id and a.kind == "rotation"),
      :count
    )
  end

  # The person's pending confirmations, by the action each confirms and
  # its state.
  defp confirmations(person) do
    Arca.Repo.all(
      from(c in "pending_confirmations",
        where: c.user_id == ^person.user.id,
        select: %{action: c.action, state: c.state}
      )
    )
  end

  defp rotate(ctx, request_id),
    do: Grimoire.call_external("person", ctx, %{"action" => "rotate", "request_id" => request_id})

  defp refusal({:error, reason}), do: Grimoire.Error.classify(reason)

  describe "person.rotate" do
    test "a session alone is asked for key_rotation and opens nothing" do
      person = enrolled!()

      assert {:error, {:confirmation_required, %{operation: "person.rotate"}}} =
               rotate(person.ctx, request_id())

      assert [%{action: "key_rotation", state: "pending"}] = confirmations(person)
      assert rotations(person.user.id) == 0
    end

    test "under its proof, an unreachable directory stages nothing and leaves the proof standing" do
      person = enrolled!()
      before = row(person.user.id)
      id = request_id()

      {refused, log} =
        with_log(fn -> Sanctum.TestContext.confirming(person.ctx, &rotate(&1, id)) end)

      assert log =~ "could not answer a rotation"
      assert {:error, {:unavailable, "Your identity's directory"}} = refused
      assert %Prima.Refusal{class: :unavailable, message: message} = refusal(refused)
      assert message =~ "retry shortly"

      # Nothing staged or opened, and no key moved.
      assert rotations(person.user.id) == 0
      assert row(person.user.id).live_public_key == before.live_public_key

      # The proof was asked for and never consumed: the repeat may use it.
      # (The person's passkey registration was confirmed by a record of its
      # own.)
      assert [%{state: "confirmed"}] =
               for(c <- confirmations(person), c.action == "key_rotation", do: c)
    end

    test "a retry under a standing request id resumes it: no second key, no second proof" do
      person = enrolled!()
      id = request_id()
      opened = attempt!(person, id)

      capture_log(fn ->
        assert {:error, {:unavailable, "Your identity's directory"}} = rotate(person.ctx, id)
      end)

      # The same attempt moved on to its submission, with the same entry
      # and the same staged key; nothing else was opened or asked.
      resumed = Arca.Repo.get!(IdentityAttempt, opened.id)
      assert resumed.phase == "submitted"
      assert resumed.entry == opened.entry
      assert resumed.staged_live_public_key == opened.staged_live_public_key
      assert rotations(person.user.id) == 1
      assert confirmations(person) == []
    end

    test "an attempt that ended answers its recorded outcome under its request id" do
      person = enrolled!()

      done = request_id()

      completed =
        attempt!(person, done, [
          {"submitted", %{}},
          {"accepted", %{outcome: "accepted"}},
          {"keys_active", %{}},
          {"completed", %{}}
        ])

      assert {:ok, %{request_id: ^done, phase: "completed", key_epoch: epoch}} =
               rotate(person.ctx, done)

      assert epoch == completed.entry_hash

      superseded = request_id()

      attempt!(person, superseded, [
        {"submitted", %{}},
        {"superseded", %{outcome: "superseded"}}
      ])

      assert %Prima.Refusal{class: :conflict, message: message} =
               refusal(rotate(person.ctx, superseded))

      assert message =~ "replaced this rotation before it took effect"

      stale = request_id()
      attempt!(person, stale, [{"submitted", %{}}, {"refused", %{outcome: "stale_head"}}])

      assert %Prima.Refusal{class: :conflict, message: message} =
               refusal(rotate(person.ctx, stale))

      assert message =~ "moved past this home's head"
    end

    test "another rotation in progress is named, before any proof is asked" do
      person = enrolled!()
      standing = request_id()
      attempt!(person, standing)

      assert %Prima.Refusal{class: :conflict, message: message} =
               refusal(rotate(person.ctx, request_id()))

      assert message =~ standing
      assert rotations(person.user.id) == 1
    end

    test "a person never enrolled, one whose keys are elsewhere, and a malformed id rotate nothing" do
      %{ctx: unenrolled, user: user} = seated!()

      assert %Prima.Refusal{class: :conflict, message: message} =
               refusal(rotate(unenrolled, request_id()))

      assert message =~ "enrolled identity"

      assert %Prima.Refusal{class: :invalid_argument} =
               refusal(rotate(unenrolled, "not a request id!"))

      %{ctx: remote, user: remote_user} = seated!()
      Arca.Repo.delete_all(from(p in PersonIdentity, where: p.user_id == ^remote_user.id))

      {:ok, _} =
        Arca.PersonIdentities.create(Prima.Actor.system(), %{
          user_id: remote_user.id,
          provenance: "remote",
          identifier: "per_" <> String.duplicate("e", 64),
          directory_url: @unreachable
        })

      assert %Prima.Refusal{class: :conflict, message: message} =
               refusal(rotate(remote, request_id()))

      assert message =~ "another home"
      assert rotations(user.id) == 0
      assert rotations(remote_user.id) == 0
    end
  end
end
