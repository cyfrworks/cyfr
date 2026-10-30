# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SecurityTransitionsRestoreTest do
  @moduledoc """
  The declared restore (`Arca.SecurityTransitions.restore/1`): the marker
  `cyfr restore` writes is consumed in one transaction that moves every
  row a restored home's authority stands on, and nothing else.

  The fixture holds, for each store the transition moves, an active row,
  a row already blocked and a revoked or terminal row, and a tombstoned
  row where the store has one: the active row moves, the blocked one stays
  blocked, the terminal ones stay as they were. A run open at the backup
  ends terminal, and no successor takes it up even after its profile is
  re-consented and the boot runs again, because every standing was raised
  (`Arca.ExecutionAttempts.takeover/3` under the standing check). A crash
  before the commit, a lost slot or a postcondition that does not hold
  leaves the store and the marker as they were, and the next boot applies
  the transition once. Each person's `restore_people` row closes on its
  own; a group with a member still recovering admits no new member; the
  kit's challenge is redeemed once, before its expiry, for its own
  person, while that person's row is open.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.SecurityTransitions
  alias Arca.Schemas

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp server, do: Prima.Actor.system()
  defp uniq, do: System.unique_integer([:positive])
  defp now, do: DateTime.utc_now()

  # ---------------------------------------------------------------------------
  # The fixture
  # ---------------------------------------------------------------------------

  defp person! do
    n = uniq()

    {:ok, user} =
      Arca.Test.People.mint(
        server(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          provider: "github",
          email: "rs#{n}@example.com",
          email_verified: true,
          first_seen_at: now(),
          last_seen_at: now(),
          created_at: now(),
          updated_at: now()
        },
        %{
          key: "github|https://github.com|rs#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "rs#{n}",
          first_seen_at: now(),
          last_seen_at: now()
        }
      )

    user
  end

  defp athanor!(kind, owner) do
    n = uniq()

    {:ok, athanor} =
      Arca.Athanors.insert(server(), %{
        kind: kind,
        name: "R#{n}",
        slug: "rs-#{n}",
        owner_user_id: if(kind == "person", do: owner),
        created_by: owner
      })

    athanor
  end

  defp seat!(athanor_id, user_id) do
    {:ok, row} =
      Arca.Members.seat(Prima.Actor.in_athanor(athanor_id), %{user_id: user_id, added_by: "x"})

    row
  end

  defp insert!(schema, row) do
    {1, _} = Arca.Repo.insert_all(schema, [row])
    row
  end

  defp session!(user_id) do
    hash = :crypto.strong_rand_bytes(32)

    insert!(Schemas.Session, %{
      id: Prima.UUID7.generate_id("ses"),
      token_hash: hash,
      user_id: user_id,
      provider: "github",
      expires_at: DateTime.add(now(), 3600, :second),
      inserted_at: now()
    })

    hash
  end

  defp key!(athanor_id, user_id, attrs \\ %{}) do
    id = Prima.UUID7.generate_id("key")

    insert!(
      Schemas.ApiKey,
      Map.merge(
        %{
          id: id,
          name: "k#{uniq()}",
          key_hash: :crypto.strong_rand_bytes(32),
          key_prefix: "cyfr_sk_rs",
          type: "service",
          scope: "[]",
          revoked: false,
          suspended: false,
          created_by: user_id,
          athanor_id: athanor_id,
          inserted_at: now(),
          updated_at: now()
        },
        attrs
      )
    )

    id
  end

  defp profile!(athanor_id, status) do
    id = Prima.UUID7.generate_id("prf")

    insert!(Schemas.Profile, %{
      id: id,
      athanor_id: athanor_id,
      source_ref: "local:acme/tool-#{uniq()}",
      kind: "owner",
      label: "default",
      status: status,
      inserted_at: now(),
      updated_at: now()
    })

    id
  end

  defp webhook!(athanor_id, user_id, profile_id, suspended \\ false) do
    id = Prima.UUID7.generate_id("whk")

    insert!(Schemas.Webhook, %{
      id: id,
      name: "w#{uniq()}",
      slug: "slug-#{uniq()}",
      target_ref: "local:acme/tool",
      secret_encrypted: "sealed",
      athanor_id: athanor_id,
      profile_id: profile_id,
      created_by: user_id,
      suspended: suspended,
      inserted_at: now(),
      updated_at: now()
    })

    id
  end

  defp paired!(athanor_id, user_id, standing) do
    id = Prima.UUID7.generate_id("pcl")

    insert!(Schemas.PairedClient, %{
      id: id,
      athanor_id: athanor_id,
      user_id: user_id,
      source_kind: "session",
      source_id: "src_#{uniq()}",
      standing: standing,
      inserted_at: now(),
      updated_at: now()
    })

    id
  end

  defp passkey!(user_id, state) do
    id = Prima.UUID7.generate_id("psk")

    insert!(Schemas.Passkey, %{
      id: id,
      user_id: user_id,
      credential_id: "cred-#{uniq()}",
      rp_id: "home.example",
      relying_home: "https://home.example",
      public_key: "cose",
      sign_count: 0,
      state: state,
      registration_digest: Prima.Digest.sha256("reg-#{uniq()}"),
      possession_verified: true,
      inserted_at: now(),
      updated_at: now()
    })

    id
  end

  defp confirmation!(athanor_id, user_id) do
    ref = Prima.Confirmation.ref("cnf_#{uniq()}")

    insert!(Schemas.PendingConfirmation, %{
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
      opener: "session:restore-test",
      asker: ~s({"kind":"session"}),
      state: "pending",
      email_code_failures: 0,
      opened_at: now(),
      expires_at: DateTime.add(now(), 300, :second),
      inserted_at: now(),
      updated_at: now()
    })

    ref
  end

  defp grant!(athanor_id, effect) do
    id = Prima.UUID7.generate_id("tgr")

    insert!(Schemas.ToolGrant, %{
      id: id,
      athanor_id: athanor_id,
      scope: "agent",
      effect: effect,
      agent_name: "assistant",
      tool: "files",
      action: "read#{uniq()}",
      granted_at: now(),
      sources: "[]"
    })

    id
  end

  defp destination,
    do: ~s({"hosts":["api.example.com"],"scheme":"https"})

  defp vault!(athanor_id, status) do
    id = Prima.UUID7.generate_id("vlt")

    insert!(Schemas.VaultEntry, %{
      id: id,
      athanor_id: athanor_id,
      name: "v#{uniq()}",
      kind: "api_key",
      destination: destination(),
      status: status,
      inserted_at: now(),
      updated_at: now()
    })

    id
  end

  defp share!(athanor_id, vault_id, status \\ "active") do
    id = Prima.UUID7.generate_id("shr")

    insert!(Schemas.Share, %{
      id: id,
      athanor_id: athanor_id,
      vault_entry_id: vault_id,
      audience: "everyone",
      status: status,
      created_by: "usr_owner",
      inserted_at: now(),
      updated_at: now()
    })

    id
  end

  defp instance!(status) do
    id = Prima.UUID7.generate_id("ine")

    insert!(Schemas.InstanceEntry, %{
      id: id,
      name: "i#{uniq()}",
      kind: "api_key",
      destination: destination(),
      audience: "everyone",
      created_by: "usr_admin",
      status: status,
      inserted_at: now(),
      updated_at: now()
    })

    id
  end

  defp consent!(athanor_id, profile_id) do
    id = Prima.UUID7.generate_id("cns")

    insert!(Schemas.Consent, %{
      id: id,
      athanor_id: athanor_id,
      profile_id: profile_id,
      revision: 1,
      scope: "component",
      shape_digest: "sha256:shape",
      commit_digest: "sha256:commit-#{uniq()}",
      resolved_policy: "{}",
      blob_digest: "sha256:blob",
      activation: "{}",
      granted_by: "usr_x",
      granted_via: "console",
      granted_at: now(),
      admitted_origins: ~s(["interactive"])
    })

    id
  end

  defp binding!(consent_id, athanor_id, vault_id, lifetime, consumed \\ nil) do
    key = "node|edge#{uniq()}|slot"

    insert!(Schemas.ConsentVaultRef, %{
      consent_id: consent_id,
      athanor_id: athanor_id,
      binding_key: key,
      scope: "athanor",
      vault_entry_id: vault_id,
      binding_digest: "sha256:binding",
      lifetime_kind: lifetime,
      consumed_by_root: consumed
    })

    key
  end

  defp binding_root(consent_id, key),
    do:
      Arca.Repo.one(
        from(r in Schemas.ConsentVaultRef,
          where: r.consent_id == ^consent_id and r.binding_key == ^key,
          select: r.consumed_by_root
        )
      )

  defp thread!(athanor_id, user_id) do
    id = Prima.UUID7.generate_id("thr")

    insert!(Schemas.Thread, %{
      id: id,
      athanor_id: athanor_id,
      created_by: user_id,
      inserted_at: now(),
      updated_at: now()
    })

    id
  end

  defp turn!(athanor_id, thread_id, status) do
    id = Prima.UUID7.generate_id("trn")

    insert!(Schemas.Turn, %{
      id: id,
      athanor_id: athanor_id,
      thread_id: thread_id,
      status: status,
      accepted_at: now(),
      origin: "interactive",
      fence: 1,
      sources: "[]"
    })

    id
  end

  defp step!(athanor_id, turn_id, state) do
    id = Prima.UUID7.generate_id("stp")

    insert!(Schemas.TurnStep, %{
      id: id,
      athanor_id: athanor_id,
      turn_id: turn_id,
      seq: uniq(),
      kind: "tool",
      purpose: "chat",
      dispatch_state: state
    })

    id
  end

  defp approval!(athanor_id, turn_id, status) do
    id = Prima.UUID7.generate_id("apr")

    insert!(Schemas.Approval, %{
      id: id,
      athanor_id: athanor_id,
      turn_id: turn_id,
      status: status,
      proposal_digest: "sha256:proposal",
      inserted_at: now()
    })

    id
  end

  # An execution with its current attempt, admitted under the athanor's
  # standing as it reads now.
  defp run!(athanor_id, user_id, status, attempt_state) do
    execution = Prima.UUID7.generate_id("exe")
    attempt = Prima.UUID7.generate_id("att")
    generation = Arca.Repo.get(Schemas.Athanor, athanor_id).security_generation

    insert!(Schemas.Execution, %{
      id: execution,
      reference: "local:acme/tool",
      user_id: user_id,
      athanor_id: athanor_id,
      status: status,
      started_at: now(),
      root_execution_id: execution,
      current_attempt: attempt
    })

    insert!(Schemas.ExecutionAttempt, %{
      attempt: attempt,
      athanor_id: athanor_id,
      athanor_generation: generation,
      execution_id: execution,
      fence: 1,
      boot_id: "boot-old",
      lease_until: DateTime.add(now(), 60, :second),
      state: attempt_state,
      started_at: now(),
      running_since: if(attempt_state == "running", do: now())
    })

    {execution, attempt}
  end

  defp intent!(athanor_id, execution, attempt) do
    id = Prima.UUID7.generate_id("swi")

    insert!(Schemas.StorageWriteIntent, %{
      id: id,
      athanor_id: athanor_id,
      execution_id: execution,
      attempt: attempt,
      fence: 1,
      runner: "runner",
      op: "write",
      path: "data/a.txt",
      state: "pending",
      inserted_at: now()
    })

    id
  end

  # An invitation to become a person here, issued by `issuer` at the
  # standing their row holds now, ended or not as `ending` says.
  defp admission_invitation!(issuer, ending \\ %{}) do
    id = Prima.UUID7.generate_id("inv")

    insert!(
      Schemas.Invitation,
      Map.merge(
        %{
          id: id,
          code_hash: Prima.Digest.sha256_hex(:crypto.strong_rand_bytes(32)),
          issued_by: issuer.id,
          issuer_generation: issuer.security_generation,
          expires_at: DateTime.add(now(), 3600, :second),
          inserted_at: now(),
          updated_at: now()
        },
        ending
      )
    )

    id
  end

  defp get(schema, id), do: Arca.Repo.get(schema, id)

  defp invited(athanor_id, invitee) do
    Map.merge(
      %{
        id: Prima.UUID7.generate_id("mem"),
        athanor_id: athanor_id,
        scope: "athanor",
        status: "invited",
        added_by: "x",
        created_at: now(),
        updated_at: now()
      },
      invitee
    )
  end

  # A home as a backup holds it: two people, each with their own athanor
  # and a group they share, and in every store the transition moves an
  # active, a blocked and a terminal row.
  defp home! do
    alice = person!()
    bob = person!()
    # Carol signs in only through a door: no method for a restore to suspend.
    carol = person!()
    own = athanor!("person", alice.id)
    seat!(own.id, alice.id)
    group = athanor!("group", alice.id)
    seat!(group.id, alice.id)
    seat!(group.id, bob.id)

    profile = profile!(own.id, "active")
    consent = consent!(own.id, profile)
    vault = vault!(own.id, "active")
    thread = thread!(own.id, alice.id)
    open_turn = turn!(own.id, thread, "running")
    {open_execution, open_attempt} = run!(own.id, alice.id, "running", "running")
    {paused_execution, paused_attempt} = run!(group.id, bob.id, "paused", "paused")
    {done_execution, done_attempt} = run!(own.id, alice.id, "completed", "completed")

    %{
      alice: alice,
      bob: bob,
      carol: carol,
      bob_passkey: passkey!(bob.id, "active"),
      own: own,
      group: group,
      sessions: [session!(alice.id), session!(bob.id), session!(carol.id)],
      key: key!(own.id, alice.id),
      revoked_key: key!(own.id, alice.id, %{revoked: true}),
      webhook: webhook!(own.id, alice.id, profile),
      paired: paired!(own.id, alice.id, "active"),
      revoked_paired: paired!(own.id, alice.id, "revoked"),
      passkey: passkey!(alice.id, "active"),
      pending_passkey: passkey!(alice.id, "pending"),
      revoked_passkey: passkey!(alice.id, "revoked"),
      confirmation: confirmation!(own.id, alice.id),
      invitation: admission_invitation!(alice),
      expired_invitation:
        admission_invitation!(alice, %{expires_at: DateTime.add(now(), -60, :second)}),
      redeemed_invitation:
        admission_invitation!(alice, %{redeemed_by: bob.id, redeemed_at: now()}),
      revoked_invitation: admission_invitation!(alice, %{revoked_at: now()}),
      profile: profile,
      blocked_profile: profile!(own.id, "needs_consent"),
      revoked_profile: profile!(own.id, "revoked"),
      allow: grant!(own.id, "allow"),
      deny: grant!(own.id, "deny"),
      consent: consent,
      once: binding!(consent, own.id, vault, "once"),
      used_once: binding!(consent, own.id, vault, "once", "exe_earlier"),
      standing_binding: binding!(consent, own.id, vault, "standing"),
      vault: vault,
      blocked_vault: vault!(own.id, "needs_reauth"),
      revoked_vault: vault!(own.id, "revoked"),
      tombstoned_vault: vault!(own.id, "tombstoned"),
      instance: instance!("active"),
      blocked_instance: instance!("needs_reauth"),
      revoked_instance: instance!("revoked"),
      tombstoned_instance: instance!("tombstoned"),
      share: share!(own.id, vault),
      revoked_share: share!(own.id, vault, "revoked"),
      open_turn: open_turn,
      paused_turn: turn!(group.id, thread!(group.id, bob.id), "paused"),
      done_turn: turn!(own.id, thread, "completed"),
      open_step: step!(own.id, open_turn, "dispatched"),
      closed_step: step!(own.id, open_turn, "closed"),
      approval: approval!(own.id, open_turn, "pending"),
      decided_approval: approval!(own.id, open_turn, "approved"),
      open_execution: open_execution,
      open_attempt: open_attempt,
      intent: intent!(own.id, open_execution, open_attempt),
      paused_execution: paused_execution,
      paused_attempt: paused_attempt,
      done_execution: done_execution,
      done_attempt: done_attempt
    }
  end

  defp marked! do
    {:ok, restore_id} = SecurityTransitions.mark_restore(server())
    restore_id
  end

  defp marker,
    do: Arca.Repo.one(from(m in Schemas.ServerMeta, where: m.key == "restore_pending"))

  defp rows(user_id),
    do:
      Arca.Repo.all(
        from(r in Schemas.RestorePerson, where: r.user_id == ^user_id, order_by: r.restore_id)
      )

  # The standing check a successor's takeover runs under, as the identity
  # domain asks it (`Sanctum.ExecutionStanding`): the athanor active at
  # the generation the grant names.
  defp standing(actor) do
    fn %Prima.ExecutionGrant{athanor_id: athanor_id, generation: generation} ->
      case Arca.ExecutionStanding.locked(actor, athanor_id) do
        {:ok, %{status: "active", security_generation: ^generation}} -> :ok
        {:ok, _other} -> {:error, :not_standing}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp takeover(athanor_id, execution) do
    actor = Prima.Actor.in_athanor(athanor_id)

    Arca.ExecutionAttempts.takeover(actor, execution,
      grant: :stored,
      verify: standing(actor),
      boot_id: "boot-new",
      lease_until: DateTime.add(now(), 60, :second)
    )
  end

  # ---------------------------------------------------------------------------
  # The marker
  # ---------------------------------------------------------------------------

  describe "the marker" do
    test "is written once, and a second mark declares the same restore" do
      restore_id = marked!()
      assert %{value: ^restore_id} = marker()
      assert {:ok, ^restore_id} = SecurityTransitions.mark_restore(server())
    end

    test "only the system marks a restore" do
      assert {:error, :cross_tenant} =
               SecurityTransitions.mark_restore(Prima.Actor.in_athanor("ath_x"))

      assert is_nil(marker())
    end

    test "with no marker the transition moves nothing" do
      fixture = home!()
      assert {:ok, :none} = SecurityTransitions.restore(slot: :none)
      assert Arca.Repo.exists?(where(Schemas.Session, token_hash: ^hd(fixture.sessions)))
      assert get(Schemas.ApiKey, fixture.key).suspended == false
      assert rows(fixture.alice.id) == []
    end
  end

  # ---------------------------------------------------------------------------
  # The transition
  # ---------------------------------------------------------------------------

  describe "a marked restore" do
    test "moves every active row, keeps blocked rows blocked and terminal rows as they were" do
      fixture = home!()
      alice_generation = fixture.alice.security_generation
      own_generation = get(Schemas.Athanor, fixture.own.id).security_generation
      revoked_at = get(Schemas.Invitation, fixture.revoked_invitation).revoked_at
      restore_id = marked!()

      assert {:ok, change} = SecurityTransitions.restore(slot: :none)
      assert change.restore_id == restore_id

      # Every standing is raised.
      assert get(Schemas.User, fixture.alice.id).security_generation == alice_generation + 1
      assert get(Schemas.Athanor, fixture.own.id).security_generation == own_generation + 1

      # Sessions are retired.
      for hash <- fixture.sessions,
          do: refute(Arca.Repo.exists?(where(Schemas.Session, token_hash: ^hash)))

      # Keys, webhooks, devices and passkeys are suspended; revoked and
      # pending rows keep their state.
      assert %{suspended: true, revoked: false} = get(Schemas.ApiKey, fixture.key)
      assert %{suspended: false, revoked: true} = get(Schemas.ApiKey, fixture.revoked_key)
      assert get(Schemas.Webhook, fixture.webhook).suspended == true
      assert get(Schemas.PairedClient, fixture.paired).standing == "suspended"
      assert get(Schemas.PairedClient, fixture.revoked_paired).standing == "revoked"
      assert get(Schemas.Passkey, fixture.passkey).state == "suspended"
      assert get(Schemas.Passkey, fixture.pending_passkey).state == "pending"
      assert get(Schemas.Passkey, fixture.revoked_passkey).state == "revoked"
      assert change.suspended_api_key_ids == [fixture.key]
      assert change.suspended_passkey_ids == Enum.sort([fixture.passkey, fixture.bob_passkey])

      # Pending confirmations are deleted.
      refute get(Schemas.PendingConfirmation, fixture.confirmation)
      assert change.deleted_confirmation_refs == [fixture.confirmation]

      # Open invitations to become a person are revoked, expired or not; a
      # redeemed one stays redeemed, a revoked one keeps its revocation.
      for id <- [fixture.invitation, fixture.expired_invitation] do
        assert %{revoked_at: %DateTime{}, redeemed_at: nil} = get(Schemas.Invitation, id)
      end

      assert %{revoked_at: nil, redeemed_at: %DateTime{}} =
               get(Schemas.Invitation, fixture.redeemed_invitation)

      assert get(Schemas.Invitation, fixture.revoked_invitation).revoked_at == revoked_at

      assert change.revoked_admission_invitation_ids ==
               Enum.sort([fixture.invitation, fixture.expired_invitation])

      # Profiles need consent; a blocked one stays blocked, a revoked one revoked.
      assert get(Schemas.Profile, fixture.profile).status == "needs_consent"
      assert get(Schemas.Profile, fixture.blocked_profile).status == "needs_consent"
      assert get(Schemas.Profile, fixture.revoked_profile).status == "revoked"
      assert change.needs_consent_profile_ids == [fixture.profile]

      # Standing allows go, denies stay.
      refute get(Schemas.ToolGrant, fixture.allow)
      assert get(Schemas.ToolGrant, fixture.deny)

      # An unconsumed once binding is consumed under the restore; a consumed
      # one keeps its root, and a standing binding is untouched.
      assert binding_root(fixture.consent, fixture.once) == "restore:" <> restore_id
      assert binding_root(fixture.consent, fixture.used_once) == "exe_earlier"
      assert binding_root(fixture.consent, fixture.standing_binding) == nil

      # Entries need re-authentication; blocked stays, terminal stays.
      assert get(Schemas.VaultEntry, fixture.vault).status == "needs_reauth"
      assert get(Schemas.VaultEntry, fixture.blocked_vault).status == "needs_reauth"
      assert get(Schemas.VaultEntry, fixture.revoked_vault).status == "revoked"
      assert get(Schemas.VaultEntry, fixture.tombstoned_vault).status == "tombstoned"
      assert get(Schemas.InstanceEntry, fixture.instance).status == "needs_reauth"
      assert get(Schemas.InstanceEntry, fixture.blocked_instance).status == "needs_reauth"
      assert get(Schemas.InstanceEntry, fixture.revoked_instance).status == "revoked"
      assert get(Schemas.InstanceEntry, fixture.tombstoned_instance).status == "tombstoned"

      # Every active share is revoked, and nothing comes back on its own;
      # a revoked one stays the row it was.
      assert get(Schemas.Share, fixture.share).status == "revoked"
      assert get(Schemas.Share, fixture.revoked_share).status == "revoked"
      assert change.revoked_share_ids == [fixture.share]

      # Open runs end terminal; a finished one is untouched.
      assert get(Schemas.Execution, fixture.open_execution).status == "failed"
      assert get(Schemas.Execution, fixture.paused_execution).status == "failed"
      assert get(Schemas.Execution, fixture.done_execution).status == "completed"

      assert %{state: "lapsed", outcome: "uncertain"} =
               get(Schemas.ExecutionAttempt, fixture.open_attempt)

      assert %{state: "lapsed", outcome: "uncertain"} =
               get(Schemas.ExecutionAttempt, fixture.paused_attempt)

      assert get(Schemas.ExecutionAttempt, fixture.done_attempt).state == "completed"

      assert %{state: "uncertain", reason: "restored"} =
               get(Schemas.StorageWriteIntent, fixture.intent)

      assert get(Schemas.Turn, fixture.open_turn).status == "uncertain"
      assert get(Schemas.Turn, fixture.paused_turn).status == "uncertain"
      assert get(Schemas.Turn, fixture.done_turn).status == "completed"
      assert get(Schemas.TurnStep, fixture.open_step).dispatch_state == "uncertain"
      assert get(Schemas.TurnStep, fixture.closed_step).dispatch_state == "closed"
      assert get(Schemas.Approval, fixture.approval).status == "expired"
      assert get(Schemas.Approval, fixture.decided_approval).status == "approved"

      # One open row for each person whose passkey or device the restore
      # suspended; a door-only person has nothing to recover and no row.
      for person <- [fixture.alice, fixture.bob] do
        assert [%{restore_id: ^restore_id, open: true, closed_at: nil}] = rows(person.id)
      end

      assert change.user_ids == Enum.sort([fixture.alice.id, fixture.bob.id])
      assert rows(fixture.carol.id) == []

      assert is_nil(marker())
    end

    test "a second restore supersedes the first: its rows close, its kit goes, and whoever " <>
           "still holds a suspended method recovers again" do
      fixture = home!()
      first = marked!()
      assert {:ok, %{restore_id: ^first}} = SecurityTransitions.restore(slot: :none)

      # Alice proved her kit under the first restore and left a challenge.
      later = DateTime.add(Arca.ServerMetaStorage.now!(), 60_000, :millisecond)
      challenge = Prima.Digest.sha256("first-challenge")
      credential = Prima.Digest.sha256("first-credential")

      :ok =
        SecurityTransitions.put_kit_challenge(server(), fixture.alice.id, first, challenge, later)

      :ok =
        SecurityTransitions.put_kit_challenge(
          server(),
          fixture.alice.id,
          first,
          Prima.Digest.sha256("unused"),
          later
        )

      :ok =
        SecurityTransitions.redeem_kit_challenge(
          server(),
          fixture.alice.id,
          first,
          challenge,
          credential,
          later
        )

      second = marked!()

      assert {:ok, %{restore_id: ^second, superseded_restore_ids: [^first]}} =
               SecurityTransitions.restore(slot: :none)

      # Her methods are still suspended: she recovers under the second.
      assert [%{restore_id: ^first, open: false}, %{restore_id: ^second, open: true}] =
               rows(fixture.alice.id)

      assert {:error, :not_standing} =
               SecurityTransitions.kit_credential(server(), fixture.alice.id, credential)

      assert {:error, :not_standing} = SecurityTransitions.kit_holder(server(), credential)

      refute Arca.Repo.exists?(from(m in Schemas.ServerMeta, where: like(m.key, "restore_kit%")))
    end

    test "is applied once: a boot after it finds no marker and moves nothing again" do
      fixture = home!()
      restore_id = marked!()
      assert {:ok, %{restore_id: ^restore_id}} = SecurityTransitions.restore(slot: :none)

      # The person re-enabled their key since; a second boot leaves it.
      Arca.Repo.update_all(where(Schemas.ApiKey, id: ^fixture.key), set: [suspended: false])
      generation = get(Schemas.User, fixture.alice.id).security_generation

      assert {:ok, :none} = SecurityTransitions.restore(slot: :none)
      assert get(Schemas.ApiKey, fixture.key).suspended == false
      assert get(Schemas.User, fixture.alice.id).security_generation == generation
      assert [%{restore_id: ^restore_id}] = rows(fixture.alice.id)
    end

    test "no open run resumes, even after its profile is re-consented and the home boots again" do
      fixture = home!()

      # Before the restore, a successor would take the open run up.
      marked!()
      assert {:ok, _change} = SecurityTransitions.restore(slot: :none)

      # The profile is re-consented, and the home boots again.
      Arca.Repo.update_all(where(Schemas.Profile, id: ^fixture.profile), set: [status: "active"])
      assert {:ok, :none} = SecurityTransitions.restore(slot: :none)

      # The lapsed rows are the one failure a successor may take up, and
      # the stamp each carries no longer stands.
      assert {:error, :not_standing} = takeover(fixture.own.id, fixture.open_execution)
      assert {:error, :not_standing} = takeover(fixture.group.id, fixture.paused_execution)
      assert get(Schemas.Execution, fixture.open_execution).status == "failed"

      # No pre-restore attempt is left open for the sweep's scan to cancel.
      assert {:ok, []} = Arca.ExecutionStanding.retired_attempts(server(), nil, 100)
    end

    test "a run admitted after the restore is taken up like any other" do
      fixture = home!()
      marked!()
      assert {:ok, _change} = SecurityTransitions.restore(slot: :none)

      {execution, _attempt} = run!(fixture.own.id, fixture.alice.id, "running", "running")
      assert {:ok, %{attempt: %{state: "running"}}} = takeover(fixture.own.id, execution)
    end
  end

  # ---------------------------------------------------------------------------
  # Failure: nothing half-applied
  # ---------------------------------------------------------------------------

  describe "a failed transition" do
    test "a statement that fails rolls everything back, and the next boot applies it once" do
      fixture = home!()
      restore_id = marked!()
      trigger = fail_on!("passkeys", "UPDATE")

      assert {:error, :database_error} = SecurityTransitions.restore(slot: :none)

      # Nothing moved, and the marker stays for the next boot.
      assert Arca.Repo.exists?(where(Schemas.Session, token_hash: ^hd(fixture.sessions)))
      assert get(Schemas.ApiKey, fixture.key).suspended == false
      assert get(Schemas.Profile, fixture.profile).status == "active"
      assert get(Schemas.Execution, fixture.open_execution).status == "running"
      assert get(Schemas.Invitation, fixture.invitation).revoked_at == nil
      assert rows(fixture.alice.id) == []
      assert %{value: ^restore_id} = marker()

      clear_failure!(trigger)
      assert {:ok, %{restore_id: ^restore_id}} = SecurityTransitions.restore(slot: :none)
      assert {:ok, :none} = SecurityTransitions.restore(slot: :none)
      assert [%{restore_id: ^restore_id, open: true}] = rows(fixture.alice.id)
      assert get(Schemas.Passkey, fixture.passkey).state == "suspended"
    end

    test "a row a statement leaves standing fails the postcondition and rolls back" do
      fixture = home!()
      marked!()
      trigger = skip_on!("api_keys", "UPDATE")

      try do
        assert {:error, :postcondition_failed} = SecurityTransitions.restore(slot: :none)
        assert get(Schemas.Passkey, fixture.passkey).state == "active"
        assert rows(fixture.alice.id) == []
        assert marker()
      after
        clear_failure!(trigger)
      end
    end

    test "a share a statement leaves active fails the postcondition and rolls back" do
      fixture = home!()
      marked!()
      trigger = skip_on!("shares", "UPDATE")

      try do
        assert {:error, :postcondition_failed} = SecurityTransitions.restore(slot: :none)
        assert get(Schemas.Share, fixture.share).status == "active"
        assert get(Schemas.VaultEntry, fixture.vault).status == "active"
        assert marker()
      after
        clear_failure!(trigger)
      end
    end

    test "an open invitation a statement leaves standing fails the postcondition and rolls back" do
      fixture = home!()
      marked!()
      trigger = skip_on!("invitations", "UPDATE")

      try do
        assert {:error, :postcondition_failed} = SecurityTransitions.restore(slot: :none)
        assert get(Schemas.Invitation, fixture.invitation).revoked_at == nil
        assert get(Schemas.Passkey, fixture.passkey).state == "active"
        assert marker()
      after
        clear_failure!(trigger)
      end
    end

    test "a slot this member no longer holds refuses it with nothing written" do
      fixture = home!()
      marked!()
      lost = %{node: "node-gone", owner: "boot-gone", generation: 1, fence: 1}

      assert {:error, :slot_lost} = SecurityTransitions.restore(slot: lost)
      assert get(Schemas.ApiKey, fixture.key).suspended == false
      assert marker()
    end
  end

  # ---------------------------------------------------------------------------
  # Each person's recovery
  # ---------------------------------------------------------------------------

  describe "restore_people" do
    setup do
      fixture = home!()
      restore_id = marked!()
      {:ok, _change} = SecurityTransitions.restore(slot: :none)
      %{fixture: fixture, restore_id: restore_id}
    end

    test "one person's close leaves another's open", %{fixture: f, restore_id: restore_id} do
      assert {:ok, ^restore_id} = SecurityTransitions.restore_open(server(), f.alice.id)
      assert {:ok, ^restore_id} = SecurityTransitions.restore_open(server(), f.bob.id)

      {:ok, closed} =
        Arca.Repo.locking_transaction(fn -> SecurityTransitions.close_restore!(f.alice.id) end)

      assert closed == [restore_id]
      assert {:ok, nil} = SecurityTransitions.restore_open(server(), f.alice.id)
      assert {:ok, ^restore_id} = SecurityTransitions.restore_open(server(), f.bob.id)
      assert [%{open: false, closed_at: %DateTime{}}] = rows(f.alice.id)
    end

    test "only the system reads a person's row" do
      assert {:error, :cross_tenant} =
               SecurityTransitions.restore_open(Prima.Actor.in_athanor("ath_x"), "usr_x")
    end

    test "a group with a member still recovering is frozen until each has closed", %{
      fixture: f
    } do
      group = Prima.Actor.in_athanor(f.group.id)
      assert {:ok, true} = SecurityTransitions.restore_frozen?(group)

      # The seat's own transaction refuses it, under the athanor's lock.
      newcomer = person!()

      assert {:error, :recovering_from_restore} =
               Arca.Members.seat(group, %{user_id: newcomer.id, added_by: "x"})

      # A person's own athanor is never frozen by it.
      assert {:ok, false} = SecurityTransitions.restore_frozen?(Prima.Actor.in_athanor(f.own.id))

      {:ok, _} =
        Arca.Repo.locking_transaction(fn -> SecurityTransitions.close_restore!(f.alice.id) end)

      assert {:ok, true} = SecurityTransitions.restore_frozen?(group)

      {:ok, _} =
        Arca.Repo.locking_transaction(fn -> SecurityTransitions.close_restore!(f.bob.id) end)

      assert {:ok, false} = SecurityTransitions.restore_frozen?(group)
      assert {:ok, _seated} = Arca.Members.seat(group, %{user_id: newcomer.id, added_by: "x"})
    end

    test "an invitation to a frozen group stays an invitation until every member has recovered",
         %{fixture: f} do
      newcomer = person!()

      # Invitations made before the freeze, which a frozen group no longer
      # takes (`Arca.Members.seat/3`).
      identifier = "per_" <> String.duplicate("a", 64)

      insert!(Schemas.Membership, invited(f.group.id, %{person_identifier: identifier}))

      assert {:ok, []} =
               Arca.Members.activate_invited_identifier(server(), newcomer.id, identifier, now())

      refute Arca.Repo.exists?(
               from(m in Schemas.Membership,
                 where: m.user_id == ^newcomer.id and m.athanor_id == ^f.group.id
               )
             )

      for person <- [f.alice, f.bob] do
        {:ok, _} =
          Arca.Repo.locking_transaction(fn -> SecurityTransitions.close_restore!(person.id) end)
      end

      group = f.group.id

      assert {:ok, [^group]} =
               Arca.Members.activate_invited_identifier(server(), newcomer.id, identifier, now())
    end

    test "the checklist names what the person must re-enable, re-consent and rotate", %{
      fixture: f,
      restore_id: restore_id
    } do
      assert {:ok, list} = SecurityTransitions.restore_checklist(server(), f.alice.id)
      assert list.restore_id == restore_id
      assert list.restored

      # A person who arrived after the restore was never restored.
      newcomer = person!()

      assert {:ok, %{restored: false, restore_id: nil}} =
               SecurityTransitions.restore_checklist(server(), newcomer.id)

      assert Enum.map(list.api_keys, & &1.id) == [f.key]
      assert Enum.map(list.webhooks, & &1.id) == [f.webhook]
      assert Enum.map(list.paired_clients, & &1.id) == [f.paired]
      assert Enum.map(list.passkeys, & &1.id) == [f.passkey]
      assert f.profile in Enum.map(list.profiles, & &1.id)
      assert f.vault in Enum.map(list.vault_entries, & &1.id)
      assert list.instance_entries == []

      assert {:ok, %{instance_entries: entries}} =
               SecurityTransitions.restore_checklist(server(), f.alice.id, platform_admin: true)

      assert f.instance in Enum.map(entries, & &1.id)

      # Another person's checklist holds nothing of hers.
      assert {:ok, bob} = SecurityTransitions.restore_checklist(server(), f.bob.id)
      assert bob.api_keys == [] and bob.paired_clients == []
      assert Enum.map(bob.passkeys, & &1.id) == [f.bob_passkey]
    end
  end

  # ---------------------------------------------------------------------------
  # The kit's challenge and credential
  # ---------------------------------------------------------------------------

  describe "the kit's challenge" do
    setup do
      fixture = home!()
      restore_id = marked!()
      {:ok, _change} = SecurityTransitions.restore(slot: :none)
      %{fixture: fixture, restore_id: restore_id}
    end

    defp later(ms), do: DateTime.add(Arca.ServerMetaStorage.now!(), ms, :millisecond)

    test "is redeemed once for a credential that stands while the row is open", %{
      fixture: f,
      restore_id: restore_id
    } do
      user = f.alice.id
      challenge = Prima.Digest.sha256("challenge")
      credential = Prima.Digest.sha256("credential")

      assert :ok =
               SecurityTransitions.put_kit_challenge(
                 server(),
                 user,
                 restore_id,
                 challenge,
                 later(60_000)
               )

      assert :ok =
               SecurityTransitions.redeem_kit_challenge(
                 server(),
                 user,
                 restore_id,
                 challenge,
                 credential,
                 later(60_000)
               )

      # A replay of the same challenge redeems nothing.
      assert {:error, :challenge_refused} =
               SecurityTransitions.redeem_kit_challenge(
                 server(),
                 user,
                 restore_id,
                 challenge,
                 Prima.Digest.sha256("again"),
                 later(60_000)
               )

      assert {:ok, ^restore_id} = SecurityTransitions.kit_credential(server(), user, credential)

      assert {:error, :not_standing} =
               SecurityTransitions.kit_credential(server(), user, Prima.Digest.sha256("other"))

      # Another person's credential is not hers.
      assert {:error, :not_standing} =
               SecurityTransitions.kit_credential(server(), f.bob.id, credential)

      # The row's close ends the credential.
      {:ok, _} = Arca.Repo.locking_transaction(fn -> SecurityTransitions.close_restore!(user) end)

      assert {:error, :not_standing} =
               SecurityTransitions.kit_credential(server(), user, credential)
    end

    test "a challenge anyone asks for displaces neither another challenge nor the credential",
         %{fixture: f, restore_id: restore_id} do
      user = f.alice.id
      first = Prima.Digest.sha256("first")
      second = Prima.Digest.sha256("second")
      credential = Prima.Digest.sha256("credential")

      for challenge <- [first, second] do
        assert :ok =
                 SecurityTransitions.put_kit_challenge(
                   server(),
                   user,
                   restore_id,
                   challenge,
                   later(60_000)
                 )
      end

      assert :ok =
               SecurityTransitions.redeem_kit_challenge(
                 server(),
                 user,
                 restore_id,
                 first,
                 credential,
                 later(60_000)
               )

      assert :ok =
               SecurityTransitions.put_kit_challenge(
                 server(),
                 user,
                 restore_id,
                 Prima.Digest.sha256("third"),
                 later(60_000)
               )

      assert {:ok, ^restore_id} = SecurityTransitions.kit_credential(server(), user, credential)

      assert :ok =
               SecurityTransitions.redeem_kit_challenge(
                 server(),
                 user,
                 restore_id,
                 second,
                 Prima.Digest.sha256("credential-2"),
                 later(60_000)
               )
    end

    test "an expired challenge, another person's or a closed row is refused", %{
      fixture: f,
      restore_id: restore_id
    } do
      challenge = Prima.Digest.sha256("c1")
      cred = Prima.Digest.sha256("cred")

      assert :ok =
               SecurityTransitions.put_kit_challenge(
                 server(),
                 f.alice.id,
                 restore_id,
                 challenge,
                 later(-1)
               )

      assert {:error, :challenge_refused} =
               SecurityTransitions.redeem_kit_challenge(
                 server(),
                 f.alice.id,
                 restore_id,
                 challenge,
                 cred,
                 later(60_000)
               )

      assert :ok =
               SecurityTransitions.put_kit_challenge(
                 server(),
                 f.alice.id,
                 restore_id,
                 challenge,
                 later(60_000)
               )

      assert {:error, :challenge_refused} =
               SecurityTransitions.redeem_kit_challenge(
                 server(),
                 f.bob.id,
                 restore_id,
                 challenge,
                 cred,
                 later(60_000)
               )

      {:ok, _} =
        Arca.Repo.locking_transaction(fn -> SecurityTransitions.close_restore!(f.alice.id) end)

      assert {:error, :closed} =
               SecurityTransitions.redeem_kit_challenge(
                 server(),
                 f.alice.id,
                 restore_id,
                 challenge,
                 cred,
                 later(60_000)
               )

      assert {:error, :closed} =
               SecurityTransitions.put_kit_challenge(
                 server(),
                 f.alice.id,
                 restore_id,
                 challenge,
                 later(60_000)
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Failure injection, per adapter
  # ---------------------------------------------------------------------------

  defp fail_on!(table, event), do: trigger!(table, event, :fail)
  defp skip_on!(table, event), do: trigger!(table, event, :skip)

  defp trigger!(table, event, mode) do
    name = "rs_#{mode}_#{table}_#{String.downcase(event)}"

    if Arca.Test.Adapter.sqlite?() do
      body =
        if mode == :fail,
          do: "SELECT RAISE(ABORT, 'injected #{event} failure');",
          else: "SELECT RAISE(IGNORE);"

      Arca.Repo.query!("CREATE TRIGGER #{name} BEFORE #{event} ON #{table} BEGIN #{body} END")
    else
      body =
        if mode == :fail,
          do: "RAISE EXCEPTION 'injected #{event} failure';",
          else: "RETURN NULL;"

      Arca.Repo.query!(
        "CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN #{body} END $$"
      )

      Arca.Repo.query!(
        "CREATE TRIGGER #{name} BEFORE #{event} ON #{table} " <>
          "FOR EACH ROW EXECUTE FUNCTION #{name}()"
      )
    end

    {name, table}
  end

  defp clear_failure!({name, table}) do
    if Arca.Test.Adapter.sqlite?() do
      Arca.Repo.query!("DROP TRIGGER IF EXISTS #{name}")
    else
      Arca.Repo.query!("DROP TRIGGER IF EXISTS #{name} ON #{table}")
      Arca.Repo.query!("DROP FUNCTION IF EXISTS #{name}()")
    end
  end
end
