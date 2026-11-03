# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SecurityTransitions.Fixtures do
  @moduledoc false
  # Rows the transition tests act on, written through the storage facades
  # as the layer above writes them.

  import Ecto.Query

  alias Arca.Schemas.{ApiKey, Athanor, Membership, Session, User}

  def server, do: Prima.Actor.system()
  def admit, do: fn _rows -> :ok end
  def uniq, do: System.unique_integer([:positive])

  def person!(overrides \\ %{}) do
    n = uniq()
    now = DateTime.utc_now()

    {:ok, user} =
      Arca.Test.People.mint(
        server(),
        Map.merge(
          %{
            id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
            provider: "github",
            email: "st#{n}@example.com",
            email_verified: true,
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          overrides
        ),
        %{
          key: "github|https://github.com|st#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "st#{n}",
          first_seen_at: now,
          last_seen_at: now
        }
      )

    user
  end

  # A person with their own athanor, seated in it.
  def owner! do
    user = person!()
    n = uniq()

    {:ok, athanor} =
      Arca.Athanors.insert(server(), %{
        name: "Own #{n}",
        slug: "own-#{n}",
        owner_user_id: user.id,
        created_by: user.id
      })

    {:ok, user} = Arca.Users.update(server(), user.id, %{personal_athanor_id: athanor.id})
    seat!(athanor.id, user.id)
    {user, athanor}
  end

  # Another person's athanor, its owner no row here.
  def athanor! do
    n = uniq()

    {:ok, athanor} =
      Arca.Athanors.insert(server(), %{
        name: "A#{n}",
        slug: "st-a-#{n}",
        owner_user_id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
        created_by: "system"
      })

    athanor
  end

  def seat!(athanor_id, user_id) do
    {:ok, row} =
      Arca.Members.seat(Prima.Actor.in_athanor(athanor_id), %{user_id: user_id, added_by: "x"})

    row
  end

  # The person's local identity row, enrolled under an identifier.
  def enrolled!(user_id) do
    now = DateTime.utc_now()
    identifier = "per_" <> Prima.Digest.sha256_hex("st-local-#{uniq()}")

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.PersonIdentity, [
        %{
          id: Prima.UUID7.generate_id("pid"),
          user_id: user_id,
          identifier: identifier,
          provenance: "local",
          enrollment: "enrolled",
          directory_url: "https://dir.example",
          revision: 1,
          inserted_at: now,
          updated_at: now
        }
      ])

    identifier
  end

  # A session of the person, bound to `athanor_id` when one is named.
  def session!(user_id, athanor_id \\ nil) do
    hash = :crypto.strong_rand_bytes(32)

    :ok =
      Arca.SessionStorage.create_session(
        hash,
        %{
          user_id: user_id,
          provider: "github",
          athanor_id: athanor_id,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        Arca.Test.Actor.issuance(user_id)
      )

    hash
  end

  def key!(athanor_id, created_by) do
    n = uniq()
    hash = :crypto.hash(:sha256, "st-key-#{n}")

    :ok =
      Arca.ApiKeyStorage.create_key(
        %{
          name: "k#{n}",
          key_hash: hash,
          key_prefix: "cyfr_sk_st",
          type: "service",
          created_by: created_by,
          athanor_id: athanor_id
        },
        Arca.Test.Actor.issuance(created_by)
      )

    {:ok, %{id: id}} = Arca.ApiKeyStorage.get_key_by_hash(hash)
    id
  end

  # `rows` open offer rows of `athanor_id` addressed to `recipient`, ten
  # files an offer, more than SQLite binds in one statement (32766 when
  # `rows` is past it). Answers the number of offers.
  def open_offers!(athanor_id, recipient, rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires = DateTime.add(now, 7 * 86_400, :second)

    for chunk <- Enum.chunk_every(1..div(rows, 10), 100) do
      Arca.Repo.insert_all(
        Arca.Schemas.FileOffer,
        for offer <- chunk, file <- 1..10 do
          %{
            id: Prima.UUID7.generate_id("fof"),
            athanor_id: athanor_id,
            offer_id: "ofr_many_#{athanor_id}_#{offer}",
            sender_user_id: "usr_many_sender",
            recipient_user_id: recipient,
            filename: "f#{file}.txt",
            digest: "sha256:many",
            size: 1,
            status: "offered",
            expires_at: expires,
            inserted_at: now,
            updated_at: now
          }
        end
      )
    end

    div(rows, 10)
  end

  def open_offer_count(athanor_id) do
    from(o in Arca.Schemas.FileOffer,
      where: o.athanor_id == ^athanor_id and o.status == "offered"
    )
    |> Arca.Repo.aggregate(:count)
  end

  def offer_statuses(offer_id) do
    from(o in Arca.Schemas.FileOffer, where: o.offer_id == ^offer_id, select: o.status)
    |> Arca.Repo.all()
  end

  # An athanor's stored tree, for a case that wrote bytes into it to
  # remove after itself.
  def storage_root(athanor_id),
    do: Arca.Adapters.Local.build_path(Prima.Actor.in_athanor(athanor_id), [])

  def user(id), do: Arca.Repo.get(User, id)
  def athanor(id), do: Arca.Repo.get(Athanor, id)
  def session?(hash), do: Arca.Repo.exists?(where(Session, token_hash: ^hash))
  def revoked?(key_id), do: Arca.Repo.get(ApiKey, key_id).revoked
  def seats(user_id), do: Arca.Repo.all(where(Membership, user_id: ^user_id))
  def membership(id), do: Arca.Repo.get(Membership, id)

  # A frame credential row, written as its store writes one. Inserted
  # directly: minting is fenced by the member's slot, which these tests do
  # not hold, and what they measure is the transition's retirement.
  def frame!(athanor_id, user_id, state \\ "active") do
    now = DateTime.utc_now()
    id = Prima.UUID7.generate_id("frc")

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.FrameCredential, [
        %{
          id: id,
          athanor_id: athanor_id,
          user_id: user_id,
          publisher: "acme",
          name: "dash",
          version: "1.0.0",
          version_digest: "sha256:" <> String.duplicate("b", 64),
          grant_revision: 1,
          frame_id: "frm_#{uniq()}",
          source_kind: "session",
          source_id: "c3Q",
          state: state,
          deadline: DateTime.add(now, 3600, :second),
          inserted_at: now,
          updated_at: now
        }
      ])

    id
  end

  def frame_state(id), do: Arca.Repo.get(Arca.Schemas.FrameCredential, id).state

  # A paired client row, written as its store writes one. Inserted
  # directly for the same reason as a frame credential: recording is fenced
  # by the member's slot, which these tests do not hold.
  def paired!(athanor_id, user_id, standing \\ "active") do
    now = DateTime.utc_now()
    id = Prima.UUID7.generate_id("pcl")

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.PairedClient, [
        %{
          id: id,
          athanor_id: athanor_id,
          user_id: user_id,
          source_kind: "session",
          source_id: "src_#{uniq()}",
          standing: standing,
          inserted_at: now,
          updated_at: now
        }
      ])

    id
  end

  def paired_standing(id), do: Arca.Repo.get(Arca.Schemas.PairedClient, id).standing

  # A device certificate, a pending pairing invitation, a passkey and a
  # pending confirmation, each inserted directly for the reason a frame
  # is: writing them is fenced by the member's slot.
  def certificate!(athanor_id, user_id, paired_client_id) do
    now = DateTime.utc_now()
    id = Prima.UUID7.generate_id("dct")

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.DeviceCertificate, [
        %{
          id: id,
          athanor_id: athanor_id,
          paired_client_id: paired_client_id,
          user_id: user_id,
          subject_kind: "local",
          device_public_key: :crypto.strong_rand_bytes(32),
          issuing_home: "https://home.example",
          audience_home: "https://home.example",
          not_before: now,
          expires_at: DateTime.add(now, 3600, :second),
          certificate: "cert-#{uniq()}",
          digest: Prima.Digest.sha256("cert-#{uniq()}"),
          state: "active",
          inserted_at: now,
          updated_at: now
        }
      ])

    id
  end

  def certificate_state(id), do: Arca.Repo.get(Arca.Schemas.DeviceCertificate, id).state

  def invitation!(athanor_id, user_id) do
    now = DateTime.utc_now()
    id = Prima.UUID7.generate_id("pin")

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.PairingInvitation, [
        %{
          id: id,
          athanor_id: athanor_id,
          secret_hash: Prima.Digest.sha256("secret-#{uniq()}"),
          user_id: user_id,
          membership_id: "mem_#{uniq()}",
          prospective_client_id: Prima.UUID7.generate_id("pcl"),
          audience_home: "https://home.example",
          expires_at: DateTime.add(now, 300, :second),
          state: "pending",
          inserted_at: now,
          updated_at: now
        }
      ])

    id
  end

  def invitation_state(id), do: Arca.Repo.get(Arca.Schemas.PairingInvitation, id).state

  def passkey!(user_id) do
    now = DateTime.utc_now()
    id = Prima.UUID7.generate_id("psk")

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.Passkey, [
        %{
          id: id,
          user_id: user_id,
          credential_id: "cred-#{uniq()}",
          rp_id: "home.example",
          relying_home: "https://home.example",
          public_key: "cose",
          sign_count: 0,
          state: "active",
          registration_digest: Prima.Digest.sha256("reg-#{uniq()}"),
          possession_verified: true,
          inserted_at: now,
          updated_at: now
        }
      ])

    id
  end

  def passkey_state(id), do: Arca.Repo.get(Arca.Schemas.Passkey, id).state

  def confirmation!(athanor_id, user_id, confirmed_by \\ []) do
    now = DateTime.utc_now()
    ref = Prima.Confirmation.ref("cnf_#{uniq()}")

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.PendingConfirmation, [
        %{
          ref: ref,
          athanor_id: athanor_id,
          user_id: user_id,
          operation: "vault.create",
          args_digest: Prima.Digest.sha256("args-#{uniq()}"),
          action: "credential_entry",
          preview: "{}",
          home: "https://home.example",
          rp_id: "home.example",
          challenge: :crypto.strong_rand_bytes(32),
          digest: Prima.Digest.sha256("record-#{uniq()}"),
          opener: "session:security-transitions-test",
          asker: ~s({"kind":"session"}),
          state: if(confirmed_by == [], do: "pending", else: "confirmed"),
          proof: if(confirmed_by == [], do: nil, else: "passkey"),
          confirmed_client_id: confirmed_by[:client],
          confirmed_passkey_id: confirmed_by[:passkey],
          email_code_failures: 0,
          opened_at: now,
          expires_at: DateTime.add(now, 300, :second),
          inserted_at: now,
          updated_at: now
        }
      ])

    ref
  end

  def confirmation_state(id), do: Arca.Repo.get(Arca.Schemas.PendingConfirmation, id).state

  # A trigger that makes one statement fail inside the transition, spelled
  # per adapter. The sandbox rolls it back with the test.
  def fail_on!(table, event) do
    name = "st_fail_#{table}_#{String.downcase(event)}"

    if Arca.Test.Adapter.sqlite?() do
      Arca.Repo.query!(
        "CREATE TRIGGER #{name} BEFORE #{event} ON #{table} " <>
          "BEGIN SELECT RAISE(ABORT, 'injected #{event} failure'); END"
      )
    else
      Arca.Repo.query!(
        "CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS " <>
          "$$ BEGIN RAISE EXCEPTION 'injected #{event} failure'; END $$"
      )

      Arca.Repo.query!(
        "CREATE TRIGGER #{name} BEFORE #{event} ON #{table} " <>
          "FOR EACH ROW EXECUTE FUNCTION #{name}()"
      )
    end

    name
  end

  def clear_failure!(name) do
    if Arca.Test.Adapter.sqlite?() do
      Arca.Repo.query!("DROP TRIGGER #{name}")
    else
      table =
        Regex.replace(~r/_(delete|update)$/, Regex.replace(~r/^st_fail_/, name, ""), "")

      Arca.Repo.query!("DROP TRIGGER #{name} ON #{table}")
      Arca.Repo.query!("DROP FUNCTION #{name}()")
    end
  end
