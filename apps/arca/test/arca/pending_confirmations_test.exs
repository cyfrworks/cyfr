# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PendingConfirmationsTest do
  @moduledoc """
  Pending confirmations, athanor-scoped and keyed by their public ref: a
  new record for every open, never one that stands; confirmed once, by a
  passkey or client that still stands, named by its ref; consumed once,
  only confirmed, unexpired, unvoided, for exactly the change it recorded,
  by the credential that opened it and under the secret whose ref it is;
  cancelled once; voided when the client or passkey that confirmed it is
  revoked; the secret stored nowhere; and the stored row rebuilds the
  `Prima.Confirmation` whose digest the proof covered.
  """

  # Takes the cell's slot, which is process-wide; each case restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{PairedClients, PendingConfirmations}
  alias Arca.Schemas.{CellLease, PendingConfirmation}
  alias Prima.Confirmation

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
  # person's; and the name each record keeps for the client that asked.
  @opener "session:opener-a"
  @other_opener "session:opener-b"
  @asker %{"kind" => "session", "name" => "github"}

  # A secret as the deciding site draws one: 256 bits, cnf_ and 43
  # base64url characters.
  defp secret, do: "cnf_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # A record named by the ref of `:secret` (a new one by default).
  defp record(actor, overrides \\ []) do
    {secret, overrides} = Keyword.pop_lazy(overrides, :secret, &secret/0)

    {:ok, record} =
      Confirmation.new(
        Keyword.merge(
          [
            id: Confirmation.ref(secret),
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

  defp open(actor, record, opener \\ @opener),
    do: PendingConfirmations.open(actor, %{record: record, opener: opener, asker: @asker})

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
    {:ok, _} = open(actor, record)
    {:ok, confirmed} = PendingConfirmations.confirm(actor, record.id, %{proof: "oidc_reauth"})
    confirmed
  end

  defp expire!(ref) do
    {1, _} =
      Arca.Repo.update_all(from(c in PendingConfirmation, where: c.ref == ^ref),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )
  end

  describe "two identical requests under one opener, a thief's first" do
    test "opens first, and the person's identical request gets its own record, which only the person repeats",
         %{actor: actor} do
      args = digest("pairing")

      # The thief, holding the person's session token, asks first; the
      # person then asks for the identical change under the same token.
      thief_secret = secret()
      thief = record(actor, secret: thief_secret, args_digest: args)
      person_secret = secret()
      person = record(actor, secret: person_secret, args_digest: args)

      assert {:ok, %{ref: thief_ref}} = open(actor, thief)
      assert {:ok, %{ref: person_ref}} = open(actor, person)
      refute thief_ref == person_ref

      # The person proves their own record, named by its ref.
      assert {:ok, %{state: "confirmed"}} =
               PendingConfirmations.confirm(actor, person_ref, %{proof: "oidc_reauth"})

      # The thief, under the very same opener, holds only its own secret
      # and the person's ref (from the stream or the list): neither repeats
      # the person's change.
      assert {:error, :not_confirmed} =
               PendingConfirmations.consume(actor, thief_secret, expected(person))

      assert {:error, :not_found} =
               PendingConfirmations.consume(actor, person_ref, expected(person))

      assert {:error, :not_found} =
               PendingConfirmations.check(actor, person_ref, expected(person))

      # The person repeats under their own secret; the thief's record stays
      # unproven.
      assert {:ok, %{ref: ^person_ref, state: "consumed"}} =
               PendingConfirmations.consume(actor, person_secret, expected(person))

      assert {:ok, %{state: "pending"}} = PendingConfirmations.get(actor, thief_ref)
    end
  end

  describe "open/2" do
    test "stores the record under its ref, holding no secret, and rebuilds it", %{actor: actor} do
      secret = secret()
      first = record(actor, secret: secret)

      assert {:ok, row} = open(actor, first)
      assert row.ref == Confirmation.ref(secret)
      assert row.ref == first.id
      assert row.state == "pending"
      assert row.digest == Confirmation.digest(first)
      assert Jason.decode!(row.asker) == @asker
      assert {:ok, ^first} = PendingConfirmations.confirmation(row)

      stored = Arca.Repo.get!(PendingConfirmation, first.id)
      refute inspect(stored, limit: :infinity, printable_limit: :infinity) =~ secret
      refute Map.has_key?(row, :id)
    end

    test "two identical requests open two records, and the unproven one expires", %{
      actor: actor
    } do
      args = digest("args")
      proven_secret = secret()
      proven = record(actor, secret: proven_secret, args_digest: args)
      unproven = record(actor, args_digest: args)

      assert {:ok, %{ref: proven_ref}} = open(actor, proven)
      assert {:ok, %{ref: unproven_ref}} = open(actor, unproven)
      refute proven_ref == unproven_ref

      assert {:ok, [%{ref: ^proven_ref}, %{ref: ^unproven_ref}]} =
               PendingConfirmations.list_open(actor, "usr_cnf")

      {:ok, _} = PendingConfirmations.confirm(actor, proven_ref, %{proof: "oidc_reauth"})

      assert {:ok, %{state: "consumed"}} =
               PendingConfirmations.consume(actor, proven_secret, expected(proven))

      # The unproven one runs out: no longer listed, proven or consumed.
      expire!(unproven_ref)
      assert {:ok, []} = PendingConfirmations.list_open(actor, "usr_cnf")

      assert {:error, :expired} =
               PendingConfirmations.confirm(actor, unproven_ref, %{proof: "oidc_reauth"})
    end

    test "an opener holds at most eight open records: the oldest is voided as a ninth opens",
         %{actor: actor} do
      assert PendingConfirmations.open_per_opener() == 8

      held =
        for _ <- 1..8 do
          secret = secret()
          rec = record(actor, secret: secret)
          assert {:ok, %{ref: ref, voided: []}} = open(actor, rec)
          {secret, rec, ref}
        end

      [{oldest_secret, oldest, oldest_ref} | kept] = held

      # A proven record counts as open, and is voided like any other.
      {:ok, _} = PendingConfirmations.confirm(actor, oldest_ref, %{proof: "oidc_reauth"})

      # Another opener's records, and the person's in another athanor, are
      # not this opener's to make room among.
      {:ok, %{ref: beside}} = open(actor, record(actor), @other_opener)
      elsewhere = %{actor | athanor_id: "ath_cnf_elsewhere"}
      {:ok, %{ref: there}} = open(elsewhere, record(elsewhere))

      assert {:ok, %{ref: ninth, voided: [^oldest_ref]}} = open(actor, record(actor))

      assert {:ok, %{state: "voided"}} = PendingConfirmations.get(actor, oldest_ref)

      assert {:error, :voided} =
               PendingConfirmations.consume(actor, oldest_secret, expected(oldest))

      {:ok, open} = PendingConfirmations.list_open(actor, "usr_cnf")
      mine = for %{opener: @opener, ref: ref} <- open, do: ref
      assert Enum.sort(mine) == Enum.sort([ninth | Enum.map(kept, &elem(&1, 2))])
      assert beside in Enum.map(open, & &1.ref)
      assert {:ok, %{state: "pending"}} = PendingConfirmations.get(elsewhere, there)

      # The next open voids the next oldest. The count is read in the
      # open's own transaction, so two opens racing on PostgreSQL could each
      # find room and leave nine: the bound is soft under concurrent opens,
      # and the next open restores it. Opens one after another hold it.
      [{_secret, _rec, second_ref} | _] = kept
      assert {:ok, %{voided: [^second_ref]}} = open(actor, record(actor))
    end

    test "another credential's open of the same request writes its own record beside the first",
         %{actor: actor} do
      first = record(actor)
      assert {:ok, %{ref: first_ref}} = open(actor, first)

      beside = record(actor, args_digest: first.args_digest)

      assert {:ok, %{ref: beside_ref, opener: @other_opener}} =
               open(actor, beside, @other_opener)

      refute beside_ref == first_ref

      assert {:ok, [%{ref: ^first_ref}, %{ref: ^beside_ref}]} =
               PendingConfirmations.list_open(actor, "usr_cnf")
    end

    test "a record named by anything but a ref, the secret among them, is refused and nothing stored",
         %{actor: actor} do
      secret = secret()
      {:ok, by_secret} = Confirmation.new(%{Map.from_struct(record(actor)) | id: secret})

      for named <- [by_secret, record(actor, id: "cnf_plain"), record(actor, id: "cnr_short")] do
        assert {:error, {:invalid, %{ref: _}}} = open(actor, named)
      end

      assert {:ok, []} = PendingConfirmations.list_open(actor, "usr_cnf")
    end

    test "a ref already stored is a conflict", %{actor: actor} do
      secret = secret()
      {:ok, _} = open(actor, record(actor, secret: secret))
      assert {:error, :conflict} = open(actor, record(actor, secret: secret))
    end

    test "an open that names no credential or no asker, or a malformed one, is refused", %{
      actor: actor
    } do
      for attrs <- [
            %{record: record(actor), asker: @asker},
            %{record: record(actor), opener: "", asker: @asker},
            %{record: record(actor), opener: nil, asker: @asker},
            %{record: record(actor), opener: String.duplicate("x", 256), asker: @asker}
          ] do
        assert {:error, {:invalid, %{opener: _}}} = PendingConfirmations.open(actor, attrs)
      end

      for asker <- [nil, %{}, "session", %{"name" => String.duplicate("x", 5000)}] do
        attrs = %{record: record(actor), opener: @opener, asker: asker}
        assert {:error, {:invalid, %{asker: _}}} = PendingConfirmations.open(actor, attrs)
      end

      assert {:error, {:invalid, %{asker: _}}} =
               PendingConfirmations.open(actor, %{record: record(actor), opener: @opener})

      assert {:ok, []} = PendingConfirmations.list_open(actor, "usr_cnf")
    end

    test "a record of another athanor, or a local person's naming an epoch, is refused", %{
      actor: actor
    } do
      elsewhere = record(actor, athanor: "ath_elsewhere")

      assert {:error, :cross_tenant} = open(actor, elsewhere)

      assert {:error, :unexpected_key_epoch} =
               PendingConfirmations.open(actor, %{
                 record: record(actor),
                 opener: @opener,
                 asker: @asker,
                 identity_key_epoch: digest("epoch")
               })
    end
  end

  describe "confirm/3" do
    test "confirms once, by the ref, and never by the secret", %{actor: actor} do
      secret = secret()
      rec = record(actor, secret: secret)
      {:ok, _} = open(actor, rec)

      assert {:error, :not_found} =
               PendingConfirmations.confirm(actor, secret, %{proof: "oidc_reauth"})

      assert {:ok, %{state: "confirmed", proof: "oidc_reauth"}} =
               PendingConfirmations.confirm(actor, rec.id, %{proof: "oidc_reauth"})

      assert {:error, :not_pending} =
               PendingConfirmations.confirm(actor, rec.id, %{proof: "oidc_reauth"})
    end

    test "refuses a proof the vocabulary lacks, and a passkey proof names its passkey", %{
      actor: actor
    } do
      rec = record(actor)
      {:ok, _} = open(actor, rec)

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
      {:ok, _} = open(actor, rec)

      assert {:error, :revoked} =
               PendingConfirmations.confirm(actor, rec.id, %{
                 proof: "oidc_reauth",
                 client_id: client.id
               })

      expire!(rec.id)

      assert {:error, :expired} =
               PendingConfirmations.confirm(actor, rec.id, %{proof: "oidc_reauth"})
    end

    test "a ref of another athanor names nothing here", %{actor: actor} do
      rec = record(actor)
      {:ok, _} = open(actor, rec)
      other = %{actor | athanor_id: "ath_cnf_other"}

      assert {:error, :not_found} =
               PendingConfirmations.confirm(other, rec.id, %{proof: "oidc_reauth"})

      assert {:error, :not_found} = PendingConfirmations.cancel(other, rec.id)
      assert {:error, :not_found} = PendingConfirmations.get(other, rec.id)
      assert {:ok, %{state: "pending"}} = PendingConfirmations.get(actor, rec.id)
    end
  end

  describe "consume/3" do
    test "consumes once, under the secret, for exactly the recorded change", %{actor: actor} do
      secret = secret()
      rec = record(actor, secret: secret)
      confirmed!(actor, rec)

      assert {:error, :mismatch} =
               PendingConfirmations.consume(actor, secret, %{
                 expected(rec)
                 | args_digest: digest("other")
               })

      assert {:error, :mismatch} =
               PendingConfirmations.consume(actor, secret, %{expected(rec) | user_id: "usr_other"})

      assert {:error, :mismatch} =
               PendingConfirmations.consume(actor, secret, %{
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
                 PendingConfirmations.consume(actor, secret, %{expected(rec) | opener: opener})

        assert {:error, :mismatch} =
                 PendingConfirmations.check(actor, secret, %{expected(rec) | opener: opener})
      end

      assert {:error, :mismatch} =
               PendingConfirmations.consume(actor, secret, Map.delete(expected(rec), :opener))

      # The ref, which any client of the person may know, consumes nothing.
      assert {:error, :not_found} = PendingConfirmations.consume(actor, rec.id, expected(rec))
      assert {:error, :not_found} = PendingConfirmations.check(actor, rec.id, expected(rec))

      assert {:ok, %{state: "consumed"}} =
               PendingConfirmations.consume(actor, secret, expected(rec))

      assert {:error, :consumed} = PendingConfirmations.consume(actor, secret, expected(rec))
    end

    test "a repeat before the proof finds its own record waiting, and only its own", %{
      actor: actor
    } do
      secret = secret()
      rec = record(actor, secret: secret)
      {:ok, _} = open(actor, rec)

      # This change, this opener, still pending and unexpired: waiting,
      # however often asked, and nothing written.
      for _ <- 1..2 do
        assert {:error, :not_confirmed} = PendingConfirmations.check(actor, secret, expected(rec))

        assert {:error, :not_confirmed} =
                 PendingConfirmations.consume(actor, secret, expected(rec))
      end

      assert {:ok, [%{ref: ref, state: "pending"}]} =
               PendingConfirmations.list_open(actor, "usr_cnf")

      assert ref == rec.id

      # Another change, or the same secret under another opener, is no
      # repeat of this request: the change and opener are compared first.
      for other <- [
            %{expected(rec) | args_digest: digest("other")},
            %{expected(rec) | opener: @other_opener}
          ] do
        assert {:error, :mismatch} = PendingConfirmations.check(actor, secret, other)
        assert {:error, :mismatch} = PendingConfirmations.consume(actor, secret, other)
      end

      # Once proven, the repeat consumes it.
      {:ok, _} = PendingConfirmations.confirm(actor, rec.id, %{proof: "oidc_reauth"})

      assert {:ok, %{state: "consumed"}} =
               PendingConfirmations.consume(actor, secret, expected(rec))
    end

    test "a pending record past its expiry waits for nothing", %{actor: actor} do
      secret = secret()
      rec = record(actor, secret: secret)
      {:ok, _} = open(actor, rec)
      expire!(rec.id)

      assert {:error, :expired} = PendingConfirmations.check(actor, secret, expected(rec))
      assert {:error, :expired} = PendingConfirmations.consume(actor, secret, expected(rec))
    end

    test "refuses a pending, an expired, a cancelled and another athanor's record", %{
      actor: actor
    } do
      pending_secret = secret()
      pending = record(actor, secret: pending_secret)
      {:ok, _} = open(actor, pending)

      assert {:error, :not_confirmed} =
               PendingConfirmations.consume(actor, pending_secret, expected(pending))

      expired_secret = secret()
      expired = record(actor, secret: expired_secret)
      confirmed!(actor, expired)
      expire!(expired.id)

      assert {:error, :expired} =
               PendingConfirmations.consume(actor, expired_secret, expected(expired))

      cancelled_secret = secret()
      cancelled = record(actor, secret: cancelled_secret)
      confirmed!(actor, cancelled)
      assert {:ok, %{state: "cancelled"}} = PendingConfirmations.cancel(actor, cancelled.id)
      assert {:error, :not_open} = PendingConfirmations.cancel(actor, cancelled.id)

      assert {:error, :cancelled} =
               PendingConfirmations.consume(actor, cancelled_secret, expected(cancelled))

      other = %{actor | athanor_id: "ath_cnf_other"}

      assert {:error, :not_found} =
               PendingConfirmations.consume(other, pending_secret, expected(pending))
    end

    test "a refusal nested in a caller's transaction rolls the whole transaction back", %{
      actor: actor
    } do
      pending_secret = secret()
      pending = record(actor, secret: pending_secret)
      {:ok, _} = open(actor, pending)
      written_first = record(actor)

      # The caller wrote before it consumed, and goes on as if the refusal
      # were only an answer: the refusal took the caller's write with it.
      assert {:error, :rollback} =
               Arca.Repo.transaction(fn ->
                 {:ok, _} = open(actor, written_first)

                 {:error, :not_confirmed} =
                   PendingConfirmations.consume(actor, pending_secret, expected(pending))

                 :committed
               end)

      assert {:error, :not_found} = PendingConfirmations.get(actor, written_first.id)
    end

    test "check/3 answers what consume would, writing nothing, so the caller opens after it", %{
      actor: actor
    } do
      pending_secret = secret()
      pending = record(actor, secret: pending_secret)
      {:ok, _} = open(actor, pending)
      in_its_place = record(actor)

      assert {:ok, {:error, :not_confirmed}} =
               Arca.Repo.transaction(fn ->
                 refusal = PendingConfirmations.check(actor, pending_secret, expected(pending))
                 {:ok, _} = open(actor, in_its_place)
                 refusal
               end)

      assert {:ok, %{state: "pending"}} = PendingConfirmations.get(actor, in_its_place.id)

      confirmed_secret = secret()
      confirmed = record(actor, secret: confirmed_secret)
      confirmed!(actor, confirmed)
      assert :ok = PendingConfirmations.check(actor, confirmed_secret, expected(confirmed))

      assert {:error, :mismatch} =
               PendingConfirmations.check(actor, confirmed_secret, %{
                 expected(confirmed)
                 | args_digest: digest("other")
               })

      assert {:ok, %{state: "confirmed"}} = PendingConfirmations.get(actor, confirmed.id)

      assert {:error, :not_found} =
               PendingConfirmations.check(actor, secret(), expected(confirmed))

      assert {:error, :no_athanor} =
               PendingConfirmations.check(Prima.Actor.system(), confirmed_secret, %{})
    end

    test "runs inside a caller's transaction, rolling back with it", %{actor: actor} do
      secret = secret()
      rec = record(actor, secret: secret)
      confirmed!(actor, rec)

      assert {:error, :effect_failed} =
               Arca.Repo.transaction(fn ->
                 {:ok, _} = PendingConfirmations.consume(actor, secret, expected(rec))
                 Arca.Repo.rollback(:effect_failed)
               end)

      assert {:ok, %{state: "confirmed"}} = PendingConfirmations.get(actor, rec.id)

      assert {:ok, %{state: "consumed"}} =
               PendingConfirmations.consume(actor, secret, expected(rec))
    end
  end

  describe "voiding" do
    test "a record whose confirming client is revoked is voided and refused", %{actor: actor} do
      client = client!(actor)
      secret = secret()
      rec = record(actor, secret: secret)
      {:ok, _} = open(actor, rec)

      {:ok, _} =
        PendingConfirmations.confirm(actor, rec.id, %{proof: "oidc_reauth", client_id: client.id})

      {:ok, _} = PairedClients.revoke(actor, client.id)

      assert {:ok, %{state: "voided"}} = PendingConfirmations.get(actor, rec.id)
      assert {:error, :voided} = PendingConfirmations.consume(actor, secret, expected(rec))
    end

    test "void_for/2 voids what a client confirmed, in the actor's athanor only, naming refs", %{
      actor: actor
    } do
      client = client!(actor)
      rec = record(actor)
      {:ok, _} = open(actor, rec)

      {:ok, _} =
        PendingConfirmations.confirm(actor, rec.id, %{proof: "email_code", client_id: client.id})

      other = Prima.Actor.in_athanor("ath_cnf_other")
      assert {:ok, []} = PendingConfirmations.void_for(other, {:paired_client, client.id})
      assert {:ok, [ref]} = PendingConfirmations.void_for(actor, {:paired_client, client.id})
      assert ref == rec.id

      assert {:error, :cross_tenant} =
               PendingConfirmations.void_for(actor, {:passkey, "psk_x"})
    end
  end

  describe "the member fence" do
    test "a stale member confirms nothing and holds no challenge", %{actor: actor, slot: slot} do
      rec = record(actor)
      {:ok, _} = open(actor, rec)

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
      {:ok, _} = open(actor, rec)

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
    {:ok, _} = open(actor, rec)
    assert {:ok, [%{ref: ref}]} = PendingConfirmations.list_open(actor, "usr_cnf")
    assert ref == rec.id
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
            id: Prima.Confirmation.ref("cnf_race_#{n}"),
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
          PendingConfirmations.open(actor, %{
            record: record,
            opener: "session:race-test",
            asker: %{"kind" => "session"}
          })

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
