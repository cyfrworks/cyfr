# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PairedClientsTest do
  @moduledoc """
  The paired client rows: recorded active, with a known source (a
  device's carrying its public key), once per credential in an athanor,
  and only by a member that owns its slot; listed and revoked in the
  actor's own athanor, with `revoked` terminal, and a device's removed
  until it is allowed again, revoked; revoked by person, across
  athanors only for the platform's own actor. Standing alone decides: no
  row carries a rank. A suspended row, a declared restore's, is listed only
  when its standing is asked for, and re-enabled only from `suspended`,
  under its verifier, by an owner of the slot, closing its person's restore
  and no one else's; a revoked row is never re-enabled.
  """

  # Takes a slot through `Arca.ControlPlane`, which writes the process-wide
  # standing record; each case saves and restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Arca.PairedClients
  alias Arca.Schemas.{CellLease, PairedClient}

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
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

    # A claimant runs, and this member holds its slot.
    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-pcl-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot_a", 60_000)

    athanor = "ath_pcl_#{System.unique_integer([:positive])}"
    {:ok, actor: Prima.Actor.in_athanor(athanor), slot: slot}
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        user_id: "usr_pcl",
        source_kind: "session",
        source_id: "src_#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end

  defp record!(actor, overrides \\ %{}) do
    {:ok, row} = PairedClients.record(actor, attrs(overrides))
    row
  end

  defp suspend!(row) do
    {1, _} =
      Arca.Repo.update_all(from(p in PairedClient, where: p.id == ^row.id),
        set: [standing: "suspended"]
      )

    row
  end

  # A person this home holds, whom a restore row can name.
  defp person! do
    now = DateTime.utc_now()

    {:ok, person} =
      Arca.Test.People.mint(
        Prima.Actor.system(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          provider: "github",
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        }
      )

    person.id
  end

  defp standing(id),
    do: Arca.Repo.one(from(p in PairedClient, where: p.id == ^id, select: p.standing))

  defp allow_again(actor, id, user_id \\ "usr_pcl"),
    do: PairedClients.allow_again(actor, user_id, id, verify: fn _row -> :ok end)

  describe "record/2" do
    test "records an active client in the actor's athanor, as a plain map", %{actor: actor} do
      assert {:ok, row} = PairedClients.record(actor, attrs())
      refute is_struct(row)
      assert "pcl_" <> _ = row.id
      assert row.standing == "active"
      assert row.athanor_id == actor.athanor_id
      assert {:ok, [^row]} = PairedClients.list(actor, [])
    end

    test "a device client carries its key, under the id its invitation reserved", %{actor: actor} do
      device_key = :crypto.strong_rand_bytes(32)
      reserved = Prima.UUID7.generate_id("pcl")

      assert {:ok, row} =
               PairedClients.record(
                 actor,
                 attrs(%{
                   id: reserved,
                   source_kind: "device_cert",
                   device_public_key: device_key
                 })
               )

      assert row.id == reserved
      assert row.device_public_key == device_key

      assert {:error, :conflict} =
               PairedClients.record(
                 actor,
                 attrs(%{id: reserved, source_kind: "device_cert", device_public_key: device_key})
               )

      assert {:error, {:invalid, %{device_public_key: _}}} =
               PairedClients.record(actor, attrs(%{source_kind: "device_cert"}))

      assert {:error, {:invalid, %{device_public_key: _}}} =
               PairedClients.record(actor, attrs(%{device_public_key: device_key}))
    end

    test "every source kind is recorded, and nothing else", %{actor: actor} do
      assert {:ok, _} = PairedClients.record(actor, attrs(%{source_kind: "api_key"}))

      assert {:error, {:invalid, %{source_kind: _}}} =
               PairedClients.record(actor, attrs(%{source_kind: "cookie"}))

      assert {:error, {:invalid, %{source_id: _}}} =
               PairedClients.record(actor, Map.delete(attrs(), :source_id))

      assert {:error, {:invalid, %{user_id: _}}} =
               PairedClients.record(actor, Map.delete(attrs(), :user_id))
    end

    test "one client per credential in an athanor", %{actor: actor} do
      row = record!(actor)
      assert {:error, :conflict} = PairedClients.record(actor, attrs(%{source_id: row.source_id}))

      other = Prima.Actor.in_athanor("ath_pcl_other_#{System.unique_integer([:positive])}")
      assert {:ok, _} = PairedClients.record(other, attrs(%{source_id: row.source_id}))
    end

    test "a stale owner records nothing", %{actor: actor, slot: slot} do
      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} = PairedClients.record(actor, attrs())
      assert Arca.Repo.aggregate(PairedClient, :count) == 0
    end

    test "an actor that names no athanor is refused" do
      assert {:error, :no_athanor} = PairedClients.record(Prima.Actor.system(), attrs())
      assert {:error, :no_athanor} = PairedClients.list(Prima.Actor.system(), [])
      assert {:error, :no_athanor} = PairedClients.revoke(Prima.Actor.system(), "pcl_x")
    end
  end

  describe "a protected device" do
    defp device_attrs(user_id, overrides \\ %{}) do
      attrs(
        Map.merge(
          %{
            user_id: user_id,
            source_kind: "device_cert",
            device_public_key: :crypto.strong_rand_bytes(32),
            holder_kind: "chip",
            display_name: "Kitchen box"
          },
          overrides
        )
      )
    end

    defp identity!(user_id), do: Arca.Test.People.account!(user_id)

    test "records what holds its key and the name it shows, and nothing a browser key reports",
         %{actor: actor} do
      row =
        record!(actor, %{
          source_kind: "device_cert",
          device_public_key: :crypto.strong_rand_bytes(32),
          holder_kind: "software",
          display_name: "Desk"
        })

      assert %{holder_kind: "software", display_name: "Desk"} = row

      for {field, value} <- [
            {:holder_kind, "platform"},
            {:display_name, "a\nb"},
            {:display_name, String.duplicate("x", 65)},
            # 33 characters, 66 bytes: the bound is the hello's, in bytes.
            {:display_name, String.duplicate("é", 33)}
          ] do
        assert {:error, {:invalid, _}} =
                 PairedClients.record(
                   actor,
                   attrs(
                     %{
                       source_kind: "device_cert",
                       device_public_key: :crypto.strong_rand_bytes(32)
                     }
                     |> Map.put(field, value)
                   )
                 ),
               inspect({field, value})
      end

      assert {:error, {:invalid, _}} = PairedClients.record(actor, attrs(%{holder_kind: "chip"}))
    end

    test "an enrollment writes its row and runs its also: step with it", %{actor: actor} do
      user_id = person!()
      identity!(user_id)
      test = self()

      assert {:ok, enrolled} =
               PairedClients.enroll(actor, device_attrs(user_id),
                 also: fn row -> {:ok, send(test, {:also, row.id})} end
               )

      assert enrolled.holder_kind == "chip"
      assert_received {:also, id}
      assert id == enrolled.id
    end

    # The decision is made under the person's lock, from their rows of
    # that key: a second enrollment finds the active row, and a removed one
    # keeps the key out until it is allowed again.
    test "an enrollment of a key the person holds finds its row, and a removed one refuses",
         %{actor: actor} do
      user_id = person!()
      identity!(user_id)
      key = :crypto.strong_rand_bytes(32)
      also = fn row -> {:ok, row} end

      assert {:ok, first} =
               PairedClients.enroll(actor, device_attrs(user_id, %{device_public_key: key}),
                 also: also
               )

      assert {:ok, again} =
               PairedClients.enroll(actor, device_attrs(user_id, %{device_public_key: key}),
                 also: also
               )

      assert again.id == first.id
      assert {:ok, %{standing: "removed"}} = PairedClients.remove(actor, first.id)

      assert {:error, :removed} =
               PairedClients.enroll(actor, device_attrs(user_id, %{device_public_key: key}),
                 also: also
               )

      assert {:ok, _revoked} = allow_again(actor, first.id, user_id)

      assert {:ok, readmitted} =
               PairedClients.enroll(actor, device_attrs(user_id, %{device_public_key: key}),
                 also: also
               )

      assert Arca.Repo.all(
               from(p in PairedClient,
                 where: p.user_id == ^user_id,
                 order_by: [asc: p.inserted_at, asc: p.id],
                 select: {p.id, p.standing}
               )
             ) == [{first.id, "revoked"}, {readmitted.id, "active"}]
    end

    # The store holds the one row a person's device key stands on, active
    # or removed, whichever write reaches it.
    test "the store refuses a second active row of one person's device key", %{actor: actor} do
      key = :crypto.strong_rand_bytes(32)
      first = record!(actor, %{source_kind: "device_cert", device_public_key: key})

      assert {:error, :conflict} =
               PairedClients.record(
                 actor,
                 attrs(%{source_kind: "device_cert", device_public_key: key})
               )

      {:ok, _removed} = PairedClients.remove(actor, first.id)

      assert {:error, :conflict} =
               PairedClients.record(
                 actor,
                 attrs(%{source_kind: "device_cert", device_public_key: key})
               )

      # Another person's key, or another athanor's row, is its own.
      assert {:ok, _theirs} =
               PairedClients.record(
                 actor,
                 attrs(%{
                   user_id: "usr_pcl_other",
                   source_kind: "device_cert",
                   device_public_key: key
                 })
               )
    end

    test "a refusal of its also: step rolls the enrollment back", %{actor: actor} do
      user_id = person!()
      identity!(user_id)

      assert {:error, :not_certified} =
               PairedClients.enroll(actor, device_attrs(user_id),
                 also: fn _row -> {:error, :not_certified} end
               )

      assert Arca.Repo.aggregate(from(p in PairedClient, where: p.user_id == ^user_id), :count) ==
               0
    end

    test "its revocation deletes the sessions its unlock created and answers their hashes", %{
      actor: actor
    } do
      row =
        record!(actor, %{
          source_kind: "device_cert",
          device_public_key: :crypto.strong_rand_bytes(32),
          holder_kind: "chip"
        })

      id = Prima.UUID7.generate_id("ses")
      hash = :crypto.hash(:sha256, "device-session-#{row.id}")

      :ok =
        Arca.SessionStorage.reserve_client_session(id, %{
          client_id: row.id,
          user_id: "usr_pcl",
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
        })

      :ok =
        Arca.SessionStorage.activate_client_session(
          hash,
          %{
            id: id,
            client_id: row.id,
            user_id: "usr_pcl",
            expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
          },
          Arca.Test.Actor.issuance("usr_pcl")
        )

      assert {:ok, %{standing: "revoked", revoked_session_hashes: [^hash]}} =
               PairedClients.revoke(actor, row.id)

      assert {:error, :not_found} = Arca.SessionStorage.get_session(hash)
    end
  end

  describe "a passkey" do
    # The person's account with its head cached here, and what a sign-in
    # by one of its passkeys names.
    defp passkey_sign_in! do
      user_id = person!()
      %{head: head} = Arca.Test.People.account!(user_id)
      %{user_id: user_id, kid: Prima.Digest.sha256("passkey-#{user_id}"), head: head}
    end

    test "is recorded by its key at the cached head, holding no device key, and found again",
         %{actor: actor} do
      signed = passkey_sign_in!()

      assert {:ok, row} = PairedClients.record_passkey(actor, signed)

      assert %{
               source_kind: "passkey",
               standing: "active",
               device_public_key: nil,
               holder_kind: nil,
               display_name: nil
             } = row

      assert {row.athanor_id, row.source_id, row.kid, row.head} ==
               {actor.athanor_id, row.id, signed.kid, signed.head}

      # A second sign-in by the same passkey finds the row that stands.
      assert {:ok, ^row} = PairedClients.record_passkey(actor, signed)

      # One revoked stands for nothing: the next sign-in records a new row.
      {:ok, _revoked} = PairedClients.revoke(actor, row.id)
      assert {:ok, again} = PairedClients.record_passkey(actor, signed)
      refute again.id == row.id
      assert again.standing == "active"
    end

    test "a head the cached head moved past records nothing", %{actor: actor} do
      signed = passkey_sign_in!()
      moved = %{signed | head: Prima.Digest.sha256("an older head")}

      assert {:error, :stale_head} = PairedClients.record_passkey(actor, moved)
      assert Arca.Repo.aggregate(PairedClient, :count) == 0
    end

    test "names its key and head, and the store refuses one without its key or with a device key",
         %{actor: actor} do
      signed = passkey_sign_in!()

      assert {:error, {:invalid, %{kid: _}}} =
               PairedClients.record(
                 actor,
                 attrs(%{user_id: signed.user_id, source_kind: "passkey"})
               )

      base = %{
        id: Prima.UUID7.generate_id("pcl"),
        athanor_id: actor.athanor_id,
        user_id: signed.user_id,
        source_kind: "passkey",
        source_id: "src_passkey",
        kid: signed.kid,
        head: signed.head,
        standing: "active",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      # Each attempt in its own savepoint, so a refused one leaves the
      # test's transaction usable on either adapter.
      refused? = fn row ->
        try do
          Arca.Repo.transaction(fn -> Arca.Repo.insert_all(PairedClient, [row]) end)
          false
        rescue
          _violation -> true
        end
      end

      assert refused?.(%{base | kid: nil, head: nil})
      assert refused?.(Map.put(base, :device_public_key, :crypto.strong_rand_bytes(32)))
      refute refused?.(base)
    end
  end

  describe "list/2" do
    test "narrows by person and by standing, active by default", %{actor: actor} do
      mine = record!(actor)
      theirs = record!(actor, %{user_id: "usr_other"})
      gone = record!(actor)
      {:ok, _} = PairedClients.revoke(actor, gone.id)

      assert {:ok, active} = PairedClients.list(actor, [])
      assert Enum.map(active, & &1.id) |> Enum.sort() == Enum.sort([mine.id, theirs.id])

      assert {:ok, [%{id: id}]} = PairedClients.list(actor, user_id: "usr_other")
      assert id == theirs.id

      assert {:ok, [%{id: revoked_id}]} = PairedClients.list(actor, standing: :revoked)
      assert revoked_id == gone.id
      assert {:ok, all} = PairedClients.list(actor, standing: :all)
      assert length(all) == 3

      other = Prima.Actor.in_athanor("ath_pcl_other_#{System.unique_integer([:positive])}")
      assert {:ok, []} = PairedClients.list(other, [])
    end

    test "a suspended client is listed only when its standing is asked for", %{actor: actor} do
      active = record!(actor)
      suspended = actor |> record!() |> suspend!()

      assert {:ok, [%{id: active_id}]} = PairedClients.list(actor, [])
      assert active_id == active.id
      assert {:ok, [%{id: ^active_id}]} = PairedClients.list(actor, standing: :active)

      assert {:ok, [%{id: suspended_id, standing: "suspended"}]} =
               PairedClients.list(actor, standing: :suspended)

      assert suspended_id == suspended.id
      assert {:ok, all} = PairedClients.list(actor, standing: :all)
      assert Enum.sort(Enum.map(all, & &1.id)) == Enum.sort([active.id, suspended.id])
    end

    test "the platform's own actor reads one named person's clients in every athanor", %{
      actor: actor
    } do
      elsewhere = Prima.Actor.in_athanor("ath_pcl_far_#{System.unique_integer([:positive])}")
      user_id = "usr_pcl_#{System.unique_integer([:positive])}"
      here = record!(actor, %{user_id: user_id})
      there = elsewhere |> record!(%{user_id: user_id}) |> suspend!()
      _bystander = record!(actor, %{user_id: "usr_pcl_bystander"})

      assert {:ok, rows} =
               PairedClients.list(Prima.Actor.system(), user_id: user_id, standing: :all)

      assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort([here.id, there.id])

      assert {:ok, [%{id: there_id}]} =
               PairedClients.list(Prima.Actor.system(), user_id: user_id, standing: :suspended)

      assert there_id == there.id
      assert {:error, :no_athanor} = PairedClients.list(Prima.Actor.system(), standing: :all)
    end
  end

  describe "revocation" do
    test "revoke/2 is terminal, and another athanor's row is not found", %{actor: actor} do
      row = record!(actor)
      other = Prima.Actor.in_athanor("ath_pcl_other")

      assert {:error, :not_found} = PairedClients.revoke(other, row.id)
      assert {:ok, %{standing: "revoked"} = revoked} = PairedClients.revoke(actor, row.id)
      assert {:ok, ^revoked} = PairedClients.revoke(actor, row.id)
      assert {:error, :not_found} = PairedClients.revoke(actor, "pcl_absent")
    end

    test "a suspended client may be revoked, which is terminal", %{actor: actor} do
      row = actor |> record!() |> suspend!()
      assert {:ok, %{standing: "revoked"}} = PairedClients.revoke(actor, row.id)
      assert standing(row.id) == "revoked"
    end

    test "remove/2 removes an active device's row alone, which revoke/2 keeps and allow_again/4 revokes",
         %{actor: actor} do
      device =
        record!(actor, %{
          source_kind: "device_cert",
          device_public_key: :crypto.strong_rand_bytes(32)
        })

      session = record!(actor)
      other = Prima.Actor.in_athanor("ath_pcl_other")

      assert {:error, :not_found} = PairedClients.remove(actor, session.id)
      assert {:error, :not_found} = PairedClients.remove(other, device.id)
      assert {:error, :not_found} = allow_again(actor, device.id)

      assert {:ok, %{standing: "removed", revoked_session_hashes: []}} =
               PairedClients.remove(actor, device.id)

      # A stale id of a row no longer active removes nothing.
      assert {:error, :not_found} = PairedClients.remove(actor, device.id)
      assert {:ok, %{standing: "removed"}} = PairedClients.revoke(actor, device.id)
      assert standing(device.id) == "removed"

      assert {:error, :not_found} = allow_again(other, device.id)
      assert {:error, :not_found} = allow_again(actor, device.id, "usr_pcl_other")
      assert {:ok, %{standing: "revoked"}} = allow_again(actor, device.id)
      assert standing(device.id) == "revoked"
      assert {:error, :not_found} = allow_again(actor, device.id)
      assert {:error, :not_found} = PairedClients.remove(actor, device.id)
      assert standing(session.id) == "active"
    end

    # Allowing a removed device again widens what may be admitted: a
    # member that lost its slot writes nothing and runs no verify, and a
    # verify that refuses rolls the write back.
    test "allow_again/4 runs under the ownership fence, its verify inside the write",
         %{actor: actor, slot: slot} do
      test = self()

      device =
        record!(actor, %{
          source_kind: "device_cert",
          device_public_key: :crypto.strong_rand_bytes(32)
        })

      {:ok, _removed} = PairedClients.remove(actor, device.id)

      assert {:error, :refused} =
               PairedClients.allow_again(actor, "usr_pcl", device.id,
                 verify: fn row ->
                   send(test, {:verified, row.id})
                   {:error, :refused}
                 end
               )

      assert_received {:verified, id}
      assert id == device.id
      assert standing(device.id) == "removed"

      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} =
               PairedClients.allow_again(actor, "usr_pcl", device.id,
                 verify: fn row ->
                   send(test, {:verified, row.id})
                   :ok
                 end
               )

      refute_received {:verified, _id}
      assert standing(device.id) == "removed"
    end

    test "a member that lost its slot may still revoke", %{actor: actor, slot: slot} do
      row = record!(actor)

      {1, _} =
        Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
          set: [owner: "someone-else", generation: slot.generation + 1]
        )

      assert {:ok, %{standing: "revoked"}} = PairedClients.revoke(actor, row.id)
    end
  end