end

defmodule Arca.SecurityTransitionsTest do
  @moduledoc """
  The standing transitions, each one transaction: what a denial retires,
  its seats and invitations in shared threads and its person's own
  athanor included, what an allow restores and what it never does, the
  generation every real change raises, and a failed statement rolling
  back everything — the injected session DELETE, key UPDATE and
  certificate UPDATE failures included, after which an allow revives
  nothing, and a failed retirement inside an allow, which leaves the
  denial standing.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Arca.SecurityTransitions.Fixtures

  alias Arca.SecurityTransitions

  @offer_end_events [
    [:cyfr, :arca, :file_offer, :withdrawn],
    [:cyfr, :arca, :file_offer, :declined]
  ]

  # The tables an allow retires stragglers in, each inside the
  # transition's transaction: a client's confirmations are voided with it
  # (`Arca.PairedClients.retire_dependents!/1`).
  @retirement_tables ~w(frame_credentials paired_clients device_certificates
                        pairing_invitations pending_confirmations)

  defp observe_offer_ends!(athanor_id, offers) do
    # The fixture's offer IDs include its tenant; file telemetry carries no
    # separate tenant field. Exact membership excludes every other fixture.
    config = %{
      offer_ids: MapSet.new(1..offers, &"ofr_many_#{athanor_id}_#{&1}"),
      counters: :atomics.new(2, signed: false)
    }

    counter_id = {__MODULE__, :offer_counts, make_ref()}
    audit_id = {__MODULE__, :fixture_audit, make_ref()}

    on_exit(fn ->
      :telemetry.detach(counter_id)
      :telemetry.detach(audit_id)
    end)

    if Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :cyfr end) do
      assert is_pid(Process.whereis(Arca.AuditHandler)), "umbrella audit process must be running"

      for event <- @offer_end_events do
        assert event in Arca.AuditHandler.events()

        assert Enum.any?(:telemetry.list_handlers(event), fn handler ->
                 handler.id == "audit-" <> Enum.join(event, "-") and
                   handler.function == (&Arca.AuditHandler.handle_event/4)
               end),
               "umbrella audit callback must be installed for #{inspect(event)}"
      end
    else
      # The Arca island has no Host boot. Compose the same real lower-layer
      # handler for this fixture alone; never replace a boot-owned callback.
      assert :ok =
               :telemetry.attach_many(
                 audit_id,
                 @offer_end_events,
                 &__MODULE__.audit_fixture_offer/4,
                 config
               )
    end

    assert :ok =
             :telemetry.attach_many(
               counter_id,
               @offer_end_events ++ [[:cyfr, :audit, :recorded]],
               &__MODULE__.count_fixture_offer/4,
               config
             )

    config.counters
  end

  @doc false
  def audit_fixture_offer(event, measurements, metadata, config) do
    if MapSet.member?(config.offer_ids, metadata.offer_id) do
      Arca.AuditHandler.handle_event(event, measurements, metadata, nil)
    end
  end

  @doc false
  def count_fixture_offer([:cyfr, :audit, :recorded], _measurements, %{audited: audited}, config) do
    if audited.name in @offer_end_events and
         MapSet.member?(config.offer_ids, audited.metadata.offer_id) do
      :atomics.add(config.counters, 2, 1)
    end
  end

  def count_fixture_offer(_event, _measurements, metadata, config) do
    if MapSet.member?(config.offer_ids, metadata.offer_id) do
      :atomics.add(config.counters, 1, 1)
    end
  end

  # A frame, a paired client with its certificate and a confirmation it
  # confirmed, and a pairing invitation of the person in the athanor,
  # issued after a denial: what the allow that follows retires.
  defp stragglers!(athanor_id, user_id) do
    client = paired!(athanor_id, user_id)

    [
      {Arca.Schemas.FrameCredential, frame!(athanor_id, user_id)},
      {Arca.Schemas.PairedClient, client},
      {Arca.Schemas.DeviceCertificate, certificate!(athanor_id, user_id, client)},
      {Arca.Schemas.PairingInvitation, invitation!(athanor_id, user_id)},
      {Arca.Schemas.PendingConfirmation, confirmation!(athanor_id, user_id, client: client)}
    ]
  end

  # Each straggler's whole row, as stored.
  defp rows(stragglers), do: for({schema, id} <- stragglers, do: Arca.Repo.get(schema, id))

  defp straggler_states([frame, client, cert, invitation, confirmation]) do
    [
      frame_state(elem(frame, 1)),
      paired_standing(elem(client, 1)),
      certificate_state(elem(cert, 1)),
      invitation_state(elem(invitation, 1)),
      confirmation_state(elem(confirmation, 1))
    ]
  end

  # What the transition answers it retired, one list per straggler's kind.
  defp retired_ids(change) do
    [
      change.revoked_frame_credential_ids,
      change.revoked_paired_client_ids,
      change.revoked_device_certificate_ids,
      change.revoked_pairing_invitation_ids,
      change.voided_confirmation_ids
    ]
  end

  defp straggler_ids(stragglers), do: for({_schema, id} <- stragglers, do: [id])

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  # A shared thread `by` made, with `others` seated in it by them.
  defp shared_thread!(by, others \\ []) do
    {:ok, thread} =
      Arca.SharedThreads.create(server(), %{title: "T#{uniq()}", created_by: by})

    for other <- others,
        do: {:ok, _} = Arca.SharedThreadMembers.seat(server(), thread.id, other, by)

    thread
  end

  defp shared_thread(id) do
    {:ok, thread} = Arca.SharedThreads.get(server(), id)
    thread
  end

  # The person's seats and their identifier's invitations, in any shared
  # thread.
  defp shared_rows(user_id, identifier) do
    Arca.Repo.all(
      from(m in Arca.Schemas.SharedThreadMember,
        where: m.user_id == ^user_id or m.person_identifier == ^identifier
      )
    )
  end

  describe "deny_user/3" do
    test "retires every credential and seat, and archives their own athanor" do
      {user, own} = owner!()
      {peer, theirs} = owner!()

      own_session = session!(user.id, own.id)
      other_session = session!(user.id)
      own_key = key!(own.id, user.id)
      made_elsewhere = key!(theirs.id, user.id)
      peer_key = key!(theirs.id, peer.id)

      assert {:ok, change} =
               SecurityTransitions.deny_user(server(), user.id, verify: admit())

      assert change.transitioned
      assert change.user_generation == 2
      assert user(user.id).status == "denied"
      assert user(user.id).security_generation == 2

      # Archived: the person's own athanor alone; another person's stands.
      assert change.archived_athanor_ids == [own.id]
      assert athanor(own.id).status == "archived"
      assert change.athanor_generations == %{own.id => 2}
      assert athanor(theirs.id).status == "active"
      assert athanor(theirs.id).security_generation == 1

      # The hashes and ids are the ones the statements removed.
      assert Enum.sort(change.revoked_session_hashes) == Enum.sort([own_session, other_session])
      refute session?(own_session) or session?(other_session)

      assert change.revoked_api_key_ids == Enum.sort([own_key, made_elsewhere])
      assert revoked?(own_key) and revoked?(made_elsewhere)
      refute revoked?(peer_key)

      assert seats(user.id) == []
      assert length(change.removed_membership_ids) == 1
      assert change.member_user_ids == %{own.id => [user.id]}
    end

    test "takes their seats and invitations in shared threads, and ends a pair or a thread left empty" do
      user = person!()
      peer = person!()
      host = person!()
      identifier = enrolled!(user.id)

      alone = shared_thread!(user.id)
      kept = shared_thread!(peer.id, [user.id])
      {:ok, pair} = Arca.SharedThreads.pair(server(), user.id, peer.id)
      ended = shared_thread!(user.id, [peer.id])
      {:ok, _} = Arca.SharedThreads.archive(server(), ended.id, ended.created_by)
      invited = shared_thread!(host.id)
      {:ok, _} = Arca.SharedThreadMembers.invite(server(), invited.id, identifier, host.id)

      assert {:ok, change} = SecurityTransitions.deny_user(server(), user.id, verify: admit())

      assert change.left_shared_thread_ids ==
               Enum.sort([pair.id, alone.id, kept.id, ended.id])

      # The pair they sat in and the thread they leave empty end, one
      # generation up; one a peer still sits in stands, and one archived
      # already keeps its generation.
      assert change.archived_shared_thread_ids == Enum.sort([pair.id, alone.id])

      for thread <- [pair, alone],
          do: assert(%{status: "archived", security_generation: 2} = shared_thread(thread.id))

      assert %{status: "active", security_generation: 1} = shared_thread(kept.id)
      assert %{status: "archived", security_generation: 2} = shared_thread(ended.id)
      assert %{status: "active", security_generation: 1} = shared_thread(invited.id)

      assert shared_rows(user.id, identifier) == []

      assert {:ok, %{user_id: peer_id}} =
               Arca.SharedThreadMembers.find(server(), kept.id, peer.id)

      assert peer_id == peer.id
      assert {:ok, [%{user_id: host_id}]} = Arca.SharedThreadMembers.list(server(), invited.id)
      assert host_id == host.id

      # A repeated denial finds no seat left to take.
      assert {:ok, again} = SecurityTransitions.deny_user(server(), user.id, verify: admit())
      assert again.left_shared_thread_ids == [] and again.archived_shared_thread_ids == []
    end

    test "ends their offers both ways" do
      {user, own} = owner!()
      {peer, peer_own} = owner!()
      shared_thread!(user.id, [peer.id])

      mine = %Prima.Actor{athanor_id: own.id, user_id: user.id}
      theirs = %Prima.Actor{athanor_id: peer_own.id, user_id: peer.id}
      on_exit(fn -> for a <- [own.id, peer_own.id], do: File.rm_rf(storage_root(a)) end)

      :ok = Arca.put(mine, ["data", "out.txt"], "from the denied")
      :ok = Arca.put(theirs, ["data", "in.txt"], "to the denied")
      {:ok, %{offer_id: sent}} = Arca.FileOffers.offer(mine, peer.id, ["data/out.txt"])
      {:ok, %{offer_id: incoming}} = Arca.FileOffers.offer(theirs, user.id, ["data/in.txt"])

      test_pid = self()
      handler = "deny-offers-#{uniq()}"

      :telemetry.attach_many(
        handler,
        [[:cyfr, :arca, :file_offer, :withdrawn], [:cyfr, :arca, :file_offer, :declined]],
        fn event, _m, meta, _c -> send(test_pid, {event, meta.offer_id}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, change} = SecurityTransitions.deny_user(server(), user.id, verify: admit())

      assert change.ended_offer_ids == Enum.sort([sent, incoming])
      refute Map.has_key?(change, :ended_offers)

      assert {:ok, [%{status: "withdrawn"}]} = Arca.FileOffers.outbox(mine)
      assert {:ok, [%{status: "declined"}]} = Arca.FileOffers.inbox(mine)

      # Each snapshot is released once the denial commits, and announced.
      assert {:error, :not_found} = Arca.get(mine, ["payloads", "offers", sent, "out.txt"])
      assert {:error, :not_found} = Arca.get(theirs, ["payloads", "offers", incoming, "in.txt"])
      assert_receive {[:cyfr, :arca, :file_offer, :withdrawn], ^sent}
      assert_receive {[:cyfr, :arca, :file_offer, :declined], ^incoming}
    end

    test "withdraws the open offers of the athanor it archives, whoever sent them" do
      {user, own} = owner!()
      elsewhere = person!()

      # Sent from their athanor by someone else, to someone the denied
      # person never met: no clause of theirs names it, but the denial
      # archives the athanor it was sent from.
      # One offer of ten files.
      1 = open_offers!(own.id, elsewhere.id, 10)
      stranded = "ofr_many_#{own.id}_1"

      assert {:ok, change} = SecurityTransitions.deny_user(server(), user.id, verify: admit())

      assert change.archived_athanor_ids == [own.id]
      assert change.ended_offer_ids == [stranded]
      assert offer_statuses(stranded) == List.duplicate("withdrawn", 10)
    end

    test "ends more open offers than one statement can name" do
      user = person!()
      theirs = athanor!()
      offers = open_offers!(theirs.id, user.id, 32_800)
      counters = observe_offer_ends!(theirs.id, offers)

      assert {:ok, change} = SecurityTransitions.deny_user(server(), user.id, verify: admit())
      assert :atomics.get(counters, 1) == 32_800
      assert :atomics.get(counters, 2) == 32_800
      assert length(change.ended_offer_ids) == offers
      assert open_offer_count(theirs.id) == 0
    end

    test "a repeated denial moves no generation and still checks what it retires" do
      {user, own} = owner!()
      {:ok, _} = SecurityTransitions.deny_user(server(), user.id, verify: admit())

      # Something that survived a lost write: a session and a key issued
      # around the first denial.
      straggler = session!(user.id)
      key = key!(own.id, user.id)

      assert {:ok, change} = SecurityTransitions.deny_user(server(), user.id, verify: admit())
      refute change.transitioned
      assert change.user_generation == 2
      assert change.archived_athanor_ids == []
      assert change.revoked_session_hashes == [straggler]
      assert change.revoked_api_key_ids == [key]
      assert user(user.id).security_generation == 2
      assert athanor(own.id).security_generation == 2
    end

    test "a person with no own athanor is denied; a pointer to no row is refused" do
      plain = person!()

      assert {:ok, %{archived_athanor_ids: []}} =
               SecurityTransitions.deny_user(server(), plain.id, verify: admit())

      dangling = person!()
      {:ok, _} = Arca.Users.update(server(), dangling.id, %{personal_athanor_id: "ath_nowhere"})
      session = session!(dangling.id)

      assert {:error, :dangling_personal_athanor} =
               SecurityTransitions.deny_user(server(), dangling.id, verify: admit())

      assert user(dangling.id).status == "active"
      assert session?(session)
    end

    test "the caller's refusal rolls back everything, with its reason" do
      {user, own} = owner!()
      session = session!(user.id)
      key = key!(own.id, user.id)

      assert {:error, :operator_said_no} =
               SecurityTransitions.deny_user(server(), user.id,
                 verify: fn %{user: %{id: id}, archive: archive} ->
                   send(self(), {:asked, id, archive})
                   {:error, :operator_said_no}
                 end
               )

      assert_received {:asked, id, [own_id]}
      assert id == user.id and own_id == own.id
      assert user(user.id).status == "active"
      assert athanor(own.id).status == "active"
      assert session?(session)
      refute revoked?(key)
    end

    test "an unknown person and a non-system actor are refused before anything moves" do
      assert {:error, :not_found} =
               SecurityTransitions.deny_user(server(), "usr_nobody", verify: admit())

      user = person!()

      assert {:error, :cross_tenant} =
               SecurityTransitions.deny_user(Prima.Actor.in_athanor("ath_test"), user.id,
                 verify: admit()
               )

      assert user(user.id).status == "active"
    end
  end

  describe "an injected failure inside a denial" do
    for {table, event, label} <- [
          {"sessions", "DELETE", "the session DELETE"},
          {"api_keys", "UPDATE", "the key UPDATE"},
          {"memberships", "DELETE", "the membership DELETE"},
          {"athanors", "UPDATE", "the athanor UPDATE"},
          {"users", "UPDATE", "the person UPDATE"}
        ] do
      test "#{label} failing rolls the denial back, and an allow then revives nothing" do
        {user, own} = owner!()
        session = session!(user.id, own.id)
        key = key!(own.id, user.id)
        frame = frame!(own.id, user.id)
        failure = fail_on!(unquote(table), unquote(event))

        assert {:error, :database_error} =
                 SecurityTransitions.deny_user(server(), user.id, verify: admit())

        assert frame_state(frame) == "active"

        # Nothing committed: no denial with a live credential, and no
        # half-archived athanor.
        assert user(user.id).status == "active"
        assert user(user.id).security_generation == 1
        assert athanor(own.id).status == "active"
        assert session?(session)
        refute revoked?(key)
        assert length(seats(user.id)) == 1

        # An allow over the failed denial has nothing to restore and moves
        # nothing.
        assert {:ok, %{transitioned: false, user_generation: 1}} =
                 SecurityTransitions.allow_user(server(), user.id, verify: admit())

        # The retry, once the statement can run, retires everything; the
        # allow after it restores the standing and none of the credentials.
        clear_failure!(failure)

        assert {:ok, %{transitioned: true}} =
                 SecurityTransitions.deny_user(server(), user.id, verify: admit())

        assert {:ok, allowed} = SecurityTransitions.allow_user(server(), user.id, verify: admit())
        assert allowed.user_generation == 3
        refute session?(session)
        assert revoked?(key)
        assert athanor(own.id).status == "active"
        assert athanor(own.id).security_generation == 3
      end
    end
  end

  describe "allow_user/3" do
    test "restores standing, the own athanor and a new seat in it, and nothing else" do
      {user, own} = owner!()
      seat!(athanor!().id, user.id)
      key = key!(own.id, user.id)
      {:ok, denied} = SecurityTransitions.deny_user(server(), user.id, verify: admit())

      [old_seat] =
        for %{athanor_id: id} = row <- denied.removed_memberships, id == own.id, do: row

      assert {:ok, change} = SecurityTransitions.allow_user(server(), user.id, verify: admit())
      assert change.transitioned
      assert change.user_generation == 3
      assert change.reopened_athanor_ids == [own.id]
      assert change.athanor_generations == %{own.id => 3}
      assert [seated] = change.seated_membership_ids
      refute seated == old_seat.id

      assert user(user.id).status == "active"
      assert athanor(own.id).status == "active"
      assert Enum.map(seats(user.id), & &1.athanor_id) == [own.id]
      assert revoked?(key)
      assert change.revoked_session_hashes == [] and change.revoked_api_key_ids == []
    end

    test "the caller's cap refusal leaves the person denied and the athanor archived" do
      {user, own} = owner!()
      {:ok, _} = SecurityTransitions.deny_user(server(), user.id, verify: admit())

      assert {:error, {:limit_reached, :max_athanors, 1}} =
               SecurityTransitions.allow_user(server(), user.id,
                 verify: fn %{athanor: %{status: "archived"}} ->
                   {:error, {:limit_reached, :max_athanors, 1}}
                 end
               )

      assert user(user.id).status == "denied"
      assert user(user.id).security_generation == 2
      assert athanor(own.id).status == "archived"
      assert seats(user.id) == []
    end

    for table <- @retirement_tables do
      test "an injected #{table} UPDATE failure rolls the allow back with every straggler standing" do
        {user, own} = owner!()
        {:ok, _} = SecurityTransitions.deny_user(server(), user.id, verify: admit())
        stragglers = stragglers!(own.id, user.id)
        before = {user(user.id), athanor(own.id), rows(stragglers)}
        assert {elem(before, 0).status, elem(before, 1).status} == {"denied", "archived"}
        failure = fail_on!(unquote(table), "UPDATE")

        assert {:error, :database_error} =
                 SecurityTransitions.allow_user(server(), user.id, verify: admit())

        # Nothing committed, row for row: no restored standing, reopened
        # athanor or new seat beside a credential the allow was to retire.
        assert {user(user.id), athanor(own.id), rows(stragglers)} == before
        assert seats(user.id) == []

        clear_failure!(failure)

        assert {:ok, change} = SecurityTransitions.allow_user(server(), user.id, verify: admit())
        assert change.transitioned
        assert change.user_generation == 3
        assert retired_ids(change) == straggler_ids(stragglers)
        assert user(user.id).status == "active"
        assert athanor(own.id).status == "active"

        assert straggler_states(stragglers) ==
                 ["revoked", "revoked", "revoked", "revoked", "voided"]
      end
    end
  end

  describe "frame credentials" do
    test "a denial revokes the person's frames everywhere and every frame of what it archives" do
      {user, own} = owner!()
      {peer, theirs} = owner!()

      mine_own = frame!(own.id, user.id)
      mine_theirs = frame!(theirs.id, user.id, "suspended")
      peer_theirs = frame!(theirs.id, peer.id)
      # A frame of another person in the athanor the denial archives.
      guest_own = frame!(own.id, peer.id)
      already = frame!(own.id, user.id, "revoked")

      assert {:ok, change} = SecurityTransitions.deny_user(server(), user.id, verify: admit())

      assert change.revoked_frame_credential_ids == Enum.sort([mine_own, mine_theirs, guest_own])

      for id <- [mine_own, mine_theirs, guest_own, already],
          do: assert(frame_state(id) == "revoked")

      assert frame_state(peer_theirs) == "active"
    end

    test "an allow revokes a frame that outlived the denial and restores none" do
      {user, own} = owner!()
      opened = frame!(own.id, user.id)
      {:ok, _} = SecurityTransitions.deny_user(server(), user.id, verify: admit())
      straggler = frame!(own.id, user.id)

      assert {:ok, change} = SecurityTransitions.allow_user(server(), user.id, verify: admit())
      assert change.revoked_frame_credential_ids == [straggler]
      assert frame_state(opened) == "revoked"
      assert frame_state(straggler) == "revoked"
    end

    test "an injected frame UPDATE failure rolls a denial back with every credential standing" do
      {user, own} = owner!()
      session = session!(user.id, own.id)
      key = key!(own.id, user.id)
      frame = frame!(own.id, user.id)
      failure = fail_on!("frame_credentials", "UPDATE")

      assert {:error, :database_error} =
               SecurityTransitions.deny_user(server(), user.id, verify: admit())

      assert user(user.id).status == "active"
      assert athanor(own.id).status == "active"
      assert session?(session)
      refute revoked?(key)
      assert frame_state(frame) == "active"

      clear_failure!(failure)

      assert {:ok, %{revoked_frame_credential_ids: [^frame]}} =
               SecurityTransitions.deny_user(server(), user.id, verify: admit())
    end
  end

  describe "paired clients" do
    test "a denial revokes the person's clients everywhere and every client of what it archives" do
      {user, own} = owner!()
      {peer, theirs} = owner!()

      mine_own = paired!(own.id, user.id)
      mine_theirs = paired!(theirs.id, user.id)
      peer_theirs = paired!(theirs.id, peer.id)
      # A client of another person in the athanor the denial archives.
      guest_own = paired!(own.id, peer.id)
      already = paired!(own.id, user.id, "revoked")

      assert {:ok, change} = SecurityTransitions.deny_user(server(), user.id, verify: admit())

      assert change.revoked_paired_client_ids == Enum.sort([mine_own, mine_theirs, guest_own])

      for id <- [mine_own, mine_theirs, guest_own, already],
          do: assert(paired_standing(id) == "revoked")

      assert paired_standing(peer_theirs) == "active"
    end

    test "an allow revokes a client that outlived the denial and restores none" do
      {user, own} = owner!()
      paired = paired!(own.id, user.id)
      {:ok, _} = SecurityTransitions.deny_user(server(), user.id, verify: admit())
      straggler = paired!(own.id, user.id)

      assert {:ok, change} = SecurityTransitions.allow_user(server(), user.id, verify: admit())
      assert change.revoked_paired_client_ids == [straggler]
      assert paired_standing(paired) == "revoked"
      assert paired_standing(straggler) == "revoked"
    end

    test "an injected client UPDATE failure rolls a denial back with every credential standing" do
      {user, own} = owner!()
      session = session!(user.id, own.id)
      frame = frame!(own.id, user.id)
      paired = paired!(own.id, user.id)
      failure = fail_on!("paired_clients", "UPDATE")

      assert {:error, :database_error} =
               SecurityTransitions.deny_user(server(), user.id, verify: admit())

      assert user(user.id).status == "active"
      assert session?(session)
      assert frame_state(frame) == "active"
      assert paired_standing(paired) == "active"

      clear_failure!(failure)

      assert {:ok,
              %{revoked_paired_client_ids: [^paired], revoked_frame_credential_ids: [^frame]}} =
               SecurityTransitions.deny_user(server(), user.id, verify: admit())
    end
  end

  describe "device certificates, pairing invitations, passkeys and confirmations" do
    test "a denial retires them everywhere the person stood, and in what it archives" do
      {user, own} = owner!()
      {peer, theirs} = owner!()

      client = paired!(theirs.id, user.id)
      cert = certificate!(theirs.id, user.id, client)
      guest_client = paired!(own.id, peer.id)
      guest_cert = certificate!(own.id, peer.id, guest_client)
      peer_client = paired!(theirs.id, peer.id)
      peer_cert = certificate!(theirs.id, peer.id, peer_client)
      invitation = invitation!(theirs.id, user.id)
      peer_invitation = invitation!(theirs.id, peer.id)
      passkey = passkey!(user.id)
      own_confirmation = confirmation!(theirs.id, user.id)
      by_guest = confirmation!(own.id, peer.id, client: guest_client)
      peer_confirmation = confirmation!(theirs.id, peer.id, client: peer_client)

      assert {:ok, change} = SecurityTransitions.deny_user(server(), user.id, verify: admit())

      assert change.revoked_device_certificate_ids == Enum.sort([cert, guest_cert])
      assert change.revoked_pairing_invitation_ids == [invitation]
      assert change.revoked_passkey_ids == [passkey]
      assert change.voided_confirmation_ids == Enum.sort([own_confirmation, by_guest])

      for id <- [cert, guest_cert], do: assert(certificate_state(id) == "revoked")
      assert invitation_state(invitation) == "revoked"
      assert passkey_state(passkey) == "revoked"
      assert confirmation_state(own_confirmation) == "voided"
      assert confirmation_state(by_guest) == "voided"

      assert certificate_state(peer_cert) == "active"
      assert invitation_state(peer_invitation) == "pending"
      assert confirmation_state(peer_confirmation) == "confirmed"

      # An allow resurrects none of them.
      assert {:ok, _} = SecurityTransitions.allow_user(server(), user.id, verify: admit())
      assert invitation_state(invitation) == "revoked"
      assert passkey_state(passkey) == "revoked"
      assert certificate_state(cert) == "revoked"
    end

    test "an injected certificate UPDATE failure rolls a denial back with every credential standing" do
      {user, own} = owner!()
      session = session!(user.id, own.id)
      client = paired!(own.id, user.id)
      cert = certificate!(own.id, user.id, client)
      failure = fail_on!("device_certificates", "UPDATE")

      assert {:error, :database_error} =
               SecurityTransitions.deny_user(server(), user.id, verify: admit())

      assert user(user.id).status == "active"
      assert session?(session)
      assert paired_standing(client) == "active"
      assert certificate_state(cert) == "active"

      clear_failure!(failure)

      assert {:ok, %{revoked_device_certificate_ids: [^cert]}} =
               SecurityTransitions.deny_user(server(), user.id, verify: admit())
    end
  end

  describe "the standing columns" do
    test "ordinary updates refuse them as read-only" do
      user = person!()

      assert {:error, {:invalid, %{security_generation: ["is read-only"]}}} =
               Arca.Users.update(server(), user.id, %{security_generation: 9})

      assert {:error, {:invalid, %{status: ["is read-only"]}}} =
               Arca.Users.update(server(), user.id, %{status: "denied"})

      ath = athanor!()

      assert {:error, {:invalid, %{status: ["is read-only"]}}} =
               Arca.Athanors.set(Prima.Actor.in_athanor(ath.id), status: "archived")

      assert {:error, {:invalid, %{security_generation: ["is read-only"]}}} =
               Arca.Athanors.set(Prima.Actor.in_athanor(ath.id), security_generation: 9)

      assert user(user.id).security_generation == 1
      assert athanor(ath.id).security_generation == 1
    end
  end

  describe "shares" do
    # The owner's shares end with their standing: a denial revokes every
    # share of their own athanor and blocks the profiles that bind one, in
    # its own transaction.
    defp shared!(owner) do
      entry = Arca.Test.Shares.entry!(owner.actor)
      share = Arca.Test.Shares.share!(owner.actor, entry.id)
      alice = Arca.Test.Shares.owner!()
      {share, alice, Arca.Test.Shares.bound!(alice.athanor.id, share.id)}
    end

    defp share_status(owner, share),
      do: Arca.Test.Shares.share_status(owner.actor, share.id)

    test "a denial revokes every share of the person's own athanor and blocks its dependents" do
      terry = Arca.Test.Shares.owner!()
      {share, alice, profile} = shared!(terry)

      assert {:ok, change} =
               SecurityTransitions.deny_user(server(), terry.user.id, verify: admit())

      assert change.revoked_share_ids == [share.id]
      assert share_status(terry, share) == "revoked"
      assert Arca.Test.Shares.profile_status(alice.athanor.id, profile.id) == "needs_consent"

      # A repeated denial finds nothing more to revoke and still holds.
      assert {:ok, again} =
               SecurityTransitions.deny_user(server(), terry.user.id, verify: admit())

      assert again.revoked_share_ids == []
    end

    test "a share created after a denial is refused, and a denial's failure keeps its shares" do
      terry = Arca.Test.Shares.owner!()
      {share, _alice, _profile} = shared!(terry)

      assert {:error, :refused} =
               SecurityTransitions.deny_user(server(), terry.user.id,
                 verify: fn _ -> {:error, :refused} end
               )

      assert share_status(terry, share) == "active"

      {:ok, _} = SecurityTransitions.deny_user(server(), terry.user.id, verify: admit())
      entry = Arca.Test.Shares.entry!(terry.actor)

      assert {:error, :not_own_athanor} =
               Arca.Shares.create(terry.actor, %{entry_id: entry.id, audience: "everyone"})
    end
  end
end

defmodule Arca.SecurityTransitionsLockTest do
  @moduledoc """
  The transitions under two real connections, outside the sandbox: a
  transition waiting behind another acts on what that one committed — on
  PostgreSQL by waiting on the row, on SQLite by waiting at the lock its transaction takes at entry
  — and never on a read taken before the wait; a seat into an athanor a
  denial is archiving waits for it; and a denial whose membership set
  moves while it locks the athanors runs again on the set as it now
  stands.
  """

  use ExUnit.Case, async: false

  require Arca.Repo.Errors

  import Ecto.Query

  import Arca.SecurityTransitions.Fixtures,
    only: [server: 0, admit: 0, uniq: 0]

  alias Arca.Schemas.{
    ApiKey,
    Athanor,
    ExternalIdentity,
    Membership,
    Session,
    User
  }

  alias Arca.SecurityTransitions
  alias Ecto.Adapters.SQL.Sandbox

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    n = uniq()
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    own_id = Prima.UUID7.generate_id("ath")

    unboxed(fn ->
      {:ok, _} =
        Arca.Test.People.mint(
          server(),
          %{
            id: user_id,
            provider: "github",
            email: "stl#{n}@example.com",
            email_verified: true,
            personal_athanor_id: own_id,
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          %{
            key: "github|https://github.com|stl#{n}",
            provider: "github",
            issuer: "https://github.com",
            subject: "stl#{n}",
            first_seen_at: now,
            last_seen_at: now
          }
        )

      {:ok, _} =
        Arca.Athanors.insert(server(), %{
          id: own_id,
          name: "Own #{n}",
          slug: "stl-own-#{n}",
          owner_user_id: user_id,
          created_by: user_id
        })
    end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(Membership, user_id: ^user_id))
        Arca.Repo.delete_all(where(Session, user_id: ^user_id))
        Arca.Repo.delete_all(where(ApiKey, created_by: ^user_id))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(User, id: ^user_id))
      end)

      remove_athanors!([own_id])
    end)

    {:ok, user_id: user_id, own_id: own_id}
  end

  # The athanors a case minted, named by the case before it runs anything,
  # with every row that names them.
  defp remove_athanors!(ids) do
    unboxed(fn ->
      Arca.Repo.delete_all(from(m in Membership, where: m.athanor_id in ^ids))
      Arca.Repo.delete_all(from(k in ApiKey, where: k.athanor_id in ^ids))
      Arca.Repo.delete_all(from(a in Athanor, where: a.id in ^ids))
    end)
  end

  # Another person's athanor, its owner no row here.
  defp athanor! do
    n = uniq()

    {:ok, athanor} =
      unboxed(fn ->
        Arca.Athanors.insert(server(), %{
          name: "A#{n}",
          slug: "stl-a-#{n}",
          owner_user_id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          created_by: "system"
        })
      end)

    athanor.id
  end

  defp seat(athanor_id, user_id) do
    unboxed(fn ->
      Arca.Members.seat(Prima.Actor.in_athanor(athanor_id), %{user_id: user_id, added_by: "x"})
    end)
  end

  # A seat's row written past `Arca.Members.seat/2`, which takes the
  # person's lock first and so waits for a denial holding them: no writer
  # in the tree seats a person without that lock, and the denial's replan
  # is the guard should one ever appear, shown here on such a writer.
  defp seat_row(athanor_id, user_id) do
    now = DateTime.utc_now()

    %{
      id: Prima.UUID7.generate_id("mem"),
      user_id: user_id,
      scope: "athanor",
      status: "active",
      athanor_id: athanor_id,
      added_by: "x",
      created_at: now,
      updated_at: now
    }
  end

  # A transition that stops inside its own transaction — every lock taken,
  # nothing written — until the test says go.
  defp paused(transition, id) do
    test = self()

    Task.async(fn ->
      unboxed(fn ->
        apply(SecurityTransitions, transition, [
          server(),
          id,
          [
            verify: fn _rows ->
              send(test, {:holding, transition})

              receive do
                :go -> :ok
              end
            end
          ]
        ])
      end)
    end)
  end

  defp run(transition, id) do
    Task.async(fn ->
      unboxed(fn -> apply(SecurityTransitions, transition, [server(), id, [verify: admit()]]) end)
    end)
  end

  test "a denial waiting behind an allow acts on the allow's commit, not on its own read", %{
    user_id: user_id,
    own_id: own_id
  } do
    {:ok, _} =
      unboxed(fn -> SecurityTransitions.deny_user(server(), user_id, verify: admit()) end)

    allower = paused(:allow_user, user_id)
    assert_receive {:holding, :allow_user}, 5_000

    denier = run(:deny_user, user_id)
    refute Task.yield(denier, 300), "the denial decided while the allow held the person"

    send(allower.pid, :go)
    assert {:ok, %{transitioned: true, user_generation: 3}} = Task.await(allower, 25_000)

    # Had the denial acted on a read from before its wait, it would have
    # found the person already denied and moved nothing.
    assert {:ok, change} = Task.await(denier, 25_000)
    assert change.transitioned
    assert change.user_generation == 4
    assert change.archived_athanor_ids == [own_id]

    unboxed(fn ->
      assert Arca.Repo.get(User, user_id).status == "denied"
      assert Arca.Repo.get(Athanor, own_id).security_generation == 4
    end)
  end

  test "an allow waiting behind a denial acts on the denial's commit", %{
    user_id: user_id,
    own_id: own_id
  } do
    denier = paused(:deny_user, user_id)
    assert_receive {:holding, :deny_user}, 5_000

    allower = run(:allow_user, user_id)
    refute Task.yield(allower, 300), "the allow decided while the denial held the person"

    send(denier.pid, :go)
    assert {:ok, %{transitioned: true, user_generation: 2}} = Task.await(denier, 25_000)

    assert {:ok, change} = Task.await(allower, 25_000)
    assert change.transitioned
    assert change.user_generation == 3
    assert change.reopened_athanor_ids == [own_id]
  end

  # How long a killed client's transaction may hold its locks: the ceiling
  # the wait below stops at.
  @release_bound_ms 30_000

  test "a denial whose process dies before commit leaves everything it touched standing", %{
    user_id: user_id,
    own_id: own_id
  } do
    hash = :crypto.strong_rand_bytes(32)

    :ok =
      unboxed(fn ->
        Arca.SessionStorage.create_session(
          hash,
          %{
            user_id: user_id,
            provider: "github",
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          Arca.Test.Actor.issuance(user_id)
        )
      end)

    # Every lock taken and the policy asked, then the process is gone with
    # its transaction open.
    pid =
      spawn(fn ->
        unboxed(fn ->
          SecurityTransitions.deny_user(server(), user_id,
            verify: fn _rows -> Process.exit(self(), :kill) end
          )
        end)
      end)

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    killed_at = System.monotonic_time(:millisecond)

    # The dead transaction's locks go when its connection is closed. Wait
    # for that as an event — a write from a fresh connection that gets the
    # person's row — bounded, rather than for a guessed interval.
    released_ms = await_release!(user_id, killed_at, @release_bound_ms)
    assert released_ms <= @release_bound_ms

    unboxed(fn ->
      assert Arca.Repo.get(User, user_id).status == "active"
      assert Arca.Repo.get(User, user_id).security_generation == 1
      assert Arca.Repo.get(Athanor, own_id).status == "active"
      assert Arca.Repo.exists?(where(Session, token_hash: ^hash))
    end)

    # And the next denial is not blocked by what the dead one held.
    assert {:ok, %{revoked_session_hashes: [^hash]}} =
             unboxed(fn -> SecurityTransitions.deny_user(server(), user_id, verify: admit()) end)
  end

  # A write-then-rollback on the person's row from a fresh connection,
  # retried every 50 ms until it gets the row or the bound passes; answers
  # the milliseconds since `since`. On SQLite the probe waits at the lock its
  # transaction takes at entry (up to the busy timeout), on PostgreSQL on the row lock.
  defp await_release!(user_id, since, bound_ms) do
    probe =
      try do
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            Arca.Repo.update_all(where(User, id: ^user_id), set: [updated_at: DateTime.utc_now()])
            Arca.Repo.rollback(:probed)
          end)
        end)
      rescue
        _busy in Arca.Repo.Errors.db_errors() -> :held
      end

    elapsed = System.monotonic_time(:millisecond) - since

    cond do
      probe == {:error, :probed} ->
        elapsed

      elapsed > bound_ms ->
        flunk("a killed client's transaction still held the person after #{elapsed} ms")

      true ->
        Process.sleep(50)
        await_release!(user_id, since, bound_ms)
    end
  end

  # PostgreSQL alone: on SQLite the denial's immediate transaction admits
  # no seat between its plan and its locks, so there is no moved set to find.
  @tag :postgres
  test "a membership taken while a denial locks the athanors is on the set it runs again on", %{
    user_id: user_id
  } do
    other_id = athanor!()
    on_exit(fn -> remove_athanors!([other_id]) end)
    test = self()

    # Hold the person's own athanor: the denial plans without the other
    # athanor, then waits on this row while the seat there is written.
    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            [_] =
              from(a in Athanor,
                where: a.id == ^Arca.Repo.get(User, user_id).personal_athanor_id
              )
              |> Arca.QueryHelpers.for_update()
              |> Arca.Repo.all()

            send(test, :holding)

            receive do
              :seat -> :ok
            end

            {1, _} = Arca.Repo.insert_all(Membership, [seat_row(other_id, user_id)])
          end)
        end)
      end)

    assert_receive :holding, 5_000

    denier =
      Task.async(fn ->
        unboxed(fn ->
          SecurityTransitions.deny_user(server(), user_id,
            verify: fn %{athanors: athanors} ->
              send(test, {:asked, Enum.map(athanors, & &1.id)})
              :ok
            end
          )
        end)
      end)

    refute Task.yield(denier, 300)
    send(holder.pid, :seat)
    Task.await(holder, 25_000)

    # The policy was shown the set as it stands after the seat, and the
    # denial removed that seat with the rest.
    assert {:ok, change} = Task.await(denier, 25_000)
    assert_received {:asked, asked}
    assert other_id in asked
    refute_received {:asked, _}
    assert other_id in Enum.map(change.removed_memberships, & &1.athanor_id)
    unboxed(fn -> assert Arca.Repo.all(where(Membership, user_id: ^user_id)) == [] end)
  end

  # PostgreSQL alone: on SQLite no second connection can seat the person
  # while the denial holds the database, so the set cannot move.
  @tag :postgres
  test "a set that moves on every attempt ends in a conflict, and nothing is written", %{
    user_id: user_id,
    own_id: own_id
  } do
    others = for _ <- 1..3, do: athanor!()
    on_exit(fn -> remove_athanors!(others) end)
    {:ok, _} = seat(own_id, user_id)
    {:ok, agent} = Agent.start_link(fn -> others end)

    # Every time the policy is asked, a second connection seats the
    # person in one more athanor, past the person's lock (`seat_row/2`):
    # the set the denial planned has moved by the time it would write.
    verify = fn _rows ->
      next = Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)

      {1, _} =
        Task.await(
          Task.async(fn ->
            unboxed(fn -> Arca.Repo.insert_all(Membership, [seat_row(next, user_id)]) end)
          end),
          25_000
        )

      :ok
    end

    assert {:error, :conflict} =
             unboxed(fn ->
               SecurityTransitions.deny_user(server(), user_id, verify: verify)
             end)

    assert Agent.get(agent, & &1) == []

    unboxed(fn ->
      user = Arca.Repo.get(User, user_id)
      assert user.status == "active"
      assert user.security_generation == 1
      assert Arca.Repo.get(Athanor, own_id).status == "active"

      for id <- others do
        assert Arca.Repo.get(Athanor, id).status == "active"
        assert Arca.Repo.get(Athanor, id).security_generation == 1
      end

      # The seats the second connection wrote stand; the denial wrote nothing.
      assert length(Arca.Repo.all(where(Membership, user_id: ^user_id))) == 4
    end)
  end

  test "a seat into an athanor a denial is archiving waits for it and is refused", %{
    user_id: user_id,
    own_id: own_id
  } do
    other = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    on_exit(fn -> unboxed(fn -> Arca.Repo.delete_all(where(Membership, user_id: ^other)) end) end)

    # The denial archives the person's own athanor; it holds the athanor
    # while its policy is asked.
    denier = paused(:deny_user, user_id)
    assert_receive {:holding, :deny_user}, 5_000

    seater = Task.async(fn -> seat(own_id, other) end)
    refute Task.yield(seater, 300), "the seat was written while the denial held the athanor"

    send(denier.pid, :go)
    assert {:ok, change} = Task.await(denier, 25_000)
    assert own_id in change.archived_athanor_ids

    assert {:error, :athanor_archived} = Task.await(seater, 25_000)

    unboxed(fn ->
      refute Arca.Repo.exists?(where(Membership, user_id: ^other))
      assert Arca.Repo.get(Athanor, own_id).status == "archived"
    end)
  end
end
