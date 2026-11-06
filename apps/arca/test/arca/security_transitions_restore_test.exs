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
  the transition once. The shared threads, a pair among them and an
  invitation into one stay as they were. Every device certificate is
  revoked and every paired client suspended, for good: a device comes
  back by a fresh hello. What the person re-enables is listed in their
  checklist (`restore_checklist/2`).
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

  defp athanor!(owner) do
    n = uniq()

    {:ok, athanor} =
      Arca.Athanors.insert(server(), %{
        name: "R#{n}",
        slug: "rs-#{n}",
        owner_user_id: owner,
        created_by: owner
      })

    athanor
  end

  # The platform administrator's mark, set on the row as the installation's
  # first admission writes it.
  defp administrator!(user_id) do
    {1, _} =
      Arca.Repo.update_all(from(u in Schemas.User, where: u.id == ^user_id),
        set: [platform_admin_at: now()]
      )

    :ok
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

  # A certificate this home issued the paired client `client_id`, in
  # `state`, unexpired.
  defp certificate!(athanor_id, user_id, client_id, state) do
    id = Prima.UUID7.generate_id("dcr")

    insert!(Schemas.DeviceCertificate, %{
      id: id,
      athanor_id: athanor_id,
      paired_client_id: client_id,
      user_id: user_id,
      identifier: "per_" <> Prima.Digest.sha256_hex("cert-#{uniq()}"),
      kid: Prima.Digest.sha256("kid-#{uniq()}"),
      head: Prima.Digest.sha256("head-#{uniq()}"),
      device_public_key: :crypto.strong_rand_bytes(32),
      issuing_home: "https://home.example",
      audience_home: "https://home.example",
      not_before: now(),
      expires_at: DateTime.add(now(), 3_600, :second),
      certificate: "signed-certificate",
      digest: Prima.Digest.sha256("cert-#{uniq()}"),
      state: state,
      revoked_at: if(state == "revoked", do: now()),
      inserted_at: now(),
      updated_at: now()
    })

    id
  end

  # The client of a passkey of the person's account that signed in here,
  # in `standing`: known by its key, holding no device key.
  defp passkey!(athanor_id, user_id, standing) do
    id = Prima.UUID7.generate_id("pcl")

    insert!(Schemas.PairedClient, %{
      id: id,
      athanor_id: athanor_id,
      user_id: user_id,
      source_kind: "passkey",
      source_id: id,
      kid: Prima.Digest.sha256("passkey-#{uniq()}"),
      head: Prima.Digest.sha256("head-#{uniq()}"),
      standing: standing,
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

  # A home as a backup holds it: two people, each with their own athanor,
  # Alice the installation's administrator, a shared thread they sit in,
  # their pair and an invitation into the thread, and in every store the
  # transition moves an active, a blocked and a terminal row.
  defp home! do
    alice = person!()
    :ok = administrator!(alice.id)
    bob = person!()
    carol = person!()
    own = athanor!(alice.id)
    bob_own = athanor!(bob.id)

    {:ok, shared_thread} =
      Arca.SharedThreads.create(server(), %{title: "R#{uniq()}", created_by: alice.id})

    {:ok, _seat} = Arca.SharedThreadMembers.seat(server(), shared_thread.id, bob.id, alice.id)
    {:ok, pair} = Arca.SharedThreads.pair(server(), alice.id, bob.id)

    {:ok, shared_invite} =
      Arca.SharedThreadMembers.invite(server(), shared_thread.id, "per_#{uniq()}", alice.id)

    profile = profile!(own.id, "active")
    consent = consent!(own.id, profile)
    vault = vault!(own.id, "active")
    thread = thread!(own.id, alice.id)
    open_turn = turn!(own.id, thread, "running")
    {open_execution, open_attempt} = run!(own.id, alice.id, "running", "running")
    {paused_execution, paused_attempt} = run!(bob_own.id, bob.id, "paused", "paused")
    {done_execution, done_attempt} = run!(own.id, alice.id, "completed", "completed")
    paired = paired!(own.id, alice.id, "active")

    %{
      alice: alice,
      bob: bob,
      carol: carol,
      bob_passkey: passkey!(bob_own.id, bob.id, "active"),
      own: own,
      bob_own: bob_own,
      shared_thread: shared_thread,
      pair: pair,
      shared_invite: shared_invite,
      sessions: [session!(alice.id), session!(bob.id), session!(carol.id)],
      key: key!(own.id, alice.id),
      revoked_key: key!(own.id, alice.id, %{revoked: true}),
      webhook: webhook!(own.id, alice.id, profile),
      paired: paired,
      revoked_paired: paired!(own.id, alice.id, "revoked"),
      certificate: certificate!(own.id, alice.id, paired, "active"),
      revoked_certificate: certificate!(own.id, alice.id, paired, "revoked"),
      passkey: passkey!(own.id, alice.id, "active"),
      revoked_passkey: passkey!(own.id, alice.id, "revoked"),
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
      share: share!(own.id, vault),
      revoked_share: share!(own.id, vault, "revoked"),
      open_turn: open_turn,
      paused_turn: turn!(bob_own.id, thread!(bob_own.id, bob.id), "paused"),
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
      assert get(Schemas.DeviceCertificate, fixture.certificate).state == "active"
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
      threads = [fixture.shared_thread.id, fixture.pair.id]
      threads_before = Enum.map(threads, &get(Schemas.SharedThread, &1))
      invite_before = get(Schemas.SharedThreadMember, fixture.shared_invite.id)
      assert %DateTime{} = admin_at = get(Schemas.User, fixture.alice.id).platform_admin_at
      restore_id = marked!()

      assert {:ok, change} = SecurityTransitions.restore(slot: :none)
      assert change.restore_id == restore_id

      # Every standing is raised.
      assert get(Schemas.User, fixture.alice.id).security_generation == alice_generation + 1
      assert get(Schemas.Athanor, fixture.own.id).security_generation == own_generation + 1

      # The administrator's mark stands: the restore raises her generation
      # and suspends her bindings here, and takes no capability.
      assert get(Schemas.User, fixture.alice.id).platform_admin_at == admin_at

      # Sessions are retired.
      for hash <- fixture.sessions,
          do: refute(Arca.Repo.exists?(where(Schemas.Session, token_hash: ^hash)))

      # Keys, webhooks, devices and passkeys are suspended; revoked rows
      # keep their state.
      assert %{suspended: true, revoked: false} = get(Schemas.ApiKey, fixture.key)
      assert %{suspended: false, revoked: true} = get(Schemas.ApiKey, fixture.revoked_key)
      assert get(Schemas.Webhook, fixture.webhook).suspended == true
      assert get(Schemas.PairedClient, fixture.paired).standing == "suspended"
      assert get(Schemas.PairedClient, fixture.revoked_paired).standing == "revoked"
      assert get(Schemas.PairedClient, fixture.passkey).standing == "suspended"
      assert get(Schemas.PairedClient, fixture.revoked_passkey).standing == "revoked"
      assert change.suspended_api_key_ids == [fixture.key]

      assert change.suspended_paired_client_ids ==
               Enum.sort([fixture.paired, fixture.passkey, fixture.bob_passkey])

      # Every certificate this home issued is revoked: a device comes back
      # by a fresh hello, never by its old certificate.
      assert %{state: "revoked", revoked_at: %DateTime{}} =
               get(Schemas.DeviceCertificate, fixture.certificate)

      assert get(Schemas.DeviceCertificate, fixture.revoked_certificate).state == "revoked"
      assert change.revoked_device_certificate_ids == [fixture.certificate]

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

      # The shared thread, the pair and the invitation into the thread stay
      # the rows they were: no shared thread's standing moves with a
      # restore, and none holds anyone out.
      assert Enum.map(threads, &get(Schemas.SharedThread, &1)) == threads_before
      assert [%{kind: "shared"}, %{kind: "pair"}] = threads_before
      assert Enum.all?(threads_before, &(&1.status == "active"))

      assert %{status: "invited", user_id: nil} =
               get(Schemas.SharedThreadMember, fixture.shared_invite.id)

      assert get(Schemas.SharedThreadMember, fixture.shared_invite.id) == invite_before

      assert {:ok, %{status: "active"}} =
               Arca.SharedThreadMembers.seat(
                 server(),
                 fixture.shared_thread.id,
                 fixture.carol.id,
                 fixture.alice.id
               )

      assert is_nil(marker())
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
      assert {:error, :not_standing} = takeover(fixture.bob_own.id, fixture.paused_execution)
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
      trigger = fail_on!("paired_clients", "UPDATE")

      assert {:error, :database_error} = SecurityTransitions.restore(slot: :none)

      # Nothing moved, and the marker stays for the next boot.
      assert Arca.Repo.exists?(where(Schemas.Session, token_hash: ^hd(fixture.sessions)))
      assert get(Schemas.ApiKey, fixture.key).suspended == false
      assert get(Schemas.Profile, fixture.profile).status == "active"
      assert get(Schemas.Execution, fixture.open_execution).status == "running"
      assert get(Schemas.Invitation, fixture.invitation).revoked_at == nil
      assert get(Schemas.DeviceCertificate, fixture.certificate).state == "active"
      assert %{value: ^restore_id} = marker()

      clear_failure!(trigger)
      assert {:ok, %{restore_id: ^restore_id}} = SecurityTransitions.restore(slot: :none)
      assert {:ok, :none} = SecurityTransitions.restore(slot: :none)
      assert get(Schemas.PairedClient, fixture.passkey).standing == "suspended"
      assert get(Schemas.DeviceCertificate, fixture.certificate).state == "revoked"
    end

    test "a row a statement leaves standing fails the postcondition and rolls back" do
      fixture = home!()
      marked!()
      trigger = skip_on!("api_keys", "UPDATE")

      try do
        assert {:error, :postcondition_failed} = SecurityTransitions.restore(slot: :none)
        assert get(Schemas.PairedClient, fixture.passkey).standing == "active"
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
        assert get(Schemas.PairedClient, fixture.passkey).standing == "active"
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
  # The checklist
  # ---------------------------------------------------------------------------

  describe "the checklist" do
    setup do
      fixture = home!()
      marked!()
      {:ok, _change} = SecurityTransitions.restore(slot: :none)
      %{fixture: fixture}
    end

    test "names what the person must re-enable, re-consent and rotate", %{fixture: f} do
      assert {:ok, list} = SecurityTransitions.restore_checklist(server(), f.alice.id)
      assert Enum.sort(Map.keys(list)) == [:api_keys, :profiles, :vault_entries, :webhooks]
      assert Enum.map(list.api_keys, & &1.id) == [f.key]
      assert Enum.map(list.webhooks, & &1.id) == [f.webhook]
      assert f.profile in Enum.map(list.profiles, & &1.id)
      assert f.vault in Enum.map(list.vault_entries, & &1.id)

      # Another person's checklist holds nothing of hers.
      assert {:ok, bob} = SecurityTransitions.restore_checklist(server(), f.bob.id)
      assert bob.api_keys == [] and bob.webhooks == []
    end

    test "only the system reads a person's checklist" do
      assert {:error, :cross_tenant} =
               SecurityTransitions.restore_checklist(Prima.Actor.in_athanor("ath_x"), "usr_x")
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
