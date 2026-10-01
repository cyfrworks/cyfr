# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.AssertionTest do
  @moduledoc """
  `person.assert` through the gate, as the signing home answers it: an
  assertion for the `cyfr` door at another home, signed only for the
  person's own pending carry whose destination is the audience, under a
  fresh `remote_sign_in` proof, and recorded with that carry once. A
  session alone, a stolen one among them, is answered the confirmation
  signal and signs nothing; an exact retry answers the same assertion; a
  proof is spent on one carry and one challenge.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.PersonIdentity
  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry}
  alias Sanctum.{Cipher, CipherAAD, Context, TestContext}
  alias Sanctum.Tenancy.{Athanors, Users}

  @directory "https://dir.example"
  @hub "https://hub.example"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.RateLimiter.reset()
    on_exit(fn -> Prima.RateLimiter.reset() end)
    :ok
  end

  # A person seated in a group of their own, enrolled here: their genesis
  # signed by their operational key and their enrollment accepted.
  defp enrolled! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|assert-#{n}",
        provider: "github",
        email: "assert#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Assert #{n}")
    keys = Arca.Repo.get_by!(PersonIdentity, user_id: user.id)

    {:ok, operational} =
      Cipher.decrypt(keys.operational_key_sealed, CipherAAD.person_key(user.id, :operational))

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
        request_id: "req_#{n}",
        user_id: user.id,
        identifier: Identity.identifier(genesis),
        directory_url: @directory,
        genesis: Identity.canonical(genesis),
        request_digest: Identity.hash(genesis),
        kit_seed_sealed: "sealed-kit-seed"
      })

    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "staged", "submitted")
    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "submitted", "accepted")

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
    %{user: user, ctx: ctx, genesis: genesis}
  end

  defp call(ctx, args), do: Grimoire.call_external("person", ctx, args)

  # The person begins a sign-in carry to `destination` here, as their
  # browser's `/carry` page asks.
  defp carry!(ctx, destination \\ @hub) do
    {:ok, carry} =
      call(ctx, %{"action" => "carry_begin", "destination" => destination, "operation" => "join"})

    carry
  end

  defp head(user_id), do: Arca.Repo.get_by!(PersonIdentity, user_id: user_id).head_hash

  defp assert_args(person, carry, challenge, audience \\ nil) do
    %{
      "action" => "assert",
      "audience" => audience || carry.destination,
      "challenge" => Encoding.b64(challenge),
      "action_id" => carry.action_id,
      "key_epoch" => head(person.user.id)
    }
  end

  test "a session alone, a stolen one among them, is asked for a proof and signs nothing" do
    person = enrolled!()
    carry = carry!(person.ctx)
    args = assert_args(person, carry, :crypto.strong_rand_bytes(32))

    assert {:error, {:confirmation_required, %{operation: "person.assert"}}} =
             call(person.ctx, args)

    assert {:ok, %{assertion: nil}} =
             Arca.CarryActions.get(%Prima.Actor{user_id: person.user.id}, carry.action_id)
  end

  test "under a fresh proof, answers the assertion for exactly that carry, its genesis and the callback" do
    person = enrolled!()
    carry = carry!(person.ctx)
    challenge = :crypto.strong_rand_bytes(32)
    args = assert_args(person, carry, challenge)

    assert {:ok, answer} = TestContext.confirming(person.ctx, &call(&1, args))
    assert answer.genesis == Entry.encode(person.genesis)

    # The callback is the audience's sign-in page, the transport in its
    # fragment, which the audience opens and verifies under the person's
    # current head.
    "https://hub.example/login#cyfr=" <> fragment = answer.callback
    {:ok, transport} = Prima.Carry.decode_object(fragment)
    assert transport == %{"assertion" => answer.assertion, "genesis" => answer.genesis}

    assert {:ok, %{assertion: assertion, genesis: genesis}} =
             Prima.PersonAssertion.open(transport)

    {:ok, state} = Identity.verify_chain([genesis])

    assert {:ok, _} =
             Prima.PersonAssertion.verify(assertion, state,
               audience: @hub,
               challenge: challenge,
               action_id: carry.action_id,
               now: System.os_time(:millisecond)
             )

    # An exact retry answers the same assertion, with no new proof.
    assert {:ok, %{assertion: same}} = call(person.ctx, args)
    assert same == answer.assertion
  end

  test "an audience no pending carry names, and another challenge for a carry, are refused" do
    person = enrolled!()
    carry = carry!(person.ctx)
    challenge = :crypto.strong_rand_bytes(32)

    assert {:error, {:invalid_argument, _}} =
             call(person.ctx, assert_args(person, carry, challenge, "https://other.example"))

    assert {:ok, _} =
             TestContext.confirming(person.ctx, &call(&1, assert_args(person, carry, challenge)))

    assert {:error, {:conflict, _}} =
             call(person.ctx, assert_args(person, carry, :crypto.strong_rand_bytes(32)))

    assert {:error, {:invalid_argument, _}} =
             call(person.ctx, %{assert_args(person, carry, challenge) | "challenge" => "short"})
  end

  test "a proof is spent on one carry: reused for another hub's, it signs nothing" do
    person = enrolled!()
    first = carry!(person.ctx)
    challenge = :crypto.strong_rand_bytes(32)
    args = assert_args(person, first, challenge)

    {:error, {:confirmation_required, %{id: id}}} = call(person.ctx, args)
    TestContext.passkey!(person.user.id)
    TestContext.prove!(person.ctx, id)
    proven = %{person.ctx | confirmation_id: id}
    assert {:ok, _} = call(proven, args)

    second = carry!(person.ctx, "https://other-hub.example")

    assert {:error, {:confirmation_required, %{id: another}}} =
             call(proven, assert_args(person, second, challenge))

    assert another != id
  end

  test "a person whose keys are at another home signs nothing here" do
    person = enrolled!()
    carry = carry!(person.ctx)
    args = assert_args(person, carry, :crypto.strong_rand_bytes(32))

    {1, _} =
      Arca.Repo.update_all(
        from(p in PersonIdentity, where: p.user_id == ^person.user.id),
        set: [provenance: "remote", live_key_sealed: nil, operational_key_sealed: nil]
      )

    assert {:error, {:conflict, message}} = call(person.ctx, args)
    assert message =~ "another home"
  end
end
