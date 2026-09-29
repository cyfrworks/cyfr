# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DirectoryHeadsTest do
  @moduledoc """
  A home's verified cache of other people's heads: the genesis and
  directory binding immutable, the head moved by compare-and-set,
  freshness read on the database's clock, and a changed `key_epoch`
  retiring, in the same transaction, the sessions, passkeys, pending
  confirmations and device certificates bound to the old one, after which
  the old epoch binds nothing new.
  """

  # Takes the cell's slot, which is process-wide; each case restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{
    DeviceCertificates,
    DirectoryHeads,
    PairedClients,
    Passkeys,
    PendingConfirmations,
    PersonIdentities,
    SessionStorage,
    Users
  }

  alias Arca.Schemas.{DirectoryHead, Session}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    hold_slot!()
    :ok
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

  defp cached!(identifier, key_epoch) do
    {:ok, head} =
      DirectoryHeads.put(server(), %{
        identifier: identifier,
        genesis: "genesis-bytes",
        directory_url: "https://dir.example",
        head_hash: key_epoch,
        key_epoch: key_epoch,
        state: ~s({"head":"#{key_epoch}"})
      })

    head
  end

  defp identifier, do: "per_" <> Prima.Digest.sha256_hex("g-#{System.unique_integer()}")

  defp remote_person!(identifier) do
    now = DateTime.utc_now()

    {:ok, person} =
      Users.mint(
        server(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          provider: "cyfr",
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        %{
          key: "cyfr|https://dir.example|#{identifier}",
          provider: "cyfr",
          issuer: "https://dir.example",
          subject: identifier,
          first_seen_at: now,
          last_seen_at: now
        },
        also: fn person ->
          {:ok, _} =
            PersonIdentities.create(server(), %{
              user_id: person.id,
              provenance: "remote",
              identifier: identifier,
              directory_url: "https://dir.example"
            })

          :ok
        end
      )

    person
  end

  defp session!(user_id, epoch) do
    hash = :crypto.strong_rand_bytes(32)
    :ok = try_session(user_id, epoch, hash)
    hash
  end

  defp try_session(user_id, epoch, hash \\ :crypto.strong_rand_bytes(32)) do
    SessionStorage.create_session(
      hash,
      %{
        user_id: user_id,
        provider: "cyfr",
        identity_key_epoch: epoch,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      },
      Arca.Test.Actor.issuance(user_id)
    )
  end

  defp other_identifier(person) do
    {:ok, %{identifier: identifier}} = PersonIdentities.get(server(), person.id)
    identifier
  end

  defp passkey_attrs(user_id, epoch) do
    %{
      user_id: user_id,
      credential_id: "cred-#{System.unique_integer([:positive])}",
      rp_id: "home.example",
      relying_home: "https://home.example",
      public_key: "cose-key",
      registration_digest: digest("registration"),
      possession_verified: true,
      state: "active",
      identity_key_epoch: epoch
    }
  end

  defp passkey!(user_id, epoch) do
    {:ok, passkey} = Passkeys.register(server(), passkey_attrs(user_id, epoch))
    passkey
  end

  defp record(athanor, user_id) do
    {:ok, record} =
      Prima.Confirmation.new(
        id: "cnf_dh_#{System.unique_integer([:positive])}",
        home: "https://home.example",
        rp_id: "home.example",
        athanor: athanor.athanor_id,
        person: user_id,
        operation: "vault.create",
        args_digest: digest("args"),
        action: "credential_entry",
        preview: %{home: "https://home.example", athanor: "Home", operation: "vault.create"},
        challenge: :crypto.strong_rand_bytes(32),
        expires_at: System.system_time(:millisecond) + 300_000
      )

    record
  end

  defp confirmation!(athanor, user_id, epoch) do
    {:ok, row} =
      PendingConfirmations.open(athanor, %{record: record(athanor, user_id), identity_key_epoch: epoch})

    row
  end

  defp device_client!(athanor, user_id) do
    device_key = :crypto.strong_rand_bytes(32)

    {:ok, client} =
      PairedClients.record(athanor, %{
        user_id: user_id,
        source_kind: "device_cert",
        source_id: Prima.Digest.sha256(device_key),
        device_public_key: device_key
      })

    client
  end

  defp certificate_attrs(client, identifier, epoch) do
    now = DateTime.utc_now()

    %{
      paired_client_id: client.id,
      user_id: client.user_id,
      subject_kind: "identity",
      identifier: identifier,
      key_epoch: epoch,
      device_public_key: client.device_public_key,
      issuing_home: "https://home.example",
      audience_home: "https://other.example",
      not_before: DateTime.add(now, -60, :second),
      expires_at: DateTime.add(now, 3600, :second),
      certificate: "cert-#{System.unique_integer()}",
      digest: digest("cert")
    }
  end

  defp certificate!(athanor, client, identifier, epoch) do
    {:ok, certificate} =
      DeviceCertificates.record(athanor, certificate_attrs(client, identifier, epoch))

    certificate
  end

  test "caches a first head once, and reads its freshness on the database's clock" do
    id = identifier()
    epoch = digest("epoch")
    head = cached!(id, epoch)

    assert head.directory_url == "https://dir.example"
    assert {:ok, %{fresh: true, head: ^head}} = DirectoryHeads.fresh(server(), id, 300)

    assert {:error, :exists} =
             DirectoryHeads.put(server(), %{
               identifier: id,
               genesis: "genesis-bytes",
               directory_url: "https://dir.example",
               head_hash: epoch,
               key_epoch: epoch,
               state: "{}"
             })

    long_ago = DateTime.add(DateTime.utc_now(), -600, :second)

    {1, _} =
      Arca.Repo.update_all(from(h in DirectoryHead, where: h.identifier == ^id),
        set: [verified_at: long_ago]
      )

    assert {:ok, %{fresh: false}} = DirectoryHeads.fresh(server(), id, 300)
    assert {:ok, %{verified_at: touched}} = DirectoryHeads.touch(server(), id, epoch)
    assert DateTime.compare(touched, long_ago) == :gt
    assert {:error, :stale} = DirectoryHeads.touch(server(), id, digest("other"))
  end

  test "an advance names the cached head, and never moves the genesis or the directory" do
    id = identifier()
    epoch = digest("epoch")
    cached!(id, epoch)
    next = digest("next")

    attrs = %{
      genesis: "genesis-bytes",
      directory_url: "https://dir.example",
      head_hash: next,
      key_epoch: epoch,
      state: "{}"
    }

    assert {:error, :stale} = DirectoryHeads.advance(server(), id, digest("wrong"), attrs)

    assert {:error, :binding_changed} =
             DirectoryHeads.advance(server(), id, epoch, %{attrs | directory_url: "https://other.example"})

    assert {:error, :binding_changed} =
             DirectoryHeads.advance(server(), id, epoch, %{attrs | genesis: "other genesis"})

    assert {:ok, %{head: %{head_hash: ^next}, retired: retired}} =
             DirectoryHeads.advance(server(), id, epoch, attrs)

    assert retired == %{session_hashes: [], passkey_ids: [], confirmation_ids: [], certificate_ids: []}
    assert {:error, :not_found} = DirectoryHeads.advance(server(), identifier(), epoch, attrs)
  end

  test "a changed key_epoch retires what was bound to the old one, which then binds nothing" do
    id = identifier()
    old = digest("old")
    new = digest("new")
    cached!(id, old)
    person = remote_person!(id)
    athanor = Prima.Actor.in_athanor("ath_dh_#{System.unique_integer([:positive])}")
    other = remote_person!(identifier())

    session = session!(person.id, old)
    passkey = passkey!(person.id, old)
    confirmation = confirmation!(athanor, person.id, old)
    client = device_client!(athanor, person.id)
    certificate = certificate!(athanor, client, id, old)

    # What another identifier's person holds is not this head's to retire.
    cached!(other_identifier(other), old)
    kept = session!(other.id, old)

    assert {:ok, %{retired: retired}} =
             DirectoryHeads.advance(server(), id, old, %{
               genesis: "genesis-bytes",
               directory_url: "https://dir.example",
               head_hash: new,
               key_epoch: new,
               state: "{}"
             })

    assert retired == %{
             session_hashes: [session],
             passkey_ids: [passkey.id],
             confirmation_ids: [confirmation.id],
             certificate_ids: [certificate.id]
           }

    assert [] = Arca.Repo.all(from(s in Session, where: s.user_id == ^person.id))
    assert [_] = Arca.Repo.all(from(s in Session, where: s.token_hash == ^kept))
    assert {:ok, %{state: "revoked"}} = Passkeys.get(server(), passkey.id)
    assert {:ok, %{state: "voided"}} = PendingConfirmations.get(athanor, confirmation.id)
    assert {:ok, %{status: "revoked"}} = DeviceCertificates.get(athanor, certificate.id)

    # The retired epoch binds nothing new, on every write that binds one.
    assert {:error, :stale_key_epoch} = try_session(person.id, old)
    assert {:error, :stale_key_epoch} = Passkeys.register(server(), passkey_attrs(person.id, old))

    assert {:error, :stale_key_epoch} =
             PendingConfirmations.open(athanor, %{
               record: record(athanor, person.id),
               identity_key_epoch: old
             })

    assert {:error, :stale_key_epoch} =
             DeviceCertificates.record(athanor, certificate_attrs(client, id, old))

    # The current one does.
    assert is_binary(session!(person.id, new))
    assert {:ok, _} = Passkeys.register(server(), passkey_attrs(person.id, new))
    assert {:ok, _} = DeviceCertificates.record(athanor, certificate_attrs(client, id, new))
  end

  test "only the platform's own actor reads or writes the cache" do
    member = Prima.Actor.in_athanor("ath_test")
    assert {:error, :cross_tenant} = DirectoryHeads.get(member, identifier())
    assert {:error, :cross_tenant} = DirectoryHeads.put(member, %{})
    assert :ok = DirectoryHeads.delete(server(), identifier())
  end
end

defmodule Arca.DirectoryHeadsRaceTest do
  @moduledoc """
  A session binding a remote person's `key_epoch` racing the advance that
  retires it, on two real connections outside the sandbox. The advance
  locks the identifier's people first, and a session holds its person's
  lock and reads the cached epoch under it, so the two serialize in either
  order: an advance waiting behind a session retires it, and a session
  waiting behind an advance reads the new epoch and is refused. On
  PostgreSQL the waiter blocks on the person's row; on SQLite at the lock
  its transaction takes at entry.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.{ControlPlane, DirectoryHeads, PersonIdentities, SessionStorage}
  alias Arca.Schemas.{CellLease, DirectoryHead, ExternalIdentity, PersonIdentity, Session, User}
  alias Ecto.Adapters.SQL.Sandbox

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  @gate 7_310_002

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()
  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres
  defp digest(seed), do: Prima.Digest.sha256("#{seed}-#{System.unique_integer()}")

  setup do
    hold_slot!()
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    identifier = "per_" <> Prima.Digest.sha256_hex("race-#{n}")
    old = digest("old")

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(Session, user_id: ^user_id))
        Arca.Repo.delete_all(where(PersonIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(User, id: ^user_id))
        Arca.Repo.delete_all(where(DirectoryHead, identifier: ^identifier))
      end)
    end)

    unboxed(fn ->
      {:ok, _} =
        Arca.Users.mint(
          server(),
          %{
            id: user_id,
            provider: "cyfr",
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          %{
            key: "cyfr|https://dir.example|#{identifier}",
            provider: "cyfr",
            issuer: "https://dir.example",
            subject: identifier,
            first_seen_at: now,
            last_seen_at: now
          },
          also: fn person ->
            {:ok, _} =
              PersonIdentities.create(server(), %{
                user_id: person.id,
                provenance: "remote",
                identifier: identifier,
                directory_url: "https://dir.example"
              })

            :ok
          end
        )

      {:ok, _} =
        DirectoryHeads.put(server(), %{
          identifier: identifier,
          genesis: "genesis-bytes",
          directory_url: "https://dir.example",
          head_hash: old,
          key_epoch: old,
          state: "{}"
        })
    end)

    {:ok, user_id: user_id, identifier: identifier, old: old}
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
      waiting? -> :ok
      tries == 0 -> flunk("backend #{backend} is not waiting at #{inspect(at)}: #{type} #{event} #{query}")
      true -> retry_wait!(backend, at, tries)
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

  defp session(user_id, epoch, hash, opts) do
    SessionStorage.create_session(
      hash,
      %{
        user_id: user_id,
        provider: "cyfr",
        identity_key_epoch: epoch,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      },
      Arca.Test.Actor.issuance(user_id) ++ opts
    )
  end

  defp advance(identifier, old, new) do
    DirectoryHeads.advance(server(), identifier, old, %{
      genesis: "genesis-bytes",
      directory_url: "https://dir.example",
      head_hash: new,
      key_epoch: new,
      state: "{}"
    })
  end

  test "an advance waiting behind a session binding the old epoch retires it", %{
    user_id: user_id,
    identifier: identifier,
    old: old
  } do
    test = self()
    hash = :crypto.strong_rand_bytes(32)

    issuer =
      Task.async(fn ->
        unboxed(fn ->
          session(user_id, old, hash,
            also: fn _session ->
              send(test, :issuance_holds)

              receive do
                :go -> :ok
              end
            end
          )
        end)
      end)

    assert_receive :issuance_holds, 5_000
    new = digest("new")

    advancer =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:advancer, backend()})
          advance(identifier, old, new)
        end)
      end)

    assert_receive {:advancer, pid}, 5_000
    if postgres?(), do: await_wait!(pid, [~s("users"), "FOR UPDATE"])
    refute Task.yield(advancer, 300), "the advance retired while a session bound the old epoch"

    send(issuer.pid, :go)
    assert :ok = Task.await(issuer, 25_000)
    assert {:ok, %{retired: %{session_hashes: [^hash]}}} = Task.await(advancer, 25_000)
    refute unboxed(fn -> Arca.Repo.exists?(where(Session, token_hash: ^hash)) end)
  end

  if Arca.Repo.adapter() != Ecto.Adapters.Postgres do
    @tag skip: "the advance has no pause point but a PostgreSQL trigger; SQLite's write lock orders it"
  end

  test "a session waiting behind the advance reads the new epoch and is refused", %{
    user_id: user_id,
    identifier: identifier,
    old: old
  } do
    test = self()
    new = digest("new")
    install_gate!("directory_heads")
    gate = close_gate!()

    advancer =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:advancer, backend()})
          gated(fn -> advance(identifier, old, new) end)
        end)
      end)

    assert_receive {:advancer, advancing}, 5_000
    await_wait!(advancing, :gate)
    hash = :crypto.strong_rand_bytes(32)

    issuer =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:issuer, backend()})
          session(user_id, old, hash, [])
        end)
      end)

    assert_receive {:issuer, issuing}, 5_000
    await_wait!(issuing, [~s("users"), "FOR UPDATE"])
    refute Task.yield(issuer, 300), "the session bound an epoch the advance was retiring"

    open_gate!(gate)
    assert {:ok, %{retired: %{session_hashes: []}}} = Task.await(advancer, 25_000)
    assert {:error, :stale_key_epoch} = Task.await(issuer, 25_000)
    refute unboxed(fn -> Arca.Repo.exists?(where(Session, token_hash: ^hash)) end)
  end
end
