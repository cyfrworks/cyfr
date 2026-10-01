# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CarryActionsTest do
  @moduledoc """
  The sign-in carry's durable actions: bounded pending source actions of
  one person, a challenge and an assertion each attached once, phases
  moved conditionally, completion applied once with an exact retry
  answering the recorded result and changed content refused, payloads
  cleared at a terminal phase; and a relying home's login receipt, unique
  per home and challenge, bound to its browser and assertion.
  """

  # Takes the cell's slot, which is process-wide; each case restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{CarryActions, Users}
  alias Arca.Schemas.{CarryAction, CellLease}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    slot = hold_slot!()
    {:ok, person: person!(), slot: slot}
  end

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  # The writes under test are fenced by the member's slot: a claimant runs
  # and this member holds its slot. The process-wide standing and the claim
  # switch are restored after each case.
  defp hold_slot! do
    saved = Map.new(@slot_keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot", 60_000)
    slot
  end

  defp server, do: Prima.Actor.system()
  defp digest(seed), do: Prima.Digest.sha256("#{seed}-#{System.unique_integer()}")

  defp person! do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()

    {:ok, person} =
      Users.mint(
        server(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          provider: "github",
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        %{
          key: "github|https://github.com|car#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "car#{n}",
          first_seen_at: now,
          last_seen_at: now
        }
      )

    person
  end

  defp as(person), do: %Prima.Actor{user_id: person.id}

  defp source(person, overrides \\ %{}) do
    payload = "payload-#{System.unique_integer()}"

    Map.merge(
      %{
        user_id: person.id,
        action_id: "car_#{System.unique_integer([:positive])}",
        source_home: "https://a.example",
        destination_home: "https://b.example",
        return_url: "https://a.example/carry",
        payload: payload,
        payload_digest: Prima.Digest.sha256(payload),
        key_epoch: digest("epoch")
      },
      overrides
    )
  end

  defp receipt(person) do
    %{
      action_id: "car_#{System.unique_integer([:positive])}",
      destination_home: "https://b.example",
      source_home: "https://a.example",
      challenge_id: "chl_#{System.unique_integer([:positive])}",
      user_id: person.id,
      key_epoch: digest("epoch"),
      browser_binding_digest: digest("browser"),
      assertion_digest: digest("assertion"),
      outcome: "admitted"
    }
  end

  describe "opening" do
    test "opens a pending action with a five-minute lifetime", %{person: person} do
      assert {:ok, action} = CarryActions.open(as(person), source(person))
      assert action.phase == "pending"
      assert action.kind == "source"
      assert action.operation == "join"
      lifetime = DateTime.diff(action.expires_at, action.inserted_at, :millisecond)
      assert lifetime == CarryActions.lifetime_ms()
    end

    test "refuses an oversize payload, a twenty-first pending action and another person's", %{
      person: person
    } do
      big = String.duplicate("x", CarryActions.max_payload_bytes() + 1)

      assert {:error, :carry_too_large} =
               CarryActions.open(as(person), source(person, %{payload: big}))

      for _ <- 1..CarryActions.max_pending(),
          do: {:ok, _} = CarryActions.open(as(person), source(person))

      assert {:error, :too_many_pending} = CarryActions.open(as(person), source(person))

      assert {:error, :cross_tenant} =
               CarryActions.open(%Prima.Actor{user_id: "usr_other"}, source(person))
    end

    test "opening ends the person's own expired actions first, releasing their payloads", %{
      person: person
    } do
      other = person!()
      {:ok, mine} = CarryActions.open(as(person), source(person))
      {:ok, theirs} = CarryActions.open(as(other), source(other))
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      {2, _} =
        Arca.Repo.update_all(from(a in CarryAction, where: a.id in ^[mine.id, theirs.id]),
          set: [expires_at: past]
        )

      assert {:ok, _opened} = CarryActions.open(as(person), source(person))

      assert {:ok, %{phase: "expired", payload: nil, retain_until: %DateTime{}}} =
               CarryActions.get(as(person), mine.id)

      # Another person's expired action waits for the sweep.
      assert {:ok, %{phase: "pending", payload: payload}} = CarryActions.get(as(other), theirs.id)
      assert is_binary(payload)
    end
  end

  describe "the challenge and the assertion" do
    test "are attached once each; the same value again answers the action", %{person: person} do
      {:ok, action} = CarryActions.open(as(person), source(person))
      challenge = %{challenge: "b-challenge", challenge_digest: digest("challenge")}
      assertion = %{assertion: "signed-assertion", assertion_digest: digest("assertion")}

      assert {:error, :no_challenge} =
               CarryActions.record_assertion(as(person), action.id, assertion)

      assert {:ok, attached} = CarryActions.attach_challenge(as(person), action.id, challenge)
      assert {:ok, ^attached} = CarryActions.attach_challenge(as(person), action.id, challenge)

      assert {:error, :challenge_attached} =
               CarryActions.attach_challenge(as(person), action.id, %{
                 challenge: "other",
                 challenge_digest: digest("other")
               })

      assert {:ok, recorded} = CarryActions.record_assertion(as(person), action.id, assertion)
      assert {:ok, ^recorded} = CarryActions.record_assertion(as(person), action.id, assertion)

      assert {:error, :assertion_recorded} =
               CarryActions.record_assertion(as(person), action.id, %{
                 assertion: "another",
                 assertion_digest: digest("another")
               })
    end

    test "an assertion is recorded with what its also: closure writes, or not at all", %{
      person: person
    } do
      {:ok, action} = CarryActions.open(as(person), source(person))
      challenge = %{challenge: "b-challenge", challenge_digest: digest("challenge")}
      {:ok, _} = CarryActions.attach_challenge(as(person), action.id, challenge)
      assertion = %{assertion: "signed-assertion", assertion_digest: digest("assertion")}

      # A closure that refuses leaves nothing written.
      assert {:error, :proof_spent} =
               CarryActions.record_assertion(as(person), action.id, assertion,
                 also: fn _action -> {:error, :proof_spent} end
               )

      assert {:ok, %{assertion: nil}} = CarryActions.get(as(person), action.id)

      # One that answers runs in the write's transaction, handed the action
      # as written.
      test = self()

      assert {:ok, recorded} =
               CarryActions.record_assertion(as(person), action.id, assertion,
                 also: fn written ->
                   send(test, {:also, written.assertion, Arca.Repo.in_transaction?()})
                   :ok
                 end
               )

      assert_received {:also, "signed-assertion", true}
      assert recorded.assertion == "signed-assertion"

      # The same assertion again runs nothing: nothing new is issued.
      assert {:ok, ^recorded} =
               CarryActions.record_assertion(as(person), action.id, assertion,
                 also: fn _action -> flunk("no second issue") end
               )
    end

    test "an assertion locks the action's person before the action, the standing order its also: closure keeps",
         %{person: person} do
      {:ok, action} = CarryActions.open(as(person), source(person))
      challenge = %{challenge: "b-challenge", challenge_digest: digest("challenge")}
      {:ok, _} = CarryActions.attach_challenge(as(person), action.id, challenge)
      assertion = %{assertion: "signed-assertion", assertion_digest: digest("assertion")}

      # Another person's actor locks no one and is refused.
      other = person!()

      assert {:error, :cross_tenant} =
               CarryActions.record_assertion(as(other), action.id, assertion)

      test = self()
      handler = "carry-lock-order-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == test and meta[:source] in ["users", "carry_actions"],
              do: send(test, {:statement, meta[:source], meta[:query]})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      # The closure takes the person's lock again, as consuming their
      # confirmation does when it reads their standing again.
      assert {:ok, %{assertion: "signed-assertion"}} =
               CarryActions.record_assertion(as(person), action.id, assertion,
                 also: fn _written ->
                   _person = Arca.DirectoryHeads.lock_person!(person.id)
                   :ok
                 end
               )

      :telemetry.detach(handler)

      assert [{"users", first} | rest] = statements()
      assert first =~ "carry_actions"
      assert Enum.any?(rest, &match?({"carry_actions", _}, &1))

      if Arca.Repo.adapter() == Ecto.Adapters.Postgres do
        assert first =~ "FOR UPDATE"
        assert {"carry_actions", locked} = Enum.find(rest, &match?({"carry_actions", _}, &1))
        assert locked =~ "FOR UPDATE"
      end
    end
  end

  defp statements(acc \\ []) do
    receive do
      {:statement, source, query} -> statements([{source, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the member fence" do
    test "a stale member attaches no challenge and records no assertion", %{
      person: person,
      slot: slot
    } do
      {:ok, bare} = CarryActions.open(as(person), source(person))
      {:ok, challenged} = CarryActions.open(as(person), source(person))
      challenge = %{challenge: "b-challenge", challenge_digest: digest("challenge")}
      {:ok, _} = CarryActions.attach_challenge(as(person), challenged.id, challenge)

      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} = CarryActions.attach_challenge(as(person), bare.id, challenge)

      assert {:error, :not_owner} =
               CarryActions.record_assertion(as(person), challenged.id, %{
                 assertion: "signed-assertion",
                 assertion_digest: digest("assertion")
               })

      assert {:ok, %{challenge: nil}} = CarryActions.get(as(person), bare.id)
      assert {:ok, %{assertion: nil}} = CarryActions.get(as(person), challenged.id)
    end
  end

  describe "phases" do
    test "a pending action consumed twice with the same outcome: one mutation, one answer", %{
      person: person
    } do
      attrs = source(person)
      {:ok, action} = CarryActions.open(as(person), attrs)

      done = %{id: action.id, outcome: "admitted", payload_digest: attrs.payload_digest}
      assert {:ok, completed} = CarryActions.consume(as(person), done)
      assert completed.phase == "completed"
      assert is_nil(completed.payload)
      assert %DateTime{} = completed.retain_until

      assert {:ok, ^completed} = CarryActions.consume(as(person), done)

      assert {:error, :changed_content} =
               CarryActions.consume(as(person), %{done | outcome: "refused"})

      assert {:error, :changed_content} =
               CarryActions.consume(as(person), %{done | payload_digest: digest("changed")})
    end

    test "delivery names the revision it read; a cancelled action is not completed", %{
      person: person
    } do
      attrs = source(person)
      {:ok, action} = CarryActions.open(as(person), attrs)

      assert {:error, :stale} = CarryActions.deliver(as(person), action.id, action.revision + 1)

      assert {:ok, %{phase: "delivered"}} =
               CarryActions.deliver(as(person), action.id, action.revision)

      assert {:ok, %{phase: "cancelled", payload: nil}} =
               CarryActions.cancel(as(person), action.id)

      assert {:error, :cancelled} =
               CarryActions.consume(as(person), %{
                 id: action.id,
                 outcome: "admitted",
                 payload_digest: attrs.payload_digest
               })
    end

    test "an expired action is refused, and the sweep expires and later removes it", %{
      person: person
    } do
      attrs = source(person)
      {:ok, action} = CarryActions.open(as(person), attrs)
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      {1, _} =
        Arca.Repo.update_all(from(a in CarryAction, where: a.id == ^action.id),
          set: [expires_at: past]
        )

      assert {:error, :expired} =
               CarryActions.consume(as(person), %{
                 id: action.id,
                 outcome: "admitted",
                 payload_digest: attrs.payload_digest
               })

      assert {:ok, %{expired: expired}} = CarryActions.sweep(server())
      assert expired >= 1
      assert {:ok, %{phase: "expired", payload: nil}} = CarryActions.get(as(person), action.id)

      {1, _} =
        Arca.Repo.update_all(from(a in CarryAction, where: a.id == ^action.id),
          set: [retain_until: past]
        )

      assert {:ok, %{removed: removed}} = CarryActions.sweep(server())
      assert removed >= 1
      assert {:error, :not_found} = CarryActions.get(as(person), action.id)
    end
  end

  describe "login receipts" do
    test "one per home and challenge; the exact receipt again answers it", %{person: person} do
      attrs = receipt(person)
      assert {:ok, recorded} = CarryActions.record_receipt(server(), attrs)
      assert recorded.kind == "login_receipt"
      assert {:ok, ^recorded} = CarryActions.record_receipt(server(), attrs)

      assert {:error, :receipt_conflict} =
               CarryActions.record_receipt(server(), %{
                 attrs
                 | browser_binding_digest: digest("other")
               })

      assert {:error, :receipt_conflict} =
               CarryActions.record_receipt(server(), %{attrs | assertion_digest: digest("other")})

      assert {:error, :cross_tenant} = CarryActions.record_receipt(as(person), attrs)
    end

    test "a receipt past its retention admits nothing", %{person: person} do
      attrs = receipt(person)
      {:ok, recorded} = CarryActions.record_receipt(server(), attrs)

      {1, _} =
        Arca.Repo.update_all(from(a in CarryAction, where: a.id == ^recorded.id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert {:error, :expired} = CarryActions.record_receipt(server(), attrs)

      assert {:error, :expired} =
               CarryActions.receipt(server(), attrs.destination_home, attrs.challenge_id)
    end

    test "a login retried after a lost response reads its receipt back, the platform's alone", %{
      person: person
    } do
      attrs = receipt(person)

      assert {:error, :not_found} =
               CarryActions.receipt(server(), attrs.destination_home, attrs.challenge_id)

      {:ok, recorded} = CarryActions.record_receipt(server(), attrs)

      assert {:ok, ^recorded} =
               CarryActions.receipt(server(), attrs.destination_home, attrs.challenge_id)

      # Another home's receipt for that challenge is not this one's.
      assert {:error, :not_found} =
               CarryActions.receipt(server(), "https://c.example", attrs.challenge_id)

      assert {:error, :cross_tenant} =
               CarryActions.receipt(as(person), attrs.destination_home, attrs.challenge_id)
    end
  end
end

defmodule Arca.CarryActionsRaceTest do
  @moduledoc """
  An exact retry of a login receipt racing the first, on real connections
  outside the sandbox: the retry loses the receipt's unique index to the
  first, waits for it, and answers the receipt it recorded. On PostgreSQL
  the retry blocks inserting its row; on SQLite at the lock its
  transaction takes at entry.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.{CarryActions, ControlPlane, Users}
  alias Arca.Schemas.{CarryAction, CellLease, ExternalIdentity, User}
  alias Ecto.Adapters.SQL.Sandbox

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()
  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres
  defp digest(seed), do: Prima.Digest.sha256("#{seed}-#{System.unique_integer()}")

  setup do
    hold_slot!()
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(CarryAction, user_id: ^user_id))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(User, id: ^user_id))
      end)
    end)

    unboxed(fn ->
      {:ok, _} =
        Users.mint(
          server(),
          %{
            id: user_id,
            provider: "github",
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          %{
            key: "github|https://github.com|car-race#{n}",
            provider: "github",
            issuer: "https://github.com",
            subject: "car-race#{n}",
            first_seen_at: now,
            last_seen_at: now
          }
        )
    end)

    {:ok, user_id: user_id}
  end

  # This member's slot, taken on a real connection so every connection
  # reads the lease; the lease row, the process-wide standing and the
  # claim switch are given back after the case.
  defp hold_slot! do
    saved = Map.new(@slot_keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)
    node = "node-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn -> Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node)) end)

      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, true)
    {:ok, slot} = unboxed(fn -> ControlPlane.take(node, node <> "#boot", 60_000) end)
    slot
  end

  # The connection's backend, on PostgreSQL, for the test to watch it wait.
  defp backend do
    if postgres?(), do: hd(hd(Arca.Repo.query!("SELECT pg_backend_pid()").rows))
  end

  # On PostgreSQL, `backend` is blocked on a lock, in a statement naming
  # every one of `fragments`.
  defp await_wait!(backend, fragments, tries \\ 250) do
    [[type, event, query]] =
      unboxed(fn ->
        Arca.Repo.query!(
          "SELECT wait_event_type, wait_event, query FROM pg_stat_activity WHERE pid = $1",
          [backend]
        ).rows
      end)

    cond do
      type == "Lock" and Enum.all?(fragments, &String.contains?(query, &1)) ->
        :ok

      tries == 0 ->
        flunk(
          "backend #{backend} is not waiting at #{inspect(fragments)}: #{type} #{event} #{query}"
        )

      true ->
        retry_wait!(backend, fragments, tries)
    end
  end

  defp retry_wait!(backend, fragments, tries) do
    Process.sleep(20)
    await_wait!(backend, fragments, tries - 1)
  end

  test "an exact retry racing the first answers the receipt it recorded", %{user_id: user_id} do
    test = self()

    attrs = %{
      action_id: "car_race_#{System.unique_integer([:positive])}",
      destination_home: "https://b.example",
      source_home: "https://a.example",
      challenge_id: "chl_race_#{System.unique_integer([:positive])}",
      user_id: user_id,
      key_epoch: digest("epoch"),
      browser_binding_digest: digest("browser"),
      assertion_digest: digest("assertion"),
      outcome: "admitted"
    }

    # The first records its receipt in the caller's transaction, beside the
    # session it mints, and holds there.
    first =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            {:ok, receipt} = CarryActions.record_receipt(server(), attrs)
            send(test, :first_holds)

            receive do
              :go -> receipt
            end
          end)
        end)
      end)

    assert_receive :first_holds, 5_000

    retry =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:retry, backend()})
          CarryActions.record_receipt(server(), attrs)
        end)
      end)

    assert_receive {:retry, pid}, 5_000
    if postgres?(), do: await_wait!(pid, [~s(INSERT INTO "carry_actions")])
    refute Task.yield(retry, 300), "the retry decided while the first held its receipt"

    send(first.pid, :go)
    assert {:ok, %{id: id}} = Task.await(first, 25_000)
    assert {:ok, %{id: ^id}} = Task.await(retry, 25_000)
  end
end
