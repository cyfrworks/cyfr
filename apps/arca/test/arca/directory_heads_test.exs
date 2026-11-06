# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DirectoryHeadsTest do
  @moduledoc """
  A home's verified cache of account heads: the genesis and directory
  binding immutable, the head moved by compare-and-set, freshness read on
  the database's clock. An advance walks the entries after the cached
  head in its own transaction: a removed key's sessions, certificates,
  confirmations and clients retire, a recovery retires every binding of
  the account and every session of its people, bound to a key or not,
  and a key removed and added again between two reads is
  retired and then admitted afresh. Every binding names the cached head
  under the person's lock, `:stale_head` otherwise. An account the
  directory answered gone retires everything, every session of its people
  included, and binds nothing. A head no
  person and no pending invitation here names is swept once it was last
  verified past the caller's bound; every other stays.
  """

  # Takes the cell's slot, which is process-wide; each case restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{
    DeviceCertificates,
    DirectoryHeads,
    PairedClients,
    PendingConfirmations,
    PersonIdentities,
    SessionStorage
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
  defp identifier, do: "per_" <> Prima.Digest.sha256_hex("g-#{System.unique_integer()}")

  defp cached!(identifier, head) do
    {:ok, row} =
      DirectoryHeads.put(server(), %{
        identifier: identifier,
        genesis: "genesis-bytes",
        directory_url: "https://dir.example",
        head_hash: head,
        state: ~s({"head":"#{head}"})
      })

    row
  end

  # A person whose identity row names `identifier`, without caching it.
  defp remote_person!(identifier, head \\ nil) do
    now = DateTime.utc_now()

    {:ok, person} =
      Arca.Test.People.mint(
        server(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        nil,
        also: fn person ->
          {:ok, _} =
            PersonIdentities.create(server(), %{
              user_id: person.id,
              identifier: identifier,
              directory_url: "https://dir.example",
              head_hash: head || digest("read")
            })

          :ok
        end
      )

    person
  end

  # A person with an account this home has read, at `head`.
  defp account!(head) do
    id = identifier()
    cached!(id, head)
    %{person: remote_person!(id, head), identifier: id}
  end

  defp athanor, do: Prima.Actor.in_athanor("ath_dh_#{System.unique_integer([:positive])}")

  defp try_session(user_id, kid, head, hash \\ :crypto.strong_rand_bytes(32)) do
    SessionStorage.create_session(
      hash,
      %{
        user_id: user_id,
        provider: "cyfr",
        kid: kid,
        head: head,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      },
      Arca.Test.Actor.issuance(user_id)
    )
  end

  defp session!(user_id, kid, head) do
    hash = :crypto.strong_rand_bytes(32)
    :ok = try_session(user_id, kid, head, hash)
    hash
  end

  defp device_key, do: :crypto.strong_rand_bytes(32)

  defp try_client(athanor, user_id, key, head) do
    PairedClients.record(athanor, %{
      user_id: user_id,
      source_kind: "device_cert",
      source_id: "req_#{System.unique_integer([:positive])}",
      device_public_key: key,
      kid: Prima.Identity.Key.kid(key),
      head: head
    })
  end

  defp client!(athanor, user_id, key, head) do
    {:ok, client} = try_client(athanor, user_id, key, head)
    client
  end

  defp certificate_attrs(client, identifier, head) do
    now = DateTime.utc_now()

    %{
      paired_client_id: client.id,
      user_id: client.user_id,
      identifier: identifier,
      kid: client.kid,
      head: head,
      device_public_key: client.device_public_key,
      issuing_home: "https://home.example",
      audience_home: "https://home.example",
      not_before: DateTime.add(now, -60, :second),
      expires_at: DateTime.add(now, 3600, :second),
      certificate: "cert-#{System.unique_integer()}",
      digest: digest("cert")
    }
  end

  defp certificate!(athanor, client, identifier, head) do
    {:ok, certificate} =
      DeviceCertificates.record(athanor, certificate_attrs(client, identifier, head))

    certificate
  end

  defp record(athanor, user_id) do
    {:ok, record} =
      Prima.Confirmation.new(
        id: Prima.Confirmation.ref("cnf_dh_#{System.unique_integer([:positive])}"),
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

  defp opened!(athanor, user_id) do
    {:ok, row} =
      PendingConfirmations.open(athanor, %{
        record: record(athanor, user_id),
        opener: "session:directory-heads-test",
        asker: %{"kind" => "session"}
      })

    row
  end

  # A record the device `client` confirmed, by its key at `head`.
  defp try_confirm(athanor, ref, client, head) do
    PendingConfirmations.confirm(athanor, ref, %{
      proof: "device",
      client_id: client.id,
      kid: client.kid,
      head: head
    })
  end

  defp confirmed!(athanor, client, head) do
    row = opened!(athanor, client.user_id)
    {:ok, _} = try_confirm(athanor, row.ref, client, head)
    row
  end

  defp advance(identifier, from, to, steps) do
    DirectoryHeads.advance(
      server(),
      identifier,
      from,
      %{
        genesis: "genesis-bytes",
        directory_url: "https://dir.example",
        head_hash: to,
        state: "{}"
      },
      steps
    )
  end

  defp hashes(user_id),
    do: Arca.Repo.all(from(s in Session, where: s.user_id == ^user_id, select: s.token_hash))

  test "caches a first head once, and reads its freshness on the database's clock" do
    id = identifier()
    head_hash = digest("head")
    head = cached!(id, head_hash)

    assert head.directory_url == "https://dir.example"
    assert is_nil(head.gone_at)
    assert {:ok, %{fresh: true, head: ^head}} = DirectoryHeads.fresh(server(), id, 300)

    assert {:error, :exists} =
             DirectoryHeads.put(server(), %{
               identifier: id,
               genesis: "genesis-bytes",
               directory_url: "https://dir.example",
               head_hash: head_hash,
               state: "{}"
             })

    assert {:error, {:invalid, %{state: _}}} =
             DirectoryHeads.put(server(), %{
               identifier: identifier(),
               genesis: "genesis-bytes",
               directory_url: "https://dir.example",
               head_hash: head_hash
             })

    long_ago = DateTime.add(DateTime.utc_now(), -600, :second)

    {1, _} =
      Arca.Repo.update_all(from(h in DirectoryHead, where: h.identifier == ^id),
        set: [verified_at: long_ago]
      )

    assert {:ok, %{fresh: false}} = DirectoryHeads.fresh(server(), id, 300)
    assert {:ok, %{verified_at: touched}} = DirectoryHeads.touch(server(), id, head_hash)
    assert DateTime.compare(touched, long_ago) == :gt
    assert {:error, :stale} = DirectoryHeads.touch(server(), id, digest("other"))
  end

  test "an advance names the cached head, and never moves the genesis or the directory" do
    id = identifier()
    head = digest("head")
    cached!(id, head)
    next = digest("next")

    attrs = %{
      genesis: "genesis-bytes",
      directory_url: "https://dir.example",
      head_hash: next,
      state: "{}"
    }

    assert {:error, :stale} = DirectoryHeads.advance(server(), id, digest("wrong"), attrs, [])

    assert {:error, :binding_changed} =
             DirectoryHeads.advance(
               server(),
               id,
               head,
               %{attrs | directory_url: "https://other.example"},
               []
             )

    assert {:error, :binding_changed} =
             DirectoryHeads.advance(server(), id, head, %{attrs | genesis: "other genesis"}, [])

    assert {:error, {:invalid, %{steps: _}}} =
             DirectoryHeads.advance(server(), id, head, attrs, [{:add_key, digest("key")}])

    assert {:ok, %{head: %{head_hash: ^next}, retired: retired}} =
             DirectoryHeads.advance(server(), id, head, attrs, [])

    assert retired == %{
             session_hashes: [],
             certificate_ids: [],
             confirmation_ids: [],
             client_ids: []
           }

    assert {:error, :not_found} = DirectoryHeads.advance(server(), identifier(), head, attrs, [])
  end

  test "a removed key's bindings retire with the walk, every other key's stand, and the people's rows read the new head" do
    old = digest("old")
    new = digest("new")
    %{person: person, identifier: id} = account!(old)
    athanor = athanor()

    removed = device_key()
    kept = device_key()
    removed_kid = Prima.Identity.Key.kid(removed)
    kept_kid = Prima.Identity.Key.kid(kept)

    removed_client = client!(athanor, person.id, removed, old)
    kept_client = client!(athanor, person.id, kept, old)
    removed_certificate = certificate!(athanor, removed_client, id, old)
    kept_certificate = certificate!(athanor, kept_client, id, old)
    removed_session = session!(person.id, removed_kid, old)
    kept_session = session!(person.id, kept_kid, old)
    unsigned = session!(person.id, nil, nil)
    removed_confirmation = confirmed!(athanor, removed_client, old)
    kept_confirmation = confirmed!(athanor, kept_client, old)
    pending = opened!(athanor, person.id)

    # Another account's binding to the same key is not this walk's.
    %{person: other, identifier: other_id} = account!(old)
    other_athanor = athanor()
    other_client = client!(other_athanor, other.id, removed, old)
    other_certificate = certificate!(other_athanor, other_client, other_id, old)

    assert {:ok, %{head: %{head_hash: ^new}, retired: retired}} =
             advance(id, old, new, [{:remove_key, removed_kid}])

    assert retired.client_ids == [removed_client.id]
    assert retired.certificate_ids == [removed_certificate.id]
    assert retired.confirmation_ids == [removed_confirmation.ref]
    assert removed_session in retired.session_hashes
    refute kept_session in retired.session_hashes
    # A session no key signed is no removed key's binding: it stands.
    refute unsigned in retired.session_hashes

    assert Enum.sort(hashes(person.id)) == Enum.sort([kept_session, unsigned])
    assert {:ok, [%{id: kept_id}]} = PairedClients.list(athanor, user_id: person.id)
    assert kept_id == kept_client.id
    assert {:ok, %{status: "revoked"}} = DeviceCertificates.get(athanor, removed_certificate.id)
    assert {:ok, %{status: "active"}} = DeviceCertificates.get(athanor, kept_certificate.id)

    assert {:ok, %{status: "active"}} =
             DeviceCertificates.get(other_athanor, other_certificate.id)

    assert {:ok, %{state: "voided"}} = PendingConfirmations.get(athanor, removed_confirmation.ref)
    assert {:ok, %{state: "confirmed"}} = PendingConfirmations.get(athanor, kept_confirmation.ref)
    assert {:ok, %{state: "pending"}} = PendingConfirmations.get(athanor, pending.ref)
    assert {:ok, %{head_hash: ^new}} = PersonIdentities.get(server(), person.id)
    assert {:ok, %{head_hash: ^old}} = PersonIdentities.get(server(), other.id)
  end

  test "a recovery retires every binding of the account and every session of its people, a session no key signed included" do
    old = digest("old")
    new = digest("new")
    %{person: person, identifier: id} = account!(old)
    %{person: other} = account!(old)
    athanor = athanor()

    client = client!(athanor, person.id, device_key(), old)
    certificate = certificate!(athanor, client, id, old)
    signed = session!(person.id, Prima.Identity.Key.kid(device_key()), old)
    unsigned = session!(person.id, nil, nil)
    others = session!(other.id, nil, nil)
    confirmation = confirmed!(athanor, client, old)

    assert {:ok, %{retired: retired}} = advance(id, old, new, [:recover])

    assert retired.client_ids == [client.id]
    assert retired.certificate_ids == [certificate.id]
    assert retired.confirmation_ids == [confirmation.ref]
    assert Enum.sort(retired.session_hashes) == Enum.sort([signed, unsigned])
    assert hashes(person.id) == []
    assert {:ok, []} = PairedClients.list(athanor, user_id: person.id)

    # Another account's session is not this recovery's.
    assert hashes(other.id) == [others]
  end

  test "a key removed and added again between two reads is retired, then admitted afresh at the new head" do
    old = digest("old")
    new = digest("new")
    %{person: person, identifier: id} = account!(old)
    athanor = athanor()
    key = device_key()
    kid = Prima.Identity.Key.kid(key)

    client = client!(athanor, person.id, key, old)
    session = session!(person.id, kid, old)

    # The walk of remove_key then add_key: the add retires nothing and is no step.
    assert {:ok, %{retired: %{client_ids: [client_id], session_hashes: [^session]}}} =
             advance(id, old, new, [{:remove_key, kid}])

    assert client_id == client.id

    # What was verified against the old head binds nothing now.
    assert {:error, :stale_head} = try_session(person.id, kid, old)
    assert {:error, :stale_head} = try_client(athanor, person.id, key, old)

    # The key is listed again at the new head, and binds afresh there.
    assert is_binary(session!(person.id, kid, new))
    readmitted = client!(athanor, person.id, key, new)
    assert readmitted.id != client.id
    assert {:ok, _} = DeviceCertificates.record(athanor, certificate_attrs(readmitted, id, new))
  end

  test "every write that binds a key names the cached head of the person's own account" do
    head = digest("head")
    %{person: person, identifier: id} = account!(head)
    %{person: other, identifier: other_id} = account!(head)
    athanor = athanor()
    stale = digest("stale")
    key = device_key()
    kid = Prima.Identity.Key.kid(key)

    assert {:error, :stale_head} = try_session(person.id, kid, stale)
    assert {:error, :stale_head} = try_client(athanor, person.id, key, stale)

    client = client!(athanor, person.id, key, head)

    assert {:error, :stale_head} =
             DeviceCertificates.record(athanor, certificate_attrs(client, id, stale))

    # A certificate names the person's own account.
    assert {:error, :stale_head} =
             DeviceCertificates.record(athanor, certificate_attrs(client, other_id, head))

    _certificate = certificate!(athanor, client, id, head)
    row = opened!(athanor, person.id)
    assert {:error, :stale_head} = try_confirm(athanor, row.ref, client, stale)
    assert {:ok, %{kid: ^kid, head: ^head}} = try_confirm(athanor, row.ref, client, head)

    # A person with no account, or one this home never read, has no head to name.
    unread = remote_person!(identifier(), head)
    assert {:error, :stale_head} = try_session(unread.id, kid, head)
    assert {:error, :stale_head} = try_session(other.id, kid, stale)

    # A key and a head are named together, or not at all.
    assert {:error, {:invalid, _}} = try_session(person.id, kid, nil)
    assert {:error, {:invalid, _}} = try_client(athanor, person.id, key, nil)

    assert {:error, {:invalid, %{kid: _}}} =
             PairedClients.record(athanor, %{
               user_id: person.id,
               source_kind: "device_cert",
               source_id: digest("source"),
               device_public_key: key,
               kid: Prima.Identity.Key.kid(device_key()),
               head: head
             })
  end

  test "an account marked gone retires every binding, binds nothing, never advances and keeps its first mark" do
    head = digest("head")
    %{person: person, identifier: id} = account!(head)
    athanor = athanor()
    key = device_key()
    kid = Prima.Identity.Key.kid(key)
    client = client!(athanor, person.id, key, head)
    certificate = certificate!(athanor, client, id, head)
    session = session!(person.id, kid, head)
    unsigned = session!(person.id, nil, nil)

    assert {:ok, %{head: %{gone_at: %DateTime{} = gone_at}, retired: retired}} =
             DirectoryHeads.gone(server(), id)

    assert retired.client_ids == [client.id]
    assert retired.certificate_ids == [certificate.id]
    assert Enum.sort(retired.session_hashes) == Enum.sort([session, unsigned])
    assert hashes(person.id) == []

    assert {:ok, %{fresh: false, head: %{gone_at: ^gone_at}}} =
             DirectoryHeads.fresh(server(), id, 300)

    assert {:error, :stale_head} = try_session(person.id, kid, head)
    assert {:error, :gone} = advance(id, head, digest("next"), [])
    assert {:error, :stale} = DirectoryHeads.touch(server(), id, head)

    assert {:ok, %{head: %{gone_at: ^gone_at}, retired: %{client_ids: []}}} =
             DirectoryHeads.gone(server(), id)

    assert {:error, :not_found} = DirectoryHeads.gone(server(), identifier())
  end

  test "only the platform's own actor reads or writes the cache" do
    member = Prima.Actor.in_athanor("ath_test")
    assert {:error, :cross_tenant} = DirectoryHeads.get(member, identifier())
    assert {:error, :cross_tenant} = DirectoryHeads.put(member, %{})
    assert {:error, :cross_tenant} = DirectoryHeads.gone(member, identifier())

    assert {:error, :cross_tenant} =
             DirectoryHeads.advance(member, identifier(), digest("h"), %{}, [])
  end

  # The bound a sweep passes.
  @bound 300_000

  # The head's last verification moved `ms` before the database's clock.
  defp aged!(identifier, ms) do
    {1, _} =
      Arca.Repo.update_all(from(h in DirectoryHead, where: h.identifier == ^identifier),
        set: [verified_at: DateTime.add(Arca.ServerMetaStorage.now!(), -ms, :millisecond)]
      )

    :ok
  end

  # A head no one here holds, last verified `ms` ago.
  defp orphan!(ms) do
    id = identifier()
    cached!(id, digest("orphan"))
    aged!(id, ms)
    id
  end

  defp cached?(identifier),
    do: Arca.Repo.exists?(from(h in DirectoryHead, where: h.identifier == ^identifier))

  # A shared thread's pending invitation naming `identifier`.
  defp invited!(identifier) do
    person = Arca.Test.Shares.person!()
    thread = Arca.Test.Shares.thread!([person.id])

    {:ok, _} = Arca.SharedThreadMembers.invite(server(), thread.id, identifier, person.id)

    :ok
  end

  describe "sweep/3" do
    test "removes a head no one here holds once it is past the bound, and keeps every head someone holds" do
      orphan = orphan!(@bound + 1_000)
      young = orphan!(@bound - 60_000)

      # A person's head stays whatever its age.
      held = identifier()
      cached!(held, digest("held"))
      remote_person!(held)
      aged!(held, 10 * @bound)

      # So does the head of an identifier a pending invitation names.
      invited = identifier()
      cached!(invited, digest("invited"))
      invited!(invited)
      aged!(invited, 10 * @bound)

      assert {:ok, 1} = DirectoryHeads.sweep(server(), @bound, 100)
      refute cached?(orphan)
      assert cached?(young)
      assert cached?(held)
      assert cached?(invited)

      assert {:ok, 0} = DirectoryHeads.sweep(server(), @bound, 100)
    end

    test "takes at most its limit, the least recently verified first" do
      older = orphan!(3 * @bound)
      newer = orphan!(2 * @bound)

      assert {:ok, 1} = DirectoryHeads.sweep(server(), @bound, 1)
      refute cached?(older)
      assert cached?(newer)

      assert {:ok, 1} = DirectoryHeads.sweep(server(), @bound, 1)
      refute cached?(newer)
    end

    test "runs under the platform's own actor alone" do
      orphan = orphan!(2 * @bound)

      for actor <- [
            Prima.Actor.in_athanor("ath_test"),
            %{server() | athanor_id: "ath_test", scope: :athanor},
            %Prima.Actor{user_id: "usr_admin", scope: :platform, platform_admin: true}
          ] do
        assert {:error, :cross_tenant} = DirectoryHeads.sweep(actor, @bound, 100)
      end

      assert cached?(orphan)
    end
  end
end

defmodule Arca.DirectoryHeadsRaceTest do
  @moduledoc """
  A session binding an account's key racing the walk that removes it, on
  two real connections outside the sandbox. The advance locks the
  account's people first, and a session holds its person's lock and reads
  the cached head under it, so the two serialize in either order: an
  advance waiting behind a session retires it, and a session waiting
  behind an advance reads the new head and is refused. On
  PostgreSQL the waiter blocks on the person's row; on SQLite at the lock
  its transaction takes at entry. A sweep waiting behind a refresh of a
  head it chose keeps the refreshed head.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.{ControlPlane, DirectoryHeads, PersonIdentities, SessionStorage}
  alias Arca.Schemas.{CellLease, DirectoryHead, PersonIdentity, Session, User}
  alias Arca.Test.LockWait
  alias Ecto.Adapters.SQL.Sandbox

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  @gate 7_310_002

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()
  defp digest(seed), do: Prima.Digest.sha256("#{seed}-#{System.unique_integer()}")

  setup do
    hold_slot!()
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    identifier = "per_" <> Prima.Digest.sha256_hex("race-#{n}")
    old = digest("old")
    kid = digest("kid")

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(Session, user_id: ^user_id))
        Arca.Repo.delete_all(where(PersonIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(User, id: ^user_id))
        Arca.Repo.delete_all(where(DirectoryHead, identifier: ^identifier))
      end)
    end)

    unboxed(fn ->
      {:ok, _} =
        Arca.Test.People.mint(
          server(),
          %{
            id: user_id,
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          nil,
          also: fn person ->
            {:ok, _} =
              PersonIdentities.create(server(), %{
                user_id: person.id,
                identifier: identifier,
                directory_url: "https://dir.example",
                head_hash: old
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
          state: "{}"
        })
    end)

    {:ok, user_id: user_id, identifier: identifier, old: old, kid: kid}
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

  # The gate's key is held in a transaction the holder keeps open until
  # `open_gate!/1`. A holder that dies with its case is mid-transaction, so
  # its connection is closed rather than lent again, and the key goes with
  # it: a session lock would stay held on the pooled connection.
  defp close_gate! do
    test = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(
            fn ->
              Arca.Repo.query!("SELECT pg_advisory_xact_lock($1)", [@gate])
              send(test, :gate_closed)
              receive do: (:open -> :ok)
            end,
            timeout: :infinity
          )
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

  defp session(user_id, kid, head, hash, opts) do
    SessionStorage.create_session(
      hash,
      %{
        user_id: user_id,
        provider: "cyfr",
        kid: kid,
        head: head,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      },
      Arca.Test.Actor.issuance(user_id) ++ opts
    )
  end

  defp advance(identifier, old, new, kid) do
    DirectoryHeads.advance(
      server(),
      identifier,
      old,
      %{
        genesis: "genesis-bytes",
        directory_url: "https://dir.example",
        head_hash: new,
        state: "{}"
      },
      [{:remove_key, kid}]
    )
  end

  test "an advance waiting behind a session binding the removed key retires it", %{
    user_id: user_id,
    identifier: identifier,
    old: old,
    kid: kid
  } do
    test = self()
    hash = :crypto.strong_rand_bytes(32)

    issuer =
      Task.async(fn ->
        unboxed(fn ->
          session(user_id, kid, old, hash,
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
          advance(identifier, old, new, kid)
        end)
      end)

    assert_receive {:advancer, pid}, 5_000
    if postgres?(), do: LockWait.await_lock_wait!(pid, [~s("users"), "FOR UPDATE"])
    refute Task.yield(advancer, 300), "the advance retired while a session bound the old head"

    send(issuer.pid, :go)
    assert :ok = Task.await(issuer, 25_000)
    assert {:ok, %{retired: %{session_hashes: [^hash]}}} = Task.await(advancer, 25_000)
    refute unboxed(fn -> Arca.Repo.exists?(where(Session, token_hash: ^hash)) end)
  end

  # The advance has no pause point but a PostgreSQL trigger; SQLite's write lock orders it.
  @tag :postgres
  test "a session waiting behind the advance reads the new head and is refused", %{
    user_id: user_id,
    identifier: identifier,
    old: old,
    kid: kid
  } do
    test = self()
    new = digest("new")
    install_gate!("directory_heads")
    gate = close_gate!()

    advancer =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:advancer, backend()})
          gated(fn -> advance(identifier, old, new, kid) end)
        end)
      end)

    assert_receive {:advancer, advancing}, 5_000
    LockWait.await_lock_wait!(advancing, [~s(UPDATE "directory_heads")], event: "advisory")
    hash = :crypto.strong_rand_bytes(32)

    issuer =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:issuer, backend()})
          session(user_id, kid, old, hash, [])
        end)
      end)

    assert_receive {:issuer, issuing}, 5_000
    LockWait.await_lock_wait!(issuing, [~s("users"), "FOR UPDATE"])
    refute Task.yield(issuer, 300), "the session bound a head the advance was moving"

    open_gate!(gate)
    assert {:ok, %{retired: %{session_hashes: []}}} = Task.await(advancer, 25_000)
    assert {:error, :stale_head} = Task.await(issuer, 25_000)
    refute unboxed(fn -> Arca.Repo.exists?(where(Session, token_hash: ^hash)) end)
  end

  test "a sweep waiting behind a refresh of the head it chose keeps the refreshed head" do
    test = self()
    orphan = "per_" <> Prima.Digest.sha256_hex("orphan-#{System.unique_integer([:positive])}")
    head = digest("orphan")

    on_exit(fn ->
      unboxed(fn -> Arca.Repo.delete_all(where(DirectoryHead, identifier: ^orphan)) end)
    end)

    # A head no one here holds, last verified an hour ago.
    unboxed(fn ->
      {:ok, _} =
        DirectoryHeads.put(server(), %{
          identifier: orphan,
          genesis: "genesis-bytes",
          directory_url: "https://dir.example",
          head_hash: head,
          state: "{}"
        })

      {1, _} =
        Arca.Repo.update_all(where(DirectoryHead, identifier: ^orphan),
          set: [verified_at: DateTime.add(Arca.ServerMetaStorage.now!(), -3_600, :second)]
        )
    end)

    # A challenge verifies it again, and holds before its commit.
    refresher =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            {:ok, _} = DirectoryHeads.touch(server(), orphan, head)
            send(test, :refreshed)

            receive do
              :go -> :ok
            end
          end)
        end)
      end)

    assert_receive :refreshed, 5_000

    sweeper =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:sweeper, backend()})
          DirectoryHeads.sweep(server(), 300_000, 100)
        end)
      end)

    assert_receive {:sweeper, sweeping}, 5_000
    if postgres?(), do: LockWait.await_lock_wait!(sweeping, [~s(DELETE FROM "directory_heads")])
    refute Task.yield(sweeper, 300), "the sweep went ahead of a refresh holding the head"

    send(refresher.pid, :go)
    assert {:ok, :ok} = Task.await(refresher, 25_000)
    assert {:ok, 0} = Task.await(sweeper, 25_000)
    assert unboxed(fn -> Arca.Repo.exists?(where(DirectoryHead, identifier: ^orphan)) end)
  end
end
