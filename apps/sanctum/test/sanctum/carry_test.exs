# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CarryTest do
  @moduledoc """
  The sign-in carry at the person's signing home: a pending action for one
  other home and the one operation `join`, its envelope signed by the live
  key under the head the person's row holds, the genesis carried as its
  payload, bounded before anything is stored; and the navigation outcome
  recorded once, an exact retry answering it with nothing applied again
  and with the requester's standing read again. The sweep also removes a
  head a relying home's challenge cached for no one here, once a carry
  could no longer rely on it.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{CarryAction, DirectoryHead, PersonIdentity}
  alias Prima.Carry
  alias Prima.Carry.Envelope
  alias Prima.Identity
  alias Prima.Identity.{Entry, RecoverRequest}
  alias Sanctum.{Caller, Cipher, CipherAAD, Context}
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @destination "https://hub.example"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    on_exit(fn -> Arca.Cache.delete_match({:established, :_, :_, :_}) end)
    :ok
  end

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)
  defp request_id, do: "req_#{System.unique_integer([:positive])}"
  defp row(user_id), do: Arca.Repo.get_by!(PersonIdentity, user_id: user_id)

  # A person seated in a group of their own, and their session's context.
  defp seated! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|carry-#{n}",
        provider: "github",
        email: "carry#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Carry #{n}")
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: athanor.id)

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
    {:ok, ctx} = Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)
    %{user: user, ctx: ctx, token: session.token}
  end

  # The seated person, enrolled: their genesis names their own keys and a
  # recovery key the test holds, and the directory accepted it.
  defp enrolled! do
    %{user: user} = person = seated!()
    keys = row(user.id)

    {:ok, operational} =
      Cipher.decrypt(keys.operational_key_sealed, CipherAAD.person_key(user.id, :operational))

    {recovery, recovery_private} = keypair()

    {:ok, genesis} =
      Entry.genesis(
        live_key: keys.live_public_key,
        operational_key: keys.operational_public_key,
        recovery_keys: [recovery],
        directory: "https://dir.example"
      )

    genesis = Identity.sign(genesis, operational)
    as = %Prima.Actor{user_id: user.id}

    {:ok, attempt} =
      Arca.IdentityAttempts.open(as, %{
        kind: "enrollment",
        request_id: request_id(),
        user_id: user.id,
        identifier: Identity.identifier(genesis),
        directory_url: "https://dir.example",
        genesis: Identity.canonical(genesis),
        request_digest: Identity.hash(genesis),
        kit_seed_sealed: "sealed-kit-seed"
      })

    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "staged", "submitted")
    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "submitted", "accepted")
    Map.merge(person, %{genesis: genesis, recovery: recovery_private})
  end

  # What a relying home verifies an envelope against: the identity's
  # verified head, from its log.
  defp state(log) do
    {:ok, state} = Identity.verify_chain(log)
    state
  end

  defp verify(envelope, state, began) do
    Envelope.verify(
      envelope,
      state,
      [destination: @destination, action_id: began.action_id, payload_digest: digest(began)],
      now: System.os_time(:millisecond),
      skew: 60_000,
      max_age: 300_000
    )
  end

  defp digest(began) do
    {:ok, digest} = Carry.payload_digest(began.payload)
    digest
  end

  # A head cached for `identifier`, as a relying home's challenge caches
  # one, last verified `ms` before the database's clock.
  defp head!(identifier, ms) do
    epoch = Prima.Digest.sha256("head-#{System.unique_integer()}")

    {:ok, _} =
      Arca.DirectoryHeads.put(Prima.Actor.system(), %{
        identifier: identifier,
        genesis: "genesis-bytes",
        directory_url: "https://dir.example",
        head_hash: epoch,
        key_epoch: epoch,
        recovery_epoch: epoch,
        state: "{}"
      })

    {1, _} =
      Arca.Repo.update_all(from(h in DirectoryHead, where: h.identifier == ^identifier),
        set: [verified_at: DateTime.add(Arca.ServerMetaStorage.now!(), -ms, :millisecond)]
      )

    identifier
  end

  defp nobody, do: "per_" <> Prima.Digest.sha256_hex("nobody-#{System.unique_integer()}")

  defp cached?(identifier),
    do: Arca.Repo.exists?(from(h in DirectoryHead, where: h.identifier == ^identifier))

  describe "begin/3" do
    test "signs one action for one destination, carrying the genesis, and stores it pending" do
      person = enrolled!()

      assert {:ok, began} = Sanctum.Carry.begin(person.ctx, @destination, "join")
      assert began.destination == @destination
      assert began.return_url == Sanctum.Person.home() <> "/carry"
      assert began.payload == %{"genesis" => Entry.encode(person.genesis)}

      # The fragment is what the browser carries, and reads back whole.
      assert {:ok, %{envelope: envelope, payload: payload}} = Carry.parse_fragment(began.fragment)
      assert payload == began.payload
      assert Envelope.encode(envelope) == began.envelope

      # A relying home verifies it under the identity's head, and holds the
      # carried genesis to the identifier before it resolves anything.
      assert {:ok, _} = verify(envelope, state([person.genesis]), began)

      assert {:ok, located} =
               Identity.locate(payload["genesis"], Identity.identifier(person.genesis))

      assert located == person.genesis

      action = Arca.Repo.get!(CarryAction, began.action_id)
      assert action.phase == "pending"
      assert action.destination_home == @destination
      assert action.key_epoch == row(person.user.id).head_hash
      assert action.payload_digest == digest(began)
    end

    test "refuses this home, a destination that is no origin, another operation, and an " <>
           "unenrolled person" do
      person = enrolled!()

      assert {:error, {:invalid_argument, _}} =
               Sanctum.Carry.begin(person.ctx, Sanctum.Person.home(), "join")

      assert {:error, {:invalid_argument, _}} =
               Sanctum.Carry.begin(person.ctx, "https://hub.example/path", "join")

      assert {:error, {:invalid_argument, _}} =
               Sanctum.Carry.begin(person.ctx, @destination, "transfer")

      unenrolled = seated!()
      assert {:error, :not_enrolled} = Sanctum.Carry.begin(unenrolled.ctx, @destination, nil)
      assert Arca.Repo.aggregate(CarryAction, :count) == 0
    end

    test "holds twenty pending at once, and releases the expired ones as it begins another" do
      person = enrolled!()

      began =
        for _ <- 1..Arca.CarryActions.max_pending() do
          {:ok, began} = Sanctum.Carry.begin(person.ctx, @destination, "join")
          began
        end

      assert {:error, {:conflict, message}} =
               Sanctum.Carry.begin(person.ctx, @destination, "join")

      assert message =~ "Twenty"

      oldest = hd(began).action_id
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      {1, _} =
        Arca.Repo.update_all(from(a in CarryAction, where: a.id == ^oldest),
          set: [expires_at: past]
        )

      assert {:ok, _} = Sanctum.Carry.begin(person.ctx, @destination, "join")
      assert %{phase: "expired", payload: nil} = Arca.Repo.get!(CarryAction, oldest)
    end
  end

  describe "pending/1" do
    test "lists the person's own unexpired pending carries, and nothing a carry signs or carries" do
      person = enrolled!()
      other = enrolled!()
      {:ok, first} = Sanctum.Carry.begin(person.ctx, @destination, "join")
      {:ok, second} = Sanctum.Carry.begin(person.ctx, "https://other-hub.example", "join")
      {:ok, theirs} = Sanctum.Carry.begin(other.ctx, @destination, "join")
      {:ok, done} = Sanctum.Carry.begin(person.ctx, @destination, "join")
      {:ok, _} = Sanctum.Carry.complete(person.ctx, done.action_id, "admitted")
      {:ok, gone} = Sanctum.Carry.begin(person.ctx, @destination, "join")

      {1, _} =
        Arca.Repo.update_all(from(a in CarryAction, where: a.id == ^gone.action_id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert {:ok, listed} = Sanctum.Carry.pending(person.ctx)
      assert Enum.map(listed, & &1.action_id) == [first.action_id, second.action_id]

      [entry, _] = listed
      head = row(person.user.id).head_hash

      assert entry == %{
               action_id: first.action_id,
               destination: @destination,
               phase: "pending",
               expires_at: first.expires_at,
               began_at: Arca.Repo.get!(CarryAction, first.action_id).inserted_at,
               key_epoch: head
             }

      # The other person's is theirs alone.
      assert {:ok, [%{action_id: action_id}]} = Sanctum.Carry.pending(other.ctx)
      assert action_id == theirs.action_id
    end

    test "answers nobody without a person behind the context" do
      person = enrolled!()
      {:ok, _} = Sanctum.Carry.begin(person.ctx, @destination, "join")

      assert {:error, :unauthenticated} =
               Sanctum.Carry.pending(%{person.ctx | authenticated: false})

      assert {:error, :unauthenticated} = Sanctum.Carry.pending(%{person.ctx | plane: :guest})
    end
  end

  describe "sweep/1" do
    test "expires every person's carries past their expiry and clears their payloads; open ones stand" do
      person = enrolled!()
      other = enrolled!()
      {:ok, gone} = Sanctum.Carry.begin(person.ctx, @destination, "join")
      {:ok, open} = Sanctum.Carry.begin(other.ctx, @destination, "join")

      {1, _} =
        Arca.Repo.update_all(from(a in CarryAction, where: a.id == ^gone.action_id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert {:ok, %{expired: 1, removed: 0}} = Sanctum.Carry.sweep(carries: 500, heads: 500)
      assert %{phase: "expired", payload: nil} = Arca.Repo.get!(CarryAction, gone.action_id)
      assert %{phase: "pending", payload: payload} = Arca.Repo.get!(CarryAction, open.action_id)
      assert is_binary(payload)
    end

    test "removes a head cached for no one here once a carry could no longer rely on it, and keeps a person's" do
      lifetime = Arca.CarryActions.lifetime_ms()

      # A person with a carry open: their head stays whatever its age.
      person = enrolled!()
      {:ok, _open} = Sanctum.Carry.begin(person.ctx, @destination, "join")
      held = head!(Identity.identifier(person.genesis), 10 * lifetime)

      orphan = head!(nobody(), lifetime + 1_000)
      young = head!(nobody(), lifetime - 60_000)

      assert {:ok, %{expired: 0, removed: 0, heads: 1}} =
               Sanctum.Carry.sweep(carries: 500, heads: 500)

      refute cached?(orphan)
      assert cached?(held)
      assert cached?(young)
    end

    test "removes at most its batch of heads in one pass" do
      lifetime = Arca.CarryActions.lifetime_ms()
      first = head!(nobody(), 3 * lifetime)
      second = head!(nobody(), 2 * lifetime)

      assert {:ok, %{heads: 1}} = Sanctum.Carry.sweep(heads: 1)
      refute cached?(first)
      assert cached?(second)

      assert {:ok, %{heads: 1}} = Sanctum.Carry.sweep(heads: 1)
      refute cached?(second)
    end

    test "sweeps only the kinds it names: heads alone move no carry, and carries alone no head" do
      person = enrolled!()
      {:ok, gone} = Sanctum.Carry.begin(person.ctx, @destination, "join")

      {1, _} =
        Arca.Repo.update_all(from(a in CarryAction, where: a.id == ^gone.action_id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      orphan = head!(nobody(), 2 * Arca.CarryActions.lifetime_ms())

      assert {:ok, %{expired: 0, removed: 0, heads: 1}} = Sanctum.Carry.sweep(heads: 500)
      refute cached?(orphan)
      assert %{phase: "pending"} = Arca.Repo.get!(CarryAction, gone.action_id)

      orphan = head!(nobody(), 2 * Arca.CarryActions.lifetime_ms())

      assert {:ok, %{expired: 1, removed: 0, heads: 0}} = Sanctum.Carry.sweep(carries: 500)
      assert cached?(orphan)
      assert %{phase: "expired"} = Arca.Repo.get!(CarryAction, gone.action_id)

      assert_raise ArgumentError, fn -> Sanctum.Carry.sweep(threads: 500) end
    end
  end

  describe "cancel/2" do
    test "ends the person's own open carry, clears its payload, and is the same again" do
      person = enrolled!()
      {:ok, began} = Sanctum.Carry.begin(person.ctx, @destination, "join")

      assert {:ok, %{action_id: action_id, phase: "cancelled"}} =
               Sanctum.Carry.cancel(person.ctx, began.action_id)

      assert action_id == began.action_id
      assert %{phase: "cancelled", payload: nil} = Arca.Repo.get!(CarryAction, began.action_id)
      assert {:ok, []} = Sanctum.Carry.pending(person.ctx)

      assert {:ok, %{phase: "cancelled"}} = Sanctum.Carry.cancel(person.ctx, began.action_id)

      # Cancelled, nothing more is recorded for it.
      assert {:error, {:conflict, _}} =
               Sanctum.Carry.complete(person.ctx, began.action_id, "admitted")
    end

    test "another person's carry, or none, is not found, and stays as it was" do
      person = enrolled!()
      other = enrolled!()
      {:ok, began} = Sanctum.Carry.begin(person.ctx, @destination, "join")

      assert {:error, {:not_found, "carry", _}} =
               Sanctum.Carry.cancel(other.ctx, began.action_id)

      assert {:error, {:not_found, "carry", _}} = Sanctum.Carry.cancel(person.ctx, "car_nobody")
      assert %{phase: "pending"} = Arca.Repo.get!(CarryAction, began.action_id)
    end

    test "a carry whose outcome is recorded has nothing left to cancel" do
      person = enrolled!()
      {:ok, began} = Sanctum.Carry.begin(person.ctx, @destination, "join")
      {:ok, _} = Sanctum.Carry.complete(person.ctx, began.action_id, "refused")

      assert {:error, {:conflict, _}} = Sanctum.Carry.cancel(person.ctx, began.action_id)

      assert %{phase: "completed", outcome: "refused"} =
               Arca.Repo.get!(CarryAction, began.action_id)
    end
  end

  describe "complete/3" do
    test "records the outcome once; an exact retry answers it and applies nothing again" do
      person = enrolled!()
      {:ok, began} = Sanctum.Carry.begin(person.ctx, @destination, "join")

      # It answers the destination this home's row names, where the
      # person's browser goes next.
      assert {:ok, %{phase: "completed", outcome: "admitted", destination: @destination}} =
               Sanctum.Carry.complete(person.ctx, began.action_id, "admitted")

      done = Arca.Repo.get!(CarryAction, began.action_id)
      assert done.payload == nil

      assert {:ok, %{phase: "completed", outcome: "admitted"}} =
               Sanctum.Carry.complete(person.ctx, began.action_id, "admitted")

      assert Arca.Repo.get!(CarryAction, began.action_id).revision == done.revision

      # Another outcome under the same action is refused.
      assert {:error, {:conflict, _}} =
               Sanctum.Carry.complete(person.ctx, began.action_id, "refused")

      assert {:error, {:invalid_argument, _}} =
               Sanctum.Carry.complete(person.ctx, began.action_id, "joined")
    end

    test "another person's action, and an expired one, are refused" do
      person = enrolled!()
      other = enrolled!()
      {:ok, began} = Sanctum.Carry.begin(person.ctx, @destination, "join")

      assert {:error, {:not_found, "carry", _}} =
               Sanctum.Carry.complete(other.ctx, began.action_id, "admitted")

      past = DateTime.add(DateTime.utc_now(), -1, :second)

      {1, _} =
        Arca.Repo.update_all(from(a in CarryAction, where: a.id == ^began.action_id),
          set: [expires_at: past]
        )

      assert {:error, {:conflict, message}} =
               Sanctum.Carry.complete(person.ctx, began.action_id, "admitted")

      assert message =~ "expired"
    end

    test "a retry after a lost reply reads the requester's standing again" do
      person = enrolled!()
      {:ok, began} = Sanctum.Carry.begin(person.ctx, @destination, "join")
      {:ok, _} = Sanctum.Carry.complete(person.ctx, began.action_id, "admitted")

      :ok = Sanctum.Session.destroy(person.token)

      assert {:error, _gone} = Sanctum.Carry.complete(person.ctx, began.action_id, "admitted")
    end

    test "an action signed under keys a recovery since replaced is refused, as its envelope is" do
      person = enrolled!()
      {:ok, began} = Sanctum.Carry.begin(person.ctx, @destination, "join")
      {:ok, envelope} = Envelope.decode(began.envelope)

      # A recovery elsewhere: new online keys, signed by the kit.
      {live, _} = keypair()
      {operational, _} = keypair()
      genesis_state = state([person.genesis])

      {:ok, request} =
        RecoverRequest.new(
          identifier: genesis_state.identifier,
          directory: genesis_state.directory,
          live_key: live,
          operational_key: operational,
          expected_revision: 0,
          request_id: request_id()
        )

      {:ok, recover} =
        Entry.recover(genesis_state.head, Identity.sign(request, person.recovery))

      recovered = state([person.genesis, recover])

      # Every relying home refuses the old envelope under the new head.
      assert {:error, :stale_key_epoch} = verify(envelope, recovered, began)

      # And the signing home records no outcome for it once its own head moved.
      {1, _} =
        Arca.Repo.update_all(
          from(p in PersonIdentity, where: p.user_id == ^person.user.id),
          set: [head_hash: recovered.head]
        )

      assert {:error, {:conflict, message}} =
               Sanctum.Carry.complete(person.ctx, began.action_id, "admitted")

      assert message =~ "replaced"
    end
  end
end
