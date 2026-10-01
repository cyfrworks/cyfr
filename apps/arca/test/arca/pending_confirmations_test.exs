# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PendingConfirmationsTest do
  @moduledoc """
  Pending confirmations, athanor-scoped: one open record per person,
  operation, argument digest and opener; confirmed once, by a passkey or
  client that still stands; consumed once, only confirmed, unexpired,
  unvoided, for exactly the change it recorded and by the credential that
  opened it; cancelled once; voided when the
  client or passkey that confirmed it is revoked; and the stored row
  rebuilds the `Prima.Confirmation` whose digest the proof covered.
  """

  # Takes the cell's slot, which is process-wide; each case restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{PairedClients, PendingConfirmations}
  alias Arca.Schemas.{CellLease, PendingConfirmation}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    slot = hold_slot!()
    athanor = "ath_cnf_#{System.unique_integer([:positive])}"
    actor = %{Prima.Actor.in_athanor(athanor) | user_id: "usr_cnf"}
    {:ok, actor: actor, slot: slot}
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

  defp digest(seed), do: Prima.Digest.sha256("#{seed}-#{System.unique_integer()}")

  # The credential that opens the records here, and another of the same
  # person's.
  @opener "session:opener-a"
  @other_opener "session:opener-b"

  defp record(actor, overrides \\ []) do
    {:ok, record} =
      Prima.Confirmation.new(
        Keyword.merge(
          [
            id: "cnf_#{System.unique_integer([:positive])}",
            home: "https://home.example",
            rp_id: "home.example",
            athanor: actor.athanor_id,
            person: "usr_cnf",
            operation: "vault.create",
            args_digest: digest("args"),
            action: "credential_entry",
            preview: %{home: "https://home.example", athanor: "Home", operation: "vault.create"},
            challenge: :crypto.strong_rand_bytes(32),
            expires_at: System.system_time(:millisecond) + 300_000
          ],
          overrides
        )
      )

    record
  end

  defp expected(record) do
    %{
      user_id: record.person,
      operation: record.operation,
      args_digest: record.args_digest,
      preview: record.preview,
      opener: @opener
    }
  end

  defp client!(actor) do
    {:ok, client} =
      PairedClients.record(actor, %{
        user_id: "usr_cnf",
        source_kind: "session",
        source_id: "ses_#{System.unique_integer([:positive])}"
      })

    client
  end

  defp confirmed!(actor, record) do
    {:ok, _} = PendingConfirmations.open(actor, %{record: record, opener: @opener})
    {:ok, confirmed} = PendingConfirmations.confirm(actor, record.id, %{proof: "oidc_reauth"})
    confirmed
  end

  describe "open/2" do
    test "stores the record, and a second open of the same request answers the first", %{
      actor: actor
    } do
      first = record(actor)
      assert {:ok, row} = PendingConfirmations.open(actor, %{record: first, opener: @opener})
      assert row.state == "pending"
      assert row.digest == Prima.Confirmation.digest(first)
      assert {:ok, ^first} = PendingConfirmations.confirmation(row)

      again = record(actor, args_digest: first.args_digest)
      assert {:ok, ^row} = PendingConfirmations.open(actor, %{record: again, opener: @opener})
    end

    test "an open record whose preview differs is voided and a new one opened", %{actor: actor} do
      first = record(actor)
      {:ok, _} = PendingConfirmations.open(actor, %{record: first, opener: @opener})

      moved =
        record(actor,
          args_digest: first.args_digest,
          preview: %{home: "https://home.example", athanor: "Renamed", operation: "vault.create"}
        )

      assert {:ok, %{id: id, state: "pending"}} =
               PendingConfirmations.open(actor, %{record: moved, opener: @opener})

      assert id == moved.id
      assert {:ok, %{state: "voided"}} = PendingConfirmations.get(actor, first.id)
      assert {:ok, [%{id: ^id}]} = PendingConfirmations.list_open(actor, "usr_cnf")

      # The voided record confirms and consumes nothing.
      assert {:error, :not_pending} =
               PendingConfirmations.confirm(actor, first.id, %{proof: "oidc_reauth"})
    end

    test "an open record past its expiry is expired and a new one written", %{actor: actor} do
      first = record(actor)
      {:ok, _} = PendingConfirmations.open(actor, %{record: first, opener: @opener})

      {1, _} =
        Arca.Repo.update_all(from(c in PendingConfirmation, where: c.id == ^first.id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      second = record(actor, args_digest: first.args_digest)

      assert {:ok, %{id: id}} =
               PendingConfirmations.open(actor, %{record: second, opener: @opener})

      assert id == second.id
      assert {:ok, %{state: "expired"}} = PendingConfirmations.get(actor, first.id)
    end

    test "another credential's open of the same request writes its own record beside the first",
         %{actor: actor} do
      first = record(actor)

      assert {:ok, %{id: first_id}} =
               PendingConfirmations.open(actor, %{record: first, opener: @opener})

      beside = record(actor, args_digest: first.args_digest)

      assert {:ok, %{id: beside_id, opener: @other_opener}} =
               PendingConfirmations.open(actor, %{record: beside, opener: @other_opener})

      assert beside_id == beside.id
      refute beside_id == first_id

      assert {:ok, [%{id: ^first_id}, %{id: ^beside_id}]} =
               PendingConfirmations.list_open(actor, "usr_cnf")

      # Each opener's second open answers its own record.
      assert {:ok, %{id: ^first_id}} =
               PendingConfirmations.open(actor, %{
                 record: record(actor, args_digest: first.args_digest),
                 opener: @opener
               })
    end

    test "an open that names no credential, or a malformed one, is refused", %{actor: actor} do
      for attrs <- [
            %{record: record(actor)},
            %{record: record(actor), opener: ""},
            %{record: record(actor), opener: nil},
            %{record: record(actor), opener: String.duplicate("x", 256)}
          ] do
        assert {:error, {:invalid, %{opener: _}}} = PendingConfirmations.open(actor, attrs)
      end

      assert {:ok, []} = PendingConfirmations.list_open(actor, "usr_cnf")
    end

    test "a record of another athanor, or a local person's naming an epoch, is refused", %{
      actor: actor
    } do
      elsewhere = record(actor, athanor: "ath_elsewhere")

      assert {:error, :cross_tenant} =
               PendingConfirmations.open(actor, %{record: elsewhere, opener: @opener})

      assert {:error, :unexpected_key_epoch} =
               PendingConfirmations.open(actor, %{
                 record: record(actor),
                 opener: @opener,
                 identity_key_epoch: digest("epoch")
               })
    end
  end

  describe "confirm/3" do
    test "confirms once", %{actor: actor} do
      rec = record(actor)
      {:ok, _} = PendingConfirmations.open(actor, %{record: rec, opener: @opener})

      assert {:ok, %{state: "confirmed", proof: "oidc_reauth"}} =
               PendingConfirmations.confirm(actor, rec.id, %{proof: "oidc_reauth"})

      assert {:error, :not_pending} =
               PendingConfirmations.confirm(actor, rec.id, %{proof: "oidc_reauth"})
    end

    test "refuses a proof the vocabulary lacks, and a passkey proof names its passkey", %{
      actor: actor
    } do
      rec = record(actor)
      {:ok, _} = PendingConfirmations.open(actor, %{record: rec, opener: @opener})

      assert {:error, {:invalid, %{proof: _}}} =
               PendingConfirmations.confirm(actor, rec.id, %{proof: "session"})

      assert {:error, {:invalid, %{passkey_id: _}}} =
               PendingConfirmations.confirm(actor, rec.id, %{proof: "passkey"})

      assert {:error, :revoked} =
               PendingConfirmations.confirm(actor, rec.id, %{
                 proof: "passkey",
                 passkey_id: "psk_x"
               })
    end

    test "refuses after expiry, and a revoked client confirms nothing", %{actor: actor} do
      client = client!(actor)
      {:ok, _} = PairedClients.revoke(actor, client.id)
      rec = record(actor)
      {:ok, _} = PendingConfirmations.open(actor, %{record: rec, opener: @opener})

      assert {:error, :revoked} =
               PendingConfirmations.confirm(actor, rec.id, %{
                 proof: "oidc_reauth",
                 client_id: client.id
               })

      {1, _} =
        Arca.Repo.update_all(from(c in PendingConfirmation, where: c.id == ^rec.id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert {:error, :expired} =
               PendingConfirmations.confirm(actor, rec.id, %{proof: "oidc_reauth"})
    end
  end

  describe "consume/3" do
    test "consumes once, for exactly the recorded change", %{actor: actor} do
      rec = record(actor)
      confirmed!(actor, rec)

      assert {:error, :mismatch} =
               PendingConfirmations.consume(actor, rec.id, %{
                 expected(rec)
                 | args_digest: digest("other")
               })

      assert {:error, :mismatch} =
               PendingConfirmations.consume(actor, rec.id, %{expected(rec) | user_id: "usr_other"})

      assert {:error, :mismatch} =
               PendingConfirmations.consume(actor, rec.id, %{
                 expected(rec)
                 | preview: %{
                     home: "https://home.example",
                     athanor: "Other",
                     operation: "vault.create"
                   }
               })

      # Another credential of the same person, or none, consumes nothing.
      for opener <- [@other_opener, nil] do
        assert {:error, :mismatch} =
                 PendingConfirmations.consume(actor, rec.id, %{expected(rec) | opener: opener})

        assert {:error, :mismatch} =
                 PendingConfirmations.check(actor, rec.id, %{expected(rec) | opener: opener})
      end

      assert {:error, :mismatch} =
               PendingConfirmations.consume(actor, rec.id, Map.delete(expected(rec), :opener))

      assert {:ok, %{state: "consumed"}} =
               PendingConfirmations.consume(actor, rec.id, expected(rec))

      assert {:error, :consumed} = PendingConfirmations.consume(actor, rec.id, expected(rec))
    end

    test "refuses a pending, an expired, a cancelled and another athanor's record", %{
      actor: actor
    } do
      pending = record(actor)
      {:ok, _} = PendingConfirmations.open(actor, %{record: pending, opener: @opener})

      assert {:error, :not_confirmed} =
               PendingConfirmations.consume(actor, pending.id, expected(pending))

      expired = record(actor)
      confirmed!(actor, expired)

      {1, _} =
        Arca.Repo.update_all(from(c in PendingConfirmation, where: c.id == ^expired.id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert {:error, :expired} =
               PendingConfirmations.consume(actor, expired.id, expected(expired))

      cancelled = record(actor)
      confirmed!(actor, cancelled)
      assert {:ok, %{state: "cancelled"}} = PendingConfirmations.cancel(actor, cancelled.id)
      assert {:error, :not_open} = PendingConfirmations.cancel(actor, cancelled.id)

      assert {:error, :cancelled} =
               PendingConfirmations.consume(actor, cancelled.id, expected(cancelled))

      other = %{actor | athanor_id: "ath_cnf_other"}

      assert {:error, :not_found} =
               PendingConfirmations.consume(other, pending.id, expected(pending))
    end

    test "a refusal nested in a caller's transaction rolls the whole transaction back", %{
      actor: actor
    } do
      pending = record(actor)
      {:ok, _} = PendingConfirmations.open(actor, %{record: pending, opener: @opener})
      written_first = record(actor)

      # The caller wrote before it consumed, and goes on as if the refusal
      # were only an answer: the refusal took the caller's write with it.
      assert {:error, :rollback} =
               Arca.Repo.transaction(fn ->
                 {:ok, _} =
                   PendingConfirmations.open(actor, %{record: written_first, opener: @opener})

                 {:error, :not_confirmed} =
                   PendingConfirmations.consume(actor, pending.id, expected(pending))

                 :committed
               end)

      assert {:error, :not_found} = PendingConfirmations.get(actor, written_first.id)
    end

    test "check/3 answers what consume would, writing nothing, so the caller opens after it", %{
      actor: actor
    } do
      pending = record(actor)
      {:ok, _} = PendingConfirmations.open(actor, %{record: pending, opener: @opener})
      in_its_place = record(actor)

      assert {:ok, {:error, :not_confirmed}} =
               Arca.Repo.transaction(fn ->
                 refusal = PendingConfirmations.check(actor, pending.id, expected(pending))

                 {:ok, _} =
                   PendingConfirmations.open(actor, %{record: in_its_place, opener: @opener})

                 refusal
               end)

      assert {:ok, %{state: "pending"}} = PendingConfirmations.get(actor, in_its_place.id)

      confirmed = record(actor)
      confirmed!(actor, confirmed)
      assert :ok = PendingConfirmations.check(actor, confirmed.id, expected(confirmed))

      assert {:error, :mismatch} =
               PendingConfirmations.check(actor, confirmed.id, %{
                 expected(confirmed)
                 | args_digest: digest("other")
               })

      assert {:ok, %{state: "confirmed"}} = PendingConfirmations.get(actor, confirmed.id)

      assert {:error, :not_found} =
               PendingConfirmations.check(actor, "cnf_missing", expected(confirmed))

      assert {:error, :no_athanor} =
               PendingConfirmations.check(Prima.Actor.system(), confirmed.id, %{})
    end

    test "runs inside a caller's transaction, rolling back with it", %{actor: actor} do
      rec = record(actor)
      confirmed!(actor, rec)

      assert {:error, :effect_failed} =
               Arca.Repo.transaction(fn ->
                 {:ok, _} = PendingConfirmations.consume(actor, rec.id, expected(rec))
                 Arca.Repo.rollback(:effect_failed)
               end)

      assert {:ok, %{state: "confirmed"}} = PendingConfirmations.get(actor, rec.id)

      assert {:ok, %{state: "consumed"}} =
               PendingConfirmations.consume(actor, rec.id, expected(rec))
    end
  end

  describe "voiding" do
    test "a record whose confirming client is revoked is voided and refused", %{actor: actor} do
      client = client!(actor)
      rec = record(actor)
      {:ok, _} = PendingConfirmations.open(actor, %{record: rec, opener: @opener})

      {:ok, _} =
        PendingConfirmations.confirm(actor, rec.id, %{proof: "oidc_reauth", client_id: client.id})

      {:ok, _} = PairedClients.revoke(actor, client.id)

      assert {:ok, %{state: "voided"}} = PendingConfirmations.get(actor, rec.id)
      assert {:error, :voided} = PendingConfirmations.consume(actor, rec.id, expected(rec))
    end

    test "void_for/2 voids what a client confirmed, in the actor's athanor only", %{actor: actor} do
      client = client!(actor)
      rec = record(actor)
      {:ok, _} = PendingConfirmations.open(actor, %{record: rec, opener: @opener})

      {:ok, _} =
        PendingConfirmations.confirm(actor, rec.id, %{proof: "email_code", client_id: client.id})

      other = Prima.Actor.in_athanor("ath_cnf_other")
      assert {:ok, []} = PendingConfirmations.void_for(other, {:paired_client, client.id})
      assert {:ok, [id]} = PendingConfirmations.void_for(actor, {:paired_client, client.id})
      assert id == rec.id

      assert {:error, :cross_tenant} =
               PendingConfirmations.void_for(actor, {:passkey, "psk_x"})
    end
  end

  describe "the member fence" do
    test "a stale member confirms nothing and holds no challenge", %{actor: actor, slot: slot} do
      rec = record(actor)
      {:ok, _} = PendingConfirmations.open(actor, %{record: rec, opener: @opener})

      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} =
               PendingConfirmations.put_challenge(actor, rec.id, %{reauth_nonce: "nonce"})

      assert {:error, :not_owner} =
               PendingConfirmations.confirm(actor, rec.id, %{proof: "oidc_reauth"})

      assert {:ok, %{state: "pending", reauth_nonce: nil}} =
               PendingConfirmations.get(actor, rec.id)
    end
  end

  describe "the email code" do
    test "is held hashed and cancels the record at its failure limit", %{actor: actor} do
      rec = record(actor)
      {:ok, _} = PendingConfirmations.open(actor, %{record: rec, opener: @opener})

      assert {:ok, %{email_code_hash: "sha256:code", email_code_failures: 0}} =
               PendingConfirmations.put_challenge(actor, rec.id, %{email_code_hash: "sha256:code"})

      for n <- 1..4 do
        assert {:ok, %{state: "pending", email_code_failures: ^n}} =
                 PendingConfirmations.count_code_failure(actor, rec.id, 5)
      end

      assert {:ok, %{state: "cancelled"}} =
               PendingConfirmations.count_code_failure(actor, rec.id, 5)
    end
  end

  test "lists the person's open records in the actor's athanor", %{actor: actor} do
    rec = record(actor)
    {:ok, _} = PendingConfirmations.open(actor, %{record: rec, opener: @opener})
    assert {:ok, [%{id: id}]} = PendingConfirmations.list_open(actor, "usr_cnf")
    assert id == rec.id
    assert {:ok, []} = PendingConfirmations.list_open(actor, "usr_other")
    assert {:error, :no_athanor} = PendingConfirmations.list_open(Prima.Actor.system(), "usr_cnf")
  end
end

defmodule Arca.PendingConfirmationsRaceTest do
  @moduledoc """
  A confirm racing a denial of its confirmer's person, on two real
  connections outside the sandbox. The confirm takes the paired client's
  lock before the record's, the order the denial takes them in, so the
  two never wait on each other: the denial revokes the client and voids
  the record, and the confirm, waiting on the client, reads the revocation
  and is refused. On PostgreSQL the denial is held just after it revoked
  the client (a trigger on its next statement waits on an advisory lock
  the test holds); on SQLite at its policy, holding the write lock.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.{ControlPlane, PairedClients, PendingConfirmations, SecurityTransitions}

  alias Arca.Schemas.{
    Athanor,
    CellLease,
    DeviceCertificate,
    ExternalIdentity,
    Membership,
    PairedClient,
    PendingConfirmation,
    User
  }

  alias Ecto.Adapters.SQL.Sandbox

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  @gate 7_310_001

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()
  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres

  setup do
    hold_slot!()
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    athanor_id = Prima.UUID7.generate_id("ath")
    actor = %{Prima.Actor.in_athanor(athanor_id) | user_id: user_id}

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(PendingConfirmation, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(DeviceCertificate, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(PairedClient, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(Membership, user_id: ^user_id))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(User, id: ^user_id))
        Arca.Repo.delete_all(where(Athanor, id: ^athanor_id))
      end)
    end)

    {client, record} =
      unboxed(fn ->
        {:ok, _} =
          Arca.Users.mint(
            server(),
            %{
              id: user_id,
              provider: "github",
              email: "cnf#{n}@example.com",
              email_verified: true,
              first_seen_at: now,
              last_seen_at: now,
              created_at: now,
              updated_at: now
            },
            %{
              key: "github|https://github.com|cnf#{n}",
              provider: "github",
              issuer: "https://github.com",
              subject: "cnf#{n}",
              first_seen_at: now,
              last_seen_at: now
            }
          )

        {:ok, _} =
          Arca.Athanors.insert(server(), %{
            id: athanor_id,
            kind: "group",
            name: "Cnf #{n}",
            slug: "cnf-race-#{n}",
            created_by: user_id
          })

        {:ok, client} =
          PairedClients.record(actor, %{
            user_id: user_id,
            source_kind: "session",
            source_id: "ses_cnf_race_#{n}"
          })

        {:ok, record} =
          Prima.Confirmation.new(
            id: "cnf_race_#{n}",
            home: "https://home.example",
            rp_id: "home.example",
            athanor: athanor_id,
            person: user_id,
            operation: "vault.create",
            args_digest: Prima.Digest.sha256("args-#{n}"),
            action: "credential_entry",
            preview: %{home: "https://home.example", athanor: "Home", operation: "vault.create"},
            challenge: :crypto.strong_rand_bytes(32),
            expires_at: System.system_time(:millisecond) + 300_000
          )

        {:ok, _} =
          PendingConfirmations.open(actor, %{record: record, opener: "session:race-test"})

        {client, record}
      end)

    {:ok, actor: actor, user_id: user_id, client: client, record: record}
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

  # On PostgreSQL, `backend` is blocked on a lock, at the gate (`:gate`) or
  # in a statement naming every one of `fragments`.
  defp await_wait!(backend, at, tries \\ 250) do
    [[type, event, query]] =
      unboxed(fn ->
        Arca.Repo.query!(
          "SELECT wait_event_type, wait_event, query FROM pg_stat_activity WHERE pid = $1",
          [backend]
        ).rows
      end)

    waiting? =
      type == "Lock" and
        case at do
          :gate -> event == "advisory"
          fragments -> event != "advisory" and Enum.all?(fragments, &String.contains?(query, &1))
        end

    cond do
      waiting? ->
        :ok

      tries == 0 ->
        flunk("backend #{backend} is not waiting at #{inspect(at)}: #{type} #{event} #{query}")

      true ->
        retry_wait!(backend, at, tries)
    end
  end

  defp retry_wait!(backend, at, tries) do
    Process.sleep(20)
    await_wait!(backend, at, tries - 1)
  end

  # A trigger that holds a connection which set `arca_test.gate` before
  # `table`'s next UPDATE statement, until the test opens the gate.
  defp install_gate!(table) do
    unboxed(fn ->
      Arca.Repo.query!("""
      CREATE OR REPLACE FUNCTION arca_test_gate() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF current_setting('arca_test.gate', true) = 'on' THEN
          PERFORM pg_advisory_lock(#{@gate});
          PERFORM pg_advisory_unlock(#{@gate});
        END IF;
        IF TG_LEVEL = 'ROW' THEN RETURN NEW; END IF;
        RETURN NULL;
      END $$
      """)

      Arca.Repo.query!(
        "CREATE TRIGGER arca_test_gate BEFORE UPDATE ON #{table} " <>
          "FOR EACH STATEMENT EXECUTE FUNCTION arca_test_gate()"
      )
    end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.query!("DROP TRIGGER IF EXISTS arca_test_gate ON #{table}")
        Arca.Repo.query!("DROP FUNCTION IF EXISTS arca_test_gate()")
      end)
    end)
  end

  defp close_gate! do
    test = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.query!("SELECT pg_advisory_lock($1)", [@gate])
          send(test, :gate_closed)

          receive do
            :open -> Arca.Repo.query!("SELECT pg_advisory_unlock($1)", [@gate])
          end
        end)
      end)

    assert_receive :gate_closed, 5_000
    holder
  end

  defp open_gate!(holder) do
    send(holder.pid, :open)
    Task.await(holder)
  end

  defp gated(fun) do
    Arca.Repo.query!("SELECT set_config('arca_test.gate', 'on', false)")

    try do
      fun.()
    after
      Arca.Repo.query!("SELECT set_config('arca_test.gate', '', false)")
    end
  end

  test "a denial holding the client refuses the confirm waiting on it", %{
    actor: actor,
    user_id: user_id,
    client: client,
    record: record
  } do
    test = self()

    denier =
      if postgres?() do
        install_gate!("device_certificates")
        gate = close_gate!()

        denier =
          Task.async(fn ->
            unboxed(fn ->
              send(test, {:denier, backend()})

              gated(fn ->
                SecurityTransitions.deny_user(server(), user_id, verify: fn _ -> :ok end)
              end)
            end)
          end)

        assert_receive {:denier, pid}, 5_000
        await_wait!(pid, :gate)
        {denier, fn -> open_gate!(gate) end}
      else
        denier =
          Task.async(fn ->
            unboxed(fn ->
              SecurityTransitions.deny_user(server(), user_id,
                verify: fn _rows ->
                  send(test, :denial_holds)

                  receive do
                    :go -> :ok
                  end
                end
              )
            end)
          end)

        assert_receive :denial_holds, 5_000
        {denier, fn -> send(denier.pid, :go) end}
      end

    {denier, release} = denier

    confirmer =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:confirmer, backend()})

          PendingConfirmations.confirm(actor, record.id, %{
            proof: "oidc_reauth",
            client_id: client.id
          })
        end)
      end)

    assert_receive {:confirmer, pid}, 5_000
    if postgres?(), do: await_wait!(pid, [~s("paired_clients"), "FOR UPDATE"])
    refute Task.yield(confirmer, 300), "the confirm decided while the denial held its client"

    release.()
    assert {:ok, %{transitioned: true} = change} = Task.await(denier, 25_000)
    assert client.id in change.revoked_paired_client_ids
    assert {:error, :revoked} = Task.await(confirmer, 25_000)

    assert %{state: "voided", confirmed_client_id: nil} =
             unboxed(fn -> Arca.Repo.get!(PendingConfirmation, record.id) end)
  end

  if Arca.Repo.adapter() != Ecto.Adapters.Postgres do
    @tag skip:
           "the denial has no pause point here but a PostgreSQL trigger; SQLite's write lock orders it"
  end

  test "a denial and a confirm through a passkey take the passkey before the record", %{
    actor: actor,
    user_id: user_id,
    client: client,
    record: record
  } do
    test = self()

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(Arca.Schemas.Passkey, user_id: ^user_id))
        Arca.Repo.delete_all(where(Arca.Schemas.PersonIdentity, user_id: ^user_id))
      end)
    end)

    passkey =
      unboxed(fn ->
        {:ok, _} =
          Arca.PersonIdentities.create(server(), %{
            user_id: user_id,
            provenance: "local",
            live_public_key: :crypto.strong_rand_bytes(32),
            operational_public_key: :crypto.strong_rand_bytes(32),
            live_key_sealed: "l",
            operational_key_sealed: "o"
          })

        {:ok, passkey} =
          Arca.Passkeys.register(%Prima.Actor{user_id: user_id}, %{
            user_id: user_id,
            credential_id: "cred-race-#{System.unique_integer([:positive])}",
            rp_id: "home.example",
            relying_home: "https://home.example",
            public_key: "cose-key",
            registration_digest: Prima.Digest.sha256("registration"),
            possession_verified: true,
            state: "active"
          })

        # The record is already confirmed through the paired client, so the
        # denial voids it as a dependent of that client.
        {:ok, _} =
          PendingConfirmations.confirm(actor, record.id, %{
            proof: "oidc_reauth",
            client_id: client.id
          })

        passkey
      end)

    # The denial is held after it revoked the client and before it revokes
    # the passkeys: with the confirmations voided only after the passkeys,
    # it holds no confirmation's lock yet, so the confirm, locking the
    # passkey and then the record, finishes, and the denial then takes the
    # passkey. Voiding first would hold the record here, and the two would
    # deadlock.
    install_gate!("pairing_invitations")
    gate = close_gate!()

    denier =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:denier, backend()})

          gated(fn ->
            SecurityTransitions.deny_user(server(), user_id, verify: fn _ -> :ok end)
          end)
        end)
      end)

    assert_receive {:denier, pid}, 5_000
    await_wait!(pid, :gate)

    confirmer =
      Task.async(fn ->
        unboxed(fn ->
          PendingConfirmations.confirm(actor, record.id, %{
            proof: "passkey",
            passkey_id: passkey.id
          })
        end)
      end)

    answer = Task.await(confirmer, 25_000)
    refute answer == {:error, :database_error}, "the confirm deadlocked: #{inspect(answer)}"

    open_gate!(gate)
    assert {:ok, %{transitioned: true} = change} = Task.await(denier, 25_000)
    assert passkey.id in change.revoked_passkey_ids

    assert %{state: "voided"} =
             unboxed(fn -> Arca.Repo.get!(PendingConfirmation, record.id) end)
  end
end