end

defmodule Arca.PairedClientsRaceTest do
  @moduledoc """
  Two first enrollments of one person's device key, on two real
  connections outside the sandbox: the second waits on the person's lock
  the first holds, then decides under it from the row the first wrote, so
  the key stands on one client. On PostgreSQL the waiter blocks on the
  person's row; on SQLite at the lock its transaction takes at entry.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.{ControlPlane, PairedClients}
  alias Arca.Schemas.{CellLease, PairedClient, User}
  alias Arca.Test.LockWait
  alias Ecto.Adapters.SQL.Sandbox

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    hold_slot!()
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    actor = Prima.Actor.in_athanor("ath_pcl_race_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(PairedClient, user_id: ^user_id))
        Arca.Repo.delete_all(where(User, id: ^user_id))
      end)
    end)

    unboxed(fn ->
      {:ok, _} =
        Arca.Test.People.mint(Prima.Actor.system(), %{
          id: user_id,
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        })
    end)

    {:ok, user_id: user_id, actor: actor}
  end

  # This member's slot, taken on a real connection so every connection
  # reads the lease; given back after the case.
  defp hold_slot! do
    saved = Map.new(@slot_keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)
    node = "node-pcl-race-#{System.unique_integer([:positive])}"

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
    {:ok, _slot} = unboxed(fn -> ControlPlane.take(node, node <> "#boot", 60_000) end)
  end

  defp backend do
    if postgres?(), do: hd(hd(Arca.Repo.query!("SELECT pg_backend_pid()").rows))
  end

  defp attrs(user_id, key) do
    id = Prima.UUID7.generate_id("pcl")

    %{
      id: id,
      user_id: user_id,
      source_kind: "device_cert",
      source_id: id,
      device_public_key: key
    }
  end

  test "two first enrollments of one key at once stand on one client",
       %{user_id: user_id, actor: actor} do
    test = self()
    key = :crypto.strong_rand_bytes(32)

    first =
      Task.async(fn ->
        unboxed(fn ->
          # The enrollment holds the person's lock, its row written and not
          # committed, until the test lets it go.
          PairedClients.enroll(actor, attrs(user_id, key),
            also: fn row ->
              send(test, {:enrolling, row.id})

              receive do
                :go -> {:ok, row}
              end
            end
          )
        end)
      end)

    assert_receive {:enrolling, first_id}, 5_000

    second =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:second, backend()})
          PairedClients.enroll(actor, attrs(user_id, key), also: fn row -> {:ok, row} end)
        end)
      end)

    assert_receive {:second, waiting}, 5_000
    if postgres?(), do: LockWait.await_lock_wait!(waiting, [~s("users"), "FOR UPDATE"])

    send(first.pid, :go)
    assert {:ok, %{id: ^first_id}} = Task.await(first, 25_000)
    assert {:ok, %{id: ^first_id}} = Task.await(second, 25_000)

    assert unboxed(fn ->
             Arca.Repo.all(
               from(p in PairedClient, where: p.user_id == ^user_id, select: {p.id, p.standing})
             )
           end) == [{first_id, "active"}]
  end
end
