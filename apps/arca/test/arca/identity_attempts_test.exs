# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.IdentityAttemptsTest do
  @moduledoc """
  Enrollment, restore and rotation attempts: persisted with their
  immutable submission before any remote call, advanced through their
  phases only in order and only from the phase the row holds, one in
  progress per person and kind (and per installation token), with the
  confirmation an enrollment consumes committed or rolled back with its
  attempt, an enrollment abandoned only before its acceptance, the kit's
  acknowledgment erasing the seed for good, and a stale
  member advancing nothing.
  """

  # Installs the process-wide mode and takes the cell's slot; each case
  # restores both.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{ControlPlane, IdentityAttempts, InstallationClaims, PersonIdentities, Users}
  alias Arca.Schemas.{CellLease, User}

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    slot = hold_slot!()
    mode = if InstallationClaims.installed?(), do: InstallationClaims.mode()

    on_exit(fn ->
      if mode, do: InstallationClaims.install_mode!(mode), else: InstallationClaims.reset()
    end)

    InstallationClaims.install_mode!(:ordinary)
    {:ok, slot: slot}
  end

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
    {:ok, slot} = ControlPlane.take(node, node <> "#boot", 60_000)
    slot
  end

  defp server, do: Prima.Actor.system()
  defp key, do: :crypto.strong_rand_bytes(32)
  defp digest(seed), do: Prima.Digest.sha256("#{seed}-#{System.unique_integer()}")
  defp request_id, do: "req_#{System.unique_integer([:positive])}"

  # The statements a telemetry handler sent this process, in order.
  defp statements(acc \\ []) do
    receive do
      {:statement, source, query} -> statements([{source, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp person! do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()

    {:ok, person} =
      Users.mint(
        server(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          provider: "github",
          email: "iat#{n}@example.com",
          email_verified: true,
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        %{
          key: "github|https://github.com|iat#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "iat#{n}",
          first_seen_at: now,
          last_seen_at: now
        },
        also: fn person ->
          {:ok, _} =
            PersonIdentities.create(server(), %{
              user_id: person.id,
              provenance: "local",
              live_public_key: key(),
              operational_public_key: key(),
              live_key_sealed: "sealed-live",
              operational_key_sealed: "sealed-op"
            })

          :ok
        end
      )

    person
  end

  defp enrollment(user_id, genesis \\ "genesis-#{System.unique_integer()}") do
    hex = Prima.Digest.sha256_hex(genesis)

    %{
      kind: "enrollment",
      request_id: request_id(),
      user_id: user_id,
      identifier: "per_" <> hex,
      directory_url: "https://dir.example",
      genesis: genesis,
      request_digest: "sha256:" <> hex,
      kit_seed_sealed: "sealed-seed"
    }
  end

  defp as(person), do: %Prima.Actor{user_id: person.id}

  defp restore_attrs(%{token: token, request: request, identifier: identifier}) do
    %{
      kind: "restore",
      request_id: request,
      identifier: identifier,
      directory_url: "https://dir.example",
      entry: "recover-request",
      request_digest: digest("recover"),
      expected_revision: 0,
      token_digest: token,
      staged_live_public_key: key(),
      staged_operational_public_key: key(),
      staged_live_key_sealed: "sealed-live",
      staged_operational_key_sealed: "sealed-op"
    }
  end

  # The restore `attempt` moved to `keys_active`, as the restore moves it.
  defp keys_active!(attempt) do
    for {from, to} <- [
          {"staged", "submitted"},
          {"submitted", "accepted"},
          {"accepted", "keys_active"}
        ] do
      {:ok, _} = IdentityAttempts.advance(server(), attempt.id, from, to)
    end

    :ok
  end

  # The restore's person, minted under its claim with the attempt's move to
  # `minted` in the mint's transaction, as the restore mints them.
  defp restored_person!(restore, attempt) do
    now = DateTime.utc_now()

    {:ok, person} =
      Users.mint(
        server(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          provider: "restore",
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        nil,
        restore: %{request_id: restore.request, token_digest: restore.token},
        also: fn minted ->
          case IdentityAttempts.advance(server(), attempt.id, "keys_active", "minted", %{
                 user_id: minted.id
               }) do
            {:ok, _} -> :ok
            {:error, _} = refusal -> refusal
          end
        end
      )

    person
  end

  defp enrolled!(person) do
    {:ok, attempt} = IdentityAttempts.open(as(person), enrollment(person.id))
    {:ok, _} = IdentityAttempts.advance(as(person), attempt.id, "staged", "submitted")
    {:ok, accepted} = IdentityAttempts.advance(as(person), attempt.id, "submitted", "accepted")
    accepted
  end

  describe "enrollment" do
    test "opens staged, with the person pending, and the also: closure in the same transaction" do
      person = person!()
      me = self()

      assert {:ok, attempt} =
               IdentityAttempts.open(as(person), enrollment(person.id),
                 also: fn opened ->
                   send(me, {:also, opened.id})
                   :ok
                 end
               )

      assert attempt.phase == "staged"
      assert_received {:also, id}
      assert id == attempt.id
      assert {:ok, %{enrollment: "pending"}} = PersonIdentities.get(server(), person.id)
    end

    test "a refusing also: closure rolls the attempt back with it" do
      person = person!()

      assert {:error, :confirmation_required} =
               IdentityAttempts.open(as(person), enrollment(person.id),
                 also: fn _attempt -> {:error, :confirmation_required} end
               )

      assert {:error, :not_found} =
               IdentityAttempts.in_progress(as(person), person.id, "enrollment")

      assert {:ok, %{enrollment: "none"}} = PersonIdentities.get(server(), person.id)
    end

    test "an exact retry answers the attempt that stands; another genesis is refused" do
      person = person!()
      attrs = enrollment(person.id)
      {:ok, attempt} = IdentityAttempts.open(as(person), attrs)

      assert {:ok, ^attempt} = IdentityAttempts.open(as(person), attrs)

      assert {:error, :attempt_in_progress} =
               IdentityAttempts.open(as(person), enrollment(person.id, "another genesis"))

      assert {:error, :request_id_reused} =
               IdentityAttempts.open(as(person), %{
                 enrollment(person.id, "third")
                 | request_id: attrs.request_id
               })
    end

    test "phases move only in order, and only from the phase the row holds" do
      person = person!()
      {:ok, attempt} = IdentityAttempts.open(as(person), enrollment(person.id))

      assert {:error, :out_of_order} =
               IdentityAttempts.advance(as(person), attempt.id, "staged", "accepted")

      assert {:error, :out_of_order} =
               IdentityAttempts.advance(as(person), attempt.id, "staged", "keys_active")

      assert {:ok, %{phase: "submitted"}} =
               IdentityAttempts.advance(as(person), attempt.id, "staged", "submitted")

      # A second writer that read `staged` lost: nothing moves.
      assert {:error, :stale} =
               IdentityAttempts.advance(as(person), attempt.id, "staged", "submitted")
    end

    test "acceptance writes the identifier onto the person's row" do
      person = person!()
      accepted = enrolled!(person)

      assert {:ok, row} = PersonIdentities.get(server(), person.id)
      assert row.enrollment == "enrolled"
      assert row.identifier == accepted.identifier
      assert row.head_hash == accepted.request_digest
      assert row.directory_url == "https://dir.example"
    end

    test "a refusal leaves the person without an identifier, the attempt recorded" do
      person = person!()
      {:ok, attempt} = IdentityAttempts.open(as(person), enrollment(person.id))
      {:ok, _} = IdentityAttempts.advance(as(person), attempt.id, "staged", "submitted")

      assert {:ok, refused} =
               IdentityAttempts.advance(as(person), attempt.id, "submitted", "refused", %{
                 outcome: ~s({"status":409})
               })

      assert refused.phase == "refused"
      assert refused.outcome == ~s({"status":409})
      assert is_nil(refused.kit_seed_sealed)

      assert {:ok, %{enrollment: "none", identifier: nil}} =
               PersonIdentities.get(server(), person.id)

      # The person may enroll again.
      assert {:ok, _} = IdentityAttempts.open(as(person), enrollment(person.id))
    end

    test "the kit's acknowledgment erases the seed, and a repeat never restores it" do
      person = person!()
      {:ok, attempt} = IdentityAttempts.open(as(person), enrollment(person.id))
      assert {:error, :not_accepted} = IdentityAttempts.acknowledge_kit(as(person), attempt.id)

      {:ok, _} = IdentityAttempts.advance(as(person), attempt.id, "staged", "submitted")
      {:ok, accepted} = IdentityAttempts.advance(as(person), attempt.id, "submitted", "accepted")
      assert accepted.kit_seed_sealed == "sealed-seed"

      assert {:ok, done} = IdentityAttempts.acknowledge_kit(as(person), accepted.id)
      assert done.phase == "completed"
      assert is_nil(done.kit_seed_sealed)
      assert %DateTime{} = done.kit_acknowledged_at

      assert {:ok, again} = IdentityAttempts.acknowledge_kit(as(person), accepted.id)
      assert is_nil(again.kit_seed_sealed)
      assert {:ok, %{kit_seed_sealed: nil}} = IdentityAttempts.get(as(person), accepted.id)
    end

    test "a person reaches only their own attempts" do
      person = person!()
      {:ok, attempt} = IdentityAttempts.open(as(person), enrollment(person.id))
      stranger = %Prima.Actor{user_id: "usr_stranger"}

      assert {:error, :cross_tenant} = IdentityAttempts.get(stranger, attempt.id)

      assert {:error, :cross_tenant} =
               IdentityAttempts.advance(stranger, attempt.id, "staged", "submitted")

      assert {:error, :cross_tenant} = IdentityAttempts.open(stranger, enrollment(person.id))
    end

    test "the genesis reader answers an accepted or completed enrollment's genesis, and nothing before" do
      person = person!()
      attrs = enrollment(person.id, "the genesis bytes")
      {:ok, attempt} = IdentityAttempts.open(as(person), attrs)

      # Staged, then submitted: not yet the person's identity.
      assert {:error, :not_found} = IdentityAttempts.genesis(as(person), person.id)
      {:ok, _} = IdentityAttempts.advance(as(person), attempt.id, "staged", "submitted")
      assert {:error, :not_found} = IdentityAttempts.genesis(as(person), person.id)

      {:ok, _} = IdentityAttempts.advance(as(person), attempt.id, "submitted", "accepted")

      binding = %{
        genesis: "the genesis bytes",
        identifier: attrs.identifier,
        directory_url: "https://dir.example"
      }

      assert {:ok, ^binding} = IdentityAttempts.genesis(as(person), person.id)
      assert {:ok, ^binding} = IdentityAttempts.genesis(server(), person.id)

      # The kit's acknowledgment completes the attempt and keeps the genesis.
      {:ok, _} = IdentityAttempts.acknowledge_kit(as(person), attempt.id)
      assert {:ok, ^binding} = IdentityAttempts.genesis(as(person), person.id)

      # Only the person, or the platform, reads it.
      stranger = %Prima.Actor{user_id: "usr_stranger"}
      assert {:error, :cross_tenant} = IdentityAttempts.genesis(stranger, person.id)
    end

    test "a refused enrollment leaves no genesis to read" do
      person = person!()
      {:ok, attempt} = IdentityAttempts.open(as(person), enrollment(person.id))
      {:ok, _} = IdentityAttempts.advance(as(person), attempt.id, "staged", "submitted")
      {:ok, _} = IdentityAttempts.advance(as(person), attempt.id, "submitted", "refused")

      assert {:error, :not_found} = IdentityAttempts.genesis(as(person), person.id)
    end

    for from <- ["staged", "submitted"] do
      test "an enrollment abandoned at #{from} ends superseded, its seed erased and the person unenrolled" do
        person = person!()
        {:ok, attempt} = IdentityAttempts.open(as(person), enrollment(person.id))

        if unquote(from) == "submitted",
          do: {:ok, _} = IdentityAttempts.advance(as(person), attempt.id, "staged", "submitted")

        assert {:ok, abandoned} =
                 IdentityAttempts.advance(as(person), attempt.id, unquote(from), "superseded")

        assert abandoned.phase == "superseded"
        assert is_nil(abandoned.kit_seed_sealed)

        assert {:ok, %{enrollment: "none", identifier: nil}} =
                 PersonIdentities.get(server(), person.id)

        assert {:error, :not_found} =
                 IdentityAttempts.in_progress(as(person), person.id, "enrollment")

        assert {:error, :not_found} = IdentityAttempts.genesis(as(person), person.id)

        # An acceptance that read the phase before the abandonment writes
        # nothing, and the person is not enrolled under the abandoned genesis.
        assert {:error, :stale} =
                 IdentityAttempts.advance(as(person), attempt.id, "submitted", "accepted")

        assert {:ok, %{enrollment: "none"}} = PersonIdentities.get(server(), person.id)

        # The person enrolls again under another genesis, so another identifier.
        assert {:ok, fresh} =
                 IdentityAttempts.open(as(person), enrollment(person.id, "the next genesis"))

        assert fresh.identifier != attempt.identifier
        assert {:ok, %{enrollment: "pending"}} = PersonIdentities.get(server(), person.id)
      end
    end

    test "an abandonment locks the person's row before it writes the attempt" do
      person = person!()
      {:ok, attempt} = IdentityAttempts.open(as(person), enrollment(person.id))
      test = self()
      sources = ~w(users identity_attempts person_identities)
      handler = "identity-attempts-order-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == test and meta[:source] in sources,
              do: send(test, {:statement, meta[:source], meta[:query]})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, %{phase: "superseded"}} =
               IdentityAttempts.advance(as(person), attempt.id, "staged", "superseded")

      :telemetry.detach(handler)
      statements = statements()

      # The person's row, then the attempt's write, then the person's
      # identity row: the standing order. Reading the attempt locks nothing.
      ordered =
        for {source, query} <- statements,
            source == "users" or not String.starts_with?(query, "SELECT"),
            do: {source, query |> String.split(" ", parts: 2) |> hd()}

      assert ordered == [
               {"users", "SELECT"},
               {"identity_attempts", "UPDATE"},
               {"person_identities", "UPDATE"}
             ]

      if Arca.Repo.adapter() == Ecto.Adapters.Postgres do
        assert [{"users", lock}] = Enum.filter(statements, &(elem(&1, 0) == "users"))
        assert lock =~ "FOR UPDATE", "the person's row is not locked: #{lock}"
      end
    end

    test "an accepted or completed enrollment is not abandoned, and stays enrolled" do
      person = person!()
      accepted = enrolled!(person)

      assert {:error, :out_of_order} =
               IdentityAttempts.advance(as(person), accepted.id, "accepted", "superseded")

      {:ok, _} = IdentityAttempts.acknowledge_kit(as(person), accepted.id)

      assert {:error, :out_of_order} =
               IdentityAttempts.advance(as(person), accepted.id, "completed", "superseded")

      assert {:ok, %{enrollment: "enrolled", identifier: identifier}} =
               PersonIdentities.get(server(), person.id)

      assert identifier == accepted.identifier
    end
  end

  describe "an added kit (holder)" do
    defp holder(person, accepted, overrides \\ %{}) do
      Map.merge(
        %{
          kind: "holder",
          request_id: request_id(),
          user_id: person.id,
          identifier: accepted.identifier,
          directory_url: "https://dir.example",
          entry: "recover-request",
          request_digest: digest("holder"),
          expected_revision: 0,
          expected_head: accepted.request_digest,
          kit_seed_sealed: "sealed-added-seed"
        },
        overrides
      )
    end

    test "opens at the person's head, and acceptance moves the head to its entry alone" do
      person = person!()
      accepted = enrolled!(person)
      {:ok, before} = PersonIdentities.get(server(), person.id)

      assert {:ok, %{phase: "staged"} = attempt} =
               IdentityAttempts.open(as(person), holder(person, accepted))

      {:ok, _} = IdentityAttempts.advance(as(person), attempt.id, "staged", "submitted")

      # An acceptance names the entry the directory committed.
      assert {:error, {:invalid, %{entry_hash: _}}} =
               IdentityAttempts.advance(as(person), attempt.id, "submitted", "accepted")

      entry_hash = digest("committed recover")

      assert {:ok, %{phase: "accepted", entry_hash: ^entry_hash}} =
               IdentityAttempts.advance(as(person), attempt.id, "submitted", "accepted", %{
                 entry_hash: entry_hash
               })

      assert {:ok, row} = PersonIdentities.get(server(), person.id)
      assert row.head_hash == entry_hash
      assert row.live_public_key == before.live_public_key
      assert row.operational_public_key == before.operational_public_key
      assert row.live_key_sealed == before.live_key_sealed
    end

    test "a head that moved since staging refuses it, and acceptance moves no head" do
      person = person!()
      accepted = enrolled!(person)

      assert {:error, :stale_head} =
               IdentityAttempts.open(
                 as(person),
                 holder(person, accepted, %{expected_head: digest("elsewhere")})
               )

      {:ok, attempt} = IdentityAttempts.open(as(person), holder(person, accepted))
      {:ok, _} = IdentityAttempts.advance(as(person), attempt.id, "staged", "submitted")

      {1, _} =
        Arca.Repo.update_all(
          from(p in Arca.Schemas.PersonIdentity, where: p.user_id == ^person.id),
          set: [head_hash: digest("rotated")]
        )

      assert {:error, :stale_head} =
               IdentityAttempts.advance(as(person), attempt.id, "submitted", "accepted", %{
                 entry_hash: digest("committed")
               })

      assert {:ok, %{phase: "submitted"}} = IdentityAttempts.get(as(person), attempt.id)
    end

    test "a person not enrolled under that identifier opens none" do
      person = person!()

      assert {:error, :not_enrollable} =
               IdentityAttempts.open(
                 as(person),
                 holder(person, %{
                   identifier: "per_" <> String.duplicate("a", 64),
                   request_digest: digest("g")
                 })
               )
    end

    test "a rotation and an added kit never fly together" do
      person = person!()
      accepted = enrolled!(person)

      rotation = %{
        kind: "rotation",
        request_id: request_id(),
        user_id: person.id,
        entry: "rotate-entry",
        entry_hash: digest("rotate"),
        expected_head: accepted.request_digest,
        staged_live_public_key: key(),
        staged_live_key_sealed: "sealed-new-live"
      }

      {:ok, added} = IdentityAttempts.open(as(person), holder(person, accepted))
      assert {:error, :attempt_in_progress} = IdentityAttempts.open(as(person), rotation)

      assert {:error, :attempt_in_progress} =
               IdentityAttempts.open(as(person), holder(person, accepted))

      # Once the added kit is accepted, its head is the one a rotation extends.
      {:ok, _} = IdentityAttempts.advance(as(person), added.id, "staged", "submitted")
      head = digest("accepted kit")

      {:ok, _} =
        IdentityAttempts.advance(as(person), added.id, "submitted", "accepted", %{
          entry_hash: head
        })

      assert {:ok, rotating} =
               IdentityAttempts.open(as(person), %{rotation | expected_head: head})

      assert {:error, :attempt_in_progress} =
               IdentityAttempts.open(as(person), holder(person, accepted, %{expected_head: head}))

      assert {:ok, %{phase: "staged"}} = IdentityAttempts.get(as(person), rotating.id)
    end

    test "its kit is acknowledged as an enrollment's, erasing the seed for good" do
      person = person!()
      accepted = enrolled!(person)
      {:ok, attempt} = IdentityAttempts.open(as(person), holder(person, accepted))
      assert {:error, :not_accepted} = IdentityAttempts.acknowledge_kit(as(person), attempt.id)
      {:ok, _} = IdentityAttempts.advance(as(person), attempt.id, "staged", "submitted")

      {:ok, _} =
        IdentityAttempts.advance(as(person), attempt.id, "submitted", "accepted", %{
          entry_hash: digest("committed")
        })

      assert {:ok, %{phase: "completed", kit_seed_sealed: nil}} =
               IdentityAttempts.acknowledge_kit(as(person), attempt.id)

      assert {:ok, %{kit_seed_sealed: nil}} =
               IdentityAttempts.acknowledge_kit(as(person), attempt.id)
    end

    test "a refused one ends with its seed erased and the head unmoved" do
      person = person!()
      accepted = enrolled!(person)
      {:ok, attempt} = IdentityAttempts.open(as(person), holder(person, accepted))
      {:ok, _} = IdentityAttempts.advance(as(person), attempt.id, "staged", "submitted")

      assert {:ok, %{phase: "refused", kit_seed_sealed: nil}} =
               IdentityAttempts.advance(as(person), attempt.id, "submitted", "refused")

      assert {:ok, %{head_hash: head}} = PersonIdentities.get(server(), person.id)
      assert head == accepted.request_digest
    end
  end

  describe "rotation" do
    test "activates the staged key only at the head it extended" do
      person = person!()
      accepted = enrolled!(person)
      staged = key()
      entry_hash = digest("rotate")

      attrs = %{
        kind: "rotation",
        request_id: request_id(),
        user_id: person.id,
        entry: "rotate-entry",
        entry_hash: entry_hash,
        expected_head: accepted.request_digest,
        staged_live_public_key: staged,
        staged_live_key_sealed: "sealed-new-live"
      }

      assert {:error, :stale_head} =
               IdentityAttempts.open(as(person), %{attrs | expected_head: digest("elsewhere")})

      {:ok, rotation} = IdentityAttempts.open(as(person), attrs)
      {:ok, _} = IdentityAttempts.advance(as(person), rotation.id, "staged", "submitted")
      {:ok, _} = IdentityAttempts.advance(as(person), rotation.id, "submitted", "accepted")

      assert {:ok, %{phase: "keys_active"}} =
               IdentityAttempts.advance(as(person), rotation.id, "accepted", "keys_active")

      assert {:ok, row} = PersonIdentities.get(server(), person.id)
      assert row.live_public_key == staged
      assert row.live_key_sealed == "sealed-new-live"
      assert row.head_hash == entry_hash

      assert {:ok, done} =
               IdentityAttempts.advance(as(person), rotation.id, "keys_active", "completed")

      assert is_nil(done.staged_live_key_sealed)
    end

    test "a head that moved before activation refuses it and changes no key" do
      person = person!()
      accepted = enrolled!(person)

      {:ok, rotation} =
        IdentityAttempts.open(as(person), %{
          kind: "rotation",
          request_id: request_id(),
          user_id: person.id,
          entry: "rotate-entry",
          entry_hash: digest("rotate"),
          expected_head: accepted.request_digest,
          staged_live_public_key: key(),
          staged_live_key_sealed: "sealed-new-live"
        })

      {:ok, _} = IdentityAttempts.advance(as(person), rotation.id, "staged", "submitted")
      {:ok, _} = IdentityAttempts.advance(as(person), rotation.id, "submitted", "accepted")
      {:ok, before} = PersonIdentities.get(server(), person.id)

      {1, _} =
        Arca.Repo.update_all(
          from(p in Arca.Schemas.PersonIdentity, where: p.user_id == ^person.id),
          set: [head_hash: digest("recovered")]
        )

      assert {:error, :stale_head} =
               IdentityAttempts.advance(as(person), rotation.id, "accepted", "keys_active")

      assert {:ok, %{phase: "accepted"}} = IdentityAttempts.get(as(person), rotation.id)
      assert {:ok, after_refusal} = PersonIdentities.get(server(), person.id)
      assert after_refusal.live_public_key == before.live_public_key

      assert {:ok, %{phase: "superseded", staged_live_key_sealed: nil}} =
               IdentityAttempts.advance(as(person), rotation.id, "accepted", "superseded")
    end
  end

  describe "restore" do
    setup do
      # The node is empty inside this test's transaction.
      Arca.Repo.delete_all(User)
      token = digest("token")
      request = request_id()
      identifier = "per_" <> Prima.Digest.sha256_hex("restored-#{System.unique_integer()}")
      {:ok, restore: %{token: token, request: request, identifier: identifier}}
    end

    test "stages with the claim it makes, and a token claimed for another request is refused",
         %{restore: restore} do
      attrs = restore_attrs(restore)
      assert {:ok, %{phase: "staged"} = attempt} = IdentityAttempts.open(server(), attrs)

      assert {:ok, %{state: "pending", request_id: request}} = InstallationClaims.get(server())
      assert request == restore.request

      assert {:error, :claimed} =
               IdentityAttempts.open(server(), %{attrs | request_id: request_id()})

      assert {:ok, ^attempt} = IdentityAttempts.open(server(), attrs)

      assert {:error, :cross_tenant} =
               IdentityAttempts.open(%Prima.Actor{user_id: "usr_x"}, attrs)
    end

    test "resumes through minting, and its end ends the claim", %{restore: restore} do
      {:ok, attempt} = IdentityAttempts.open(server(), restore_attrs(restore))

      for {from, to} <- [
            {"staged", "submitted"},
            {"submitted", "accepted"},
            {"accepted", "keys_active"}
          ] do
        assert {:ok, %{phase: ^to}} = IdentityAttempts.advance(server(), attempt.id, from, to)
      end

      assert {:error, {:invalid, %{user_id: _}}} =
               IdentityAttempts.advance(server(), attempt.id, "keys_active", "minted")

      now = DateTime.utc_now()

      {:ok, person} =
        Users.mint(
          server(),
          %{
            id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
            provider: "restore",
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          nil,
          restore: %{request_id: restore.request, token_digest: restore.token},
          also: fn minted ->
            case IdentityAttempts.advance(server(), attempt.id, "keys_active", "minted", %{
                   user_id: minted.id
                 }) do
              {:ok, _} -> :ok
              {:error, _} = refusal -> refusal
            end
          end
        )

      assert {:ok, %{phase: "minted", user_id: user_id}} =
               IdentityAttempts.get(server(), attempt.id)

      assert user_id == person.id

      assert {:ok, %{phase: "completed", staged_live_key_sealed: nil}} =
               IdentityAttempts.advance(server(), attempt.id, "minted", "completed")

      assert {:ok, %{state: "ended", outcome: "completed"}} = InstallationClaims.get(server())
    end

    test "keeps its genesis, which the restored person's identity rests on",
         %{restore: restore} do
      attrs = Map.put(restore_attrs(restore), :genesis, "the restored genesis")
      {:ok, attempt} = IdentityAttempts.open(server(), attrs)
      assert attempt.genesis == "the restored genesis"

      assert {:ok, %{id: id}} = IdentityAttempts.get_by_token(server(), restore.token)
      assert id == attempt.id
      assert {:error, :not_found} = IdentityAttempts.get_by_token(server(), digest("other"))

      assert {:error, :cross_tenant} =
               IdentityAttempts.get_by_token(%Prima.Actor{user_id: "usr_x"}, restore.token)

      for {from, to, attrs} <- [
            {"staged", "submitted", %{}},
            {"submitted", "accepted", %{entry_hash: digest("recovered")}},
            {"accepted", "keys_active", %{}}
          ] do
        {:ok, _} = IdentityAttempts.advance(server(), attempt.id, from, to, attrs)
      end

      now = DateTime.utc_now()

      {:ok, person} =
        Users.mint(
          server(),
          %{
            id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
            provider: "restore",
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          nil,
          restore: %{request_id: restore.request, token_digest: restore.token},
          also: fn minted ->
            {:ok, _} =
              IdentityAttempts.advance(server(), attempt.id, "keys_active", "minted", %{
                user_id: minted.id
              })

            :ok
          end
        )

      assert {:ok, %{genesis: "the restored genesis", identifier: identifier}} =
               IdentityAttempts.genesis(server(), person.id)

      assert identifier == restore.identifier

      assert {:error, {:invalid, %{genesis: _}}} =
               IdentityAttempts.open(
                 server(),
                 %{
                   restore_attrs(%{restore | request: request_id()})
                   | token_digest: digest("t")
                 }
                 |> Map.put(:genesis, "")
               )
    end

    test "a reproof challenge lives until its expiry on the database's clock, and is used once",
         %{restore: restore} do
      {:ok, attempt} = IdentityAttempts.open(server(), restore_attrs(restore))

      for {from, to} <- [
            {"staged", "submitted"},
            {"submitted", "accepted"},
            {"accepted", "keys_active"}
          ] do
        {:ok, _} = IdentityAttempts.advance(server(), attempt.id, from, to)
      end

      now = DateTime.utc_now()

      {:ok, _person} =
        Users.mint(
          server(),
          %{
            id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
            provider: "restore",
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          nil,
          restore: %{request_id: restore.request, token_digest: restore.token},
          also: fn minted ->
            {:ok, _} =
              IdentityAttempts.advance(server(), attempt.id, "keys_active", "minted", %{
                user_id: minted.id
              })

            :ok
          end
        )

      {:ok, _} = IdentityAttempts.advance(server(), attempt.id, "minted", "completed")

      # Issued for five minutes from the database's clock, as the restore
      # issues it.
      five_minutes = 5 * 60 * 1000
      challenge = digest("challenge")
      issued = Arca.ServerMetaStorage.now!()
      expires_at = DateTime.add(issued, five_minutes, :millisecond)

      assert {:ok, _held} =
               IdentityAttempts.put_reproof(server(), attempt.id, challenge, expires_at)

      assert :ok = IdentityAttempts.reproof_held(server(), attempt.id, challenge)

      assert {:error, :no_challenge} =
               IdentityAttempts.reproof_held(server(), attempt.id, digest("another"))

      assert {:error, :cross_tenant} =
               IdentityAttempts.reproof_held(
                 %Prima.Actor{user_id: "usr_x"},
                 attempt.id,
                 challenge
               )

      # The five minutes pass: the database's clock is past the expiry the
      # row holds. Neither the check nor the consumption accepts it.
      Arca.Repo.update_all(
        from(a in Arca.Schemas.IdentityAttempt, where: a.id == ^attempt.id),
        set: [reproof_expires_at: DateTime.add(issued, -1, :millisecond)]
      )

      assert {:error, :no_challenge} =
               IdentityAttempts.reproof_held(server(), attempt.id, challenge)

      assert {:error, :no_challenge} =
               IdentityAttempts.consume_reproof(server(), attempt.id, challenge)

      # A new one, alive, is consumed once.
      fresh = digest("challenge")

      {:ok, _} =
        IdentityAttempts.put_reproof(
          server(),
          attempt.id,
          fresh,
          DateTime.add(Arca.ServerMetaStorage.now!(), five_minutes, :millisecond)
        )

      assert {:ok, %{reproof_challenge_digest: nil}} =
               IdentityAttempts.consume_reproof(server(), attempt.id, fresh)

      assert {:error, :no_challenge} =
               IdentityAttempts.consume_reproof(server(), attempt.id, fresh)

      assert {:error, :no_challenge} = IdentityAttempts.reproof_held(server(), attempt.id, fresh)
    end

    test "a superseded restore activates nothing and ends its claim", %{restore: restore} do
      {:ok, attempt} = IdentityAttempts.open(server(), restore_attrs(restore))
      {:ok, _} = IdentityAttempts.advance(server(), attempt.id, "staged", "submitted")
      {:ok, _} = IdentityAttempts.advance(server(), attempt.id, "submitted", "accepted")

      assert {:ok, superseded} =
               IdentityAttempts.advance(server(), attempt.id, "accepted", "superseded")

      assert is_nil(superseded.staged_live_key_sealed)
      assert is_nil(superseded.staged_operational_key_sealed)
      assert {:ok, %{state: "ended", outcome: "superseded"}} = InstallationClaims.get(server())
    end

    test "superseded at keys_active, before its mint, it activates nothing and ends its claim",
         %{restore: restore} do
      {:ok, attempt} = IdentityAttempts.open(server(), restore_attrs(restore))
      :ok = keys_active!(attempt)

      assert {:ok, superseded} =
               IdentityAttempts.advance(server(), attempt.id, "keys_active", "superseded", %{
                 outcome: "superseded"
               })

      assert %{phase: "superseded", outcome: "superseded", user_id: nil} = superseded
      assert is_nil(superseded.staged_live_key_sealed)
      assert is_nil(superseded.staged_operational_key_sealed)
      assert {:ok, %{state: "ended", outcome: "superseded"}} = InstallationClaims.get(server())
      assert Arca.Repo.aggregate(User, :count) == 0

      # Ended, it mints nothing after.
      assert {:error, :out_of_order} =
               IdentityAttempts.advance(server(), attempt.id, "superseded", "minted", %{
                 user_id: "usr_late"
               })
    end

    test "superseded at minted, before its session, it ends its claim and its person stays",
         %{restore: restore} do
      {:ok, attempt} = IdentityAttempts.open(server(), restore_attrs(restore))
      :ok = keys_active!(attempt)
      person = restored_person!(restore, attempt)

      assert {:ok, superseded} =
               IdentityAttempts.advance(server(), attempt.id, "minted", "superseded", %{
                 outcome: "superseded"
               })

      assert %{phase: "superseded", outcome: "superseded", user_id: user_id} = superseded
      assert user_id == person.id
      assert is_nil(superseded.staged_live_key_sealed)
      assert is_nil(superseded.staged_operational_key_sealed)
      assert {:ok, %{state: "ended", outcome: "superseded"}} = InstallationClaims.get(server())
      assert {:ok, %{id: ^user_id}} = Users.get(server(), user_id)

      # Ended, it completes nothing after.
      assert {:error, :out_of_order} =
               IdentityAttempts.advance(server(), attempt.id, "superseded", "completed")
    end
  end

  describe "the member fence" do
    test "a stale member opens and advances nothing", %{slot: slot} do
      person = person!()
      other = person!()
      {:ok, attempt} = IdentityAttempts.open(as(person), enrollment(person.id))

      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} =
               IdentityAttempts.advance(as(person), attempt.id, "staged", "submitted")

      assert {:ok, %{phase: "staged"}} = IdentityAttempts.get(as(person), attempt.id)

      assert {:error, :not_owner} = IdentityAttempts.open(as(other), enrollment(other.id))
    end
  end
end

defmodule Arca.IdentityAttemptsRaceTest do
  @moduledoc """
  Two enrollments of one person opened at once, on two real connections
  outside the sandbox, with different genesis bytes: the index on a
  person's active enrollment makes the second wait for the first and then
  refuse, so one durable attempt stands. On PostgreSQL the second blocks
  inserting its row; on SQLite at the lock its transaction takes at entry.
  An abandonment, on its own connection, waits behind the person's row
  lock before it writes the attempt.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.{ControlPlane, IdentityAttempts, PersonIdentities, Users}
  alias Arca.Schemas.{CellLease, ExternalIdentity, IdentityAttempt, PersonIdentity, User}
  alias Ecto.Adapters.SQL.Sandbox

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()
  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres

  setup do
    hold_slot!()
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(IdentityAttempt, user_id: ^user_id))
        Arca.Repo.delete_all(where(PersonIdentity, user_id: ^user_id))
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
            key: "github|https://github.com|iat-race#{n}",
            provider: "github",
            issuer: "https://github.com",
            subject: "iat-race#{n}",
            first_seen_at: now,
            last_seen_at: now
          },
          also: fn person ->
            {:ok, _} =
              PersonIdentities.create(server(), %{
                user_id: person.id,
                provenance: "local",
                live_public_key: :crypto.strong_rand_bytes(32),
                operational_public_key: :crypto.strong_rand_bytes(32),
                live_key_sealed: "sealed-live",
                operational_key_sealed: "sealed-op"
              })

            :ok
          end
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

  defp enrollment(user_id, genesis) do
    hex = Prima.Digest.sha256_hex(genesis)

    %{
      kind: "enrollment",
      request_id: "req_#{System.unique_integer([:positive])}",
      user_id: user_id,
      identifier: "per_" <> hex,
      directory_url: "https://dir.example",
      genesis: genesis,
      request_digest: "sha256:" <> hex,
      kit_seed_sealed: "sealed-seed"
    }
  end

  test "a second enrollment waits behind the first and is refused", %{user_id: user_id} do
    test = self()
    as = %Prima.Actor{user_id: user_id}
    first = enrollment(user_id, "genesis-one-#{System.unique_integer()}")

    opener =
      Task.async(fn ->
        unboxed(fn ->
          IdentityAttempts.open(as, first,
            also: fn _attempt ->
              send(test, :first_holds)

              receive do
                :go -> :ok
              end
            end
          )
        end)
      end)

    assert_receive :first_holds, 5_000

    second =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:second, backend()})
          IdentityAttempts.open(as, enrollment(user_id, "genesis-two-#{System.unique_integer()}"))
        end)
      end)

    assert_receive {:second, pid}, 5_000
    if postgres?(), do: await_wait!(pid, [~s(INSERT INTO "identity_attempts")])
    refute Task.yield(second, 300), "the second enrollment decided while the first held its index"

    send(opener.pid, :go)
    assert {:ok, %{request_id: request}} = Task.await(opener, 25_000)
    assert request == first.request_id
    assert {:error, :attempt_in_progress} = Task.await(second, 25_000)

    assert [%{request_id: ^request}] =
             unboxed(fn -> Arca.Repo.all(where(IdentityAttempt, user_id: ^user_id)) end)
  end

  test "an abandonment waits behind the person's row lock before it writes the attempt",
       %{user_id: user_id} do
    test = self()
    as = %Prima.Actor{user_id: user_id}
    attrs = enrollment(user_id, "genesis-abandoned-#{System.unique_integer()}")
    {:ok, attempt} = unboxed(fn -> IdentityAttempts.open(as, attrs) end)

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            _locked = Arca.DirectoryHeads.lock_person!(user_id)
            send(test, :person_held)

            receive do
              :go -> :ok
            end
          end)
        end)
      end)

    assert_receive :person_held, 5_000

    abandon =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:abandon, backend()})
          IdentityAttempts.advance(as, attempt.id, "staged", "superseded")
        end)
      end)

    assert_receive {:abandon, pid}, 5_000
    if postgres?(), do: await_wait!(pid, [~s(FROM "users"), "FOR UPDATE"])
    refute Task.yield(abandon, 300), "the abandonment decided while the person's row was held"

    assert %{phase: "staged"} =
             unboxed(fn -> Arca.Repo.get!(IdentityAttempt, attempt.id) end)

    send(holder.pid, :go)
    assert {:ok, :ok} = Task.await(holder, 25_000)
    assert {:ok, %{phase: "superseded"}} = Task.await(abandon, 25_000)

    assert {:ok, %{enrollment: "none"}} =
             unboxed(fn -> PersonIdentities.get(server(), user_id) end)
  end
end
