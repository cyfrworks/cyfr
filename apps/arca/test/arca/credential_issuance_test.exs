# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CredentialIssuanceTest do
  @moduledoc """
  A session or a key is written in the issuance transaction
  (`Arca.SecurityTransitions.Issuance`): the rows its standing rests on
  locked and reread, the caller's policy asked over them, the credential
  written only if it agrees.

  Under two real connections, outside the sandbox, an issuance and a
  denial serialize in both orders: an issuance waiting behind a denial
  reads the denial's commit — and the database's own time after the wait
  — and refuses; a denial waiting behind an issuance retires the
  credential the issuance just wrote. On PostgreSQL the waiter blocks on
  the person's row; on SQLite at the lock its transaction takes at entry.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.Schemas.{ApiKey, Athanor, ExternalIdentity, Membership, Session, User}
  alias Arca.SecurityTransitions
  alias Arca.SecurityTransitions.Issuance
  alias Ecto.Adapters.SQL.Sandbox

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Cyfr.Actor.system()
  defp admit, do: fn _rows -> :ok end

  setup do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    user_id = Cyfr.UUID7.generate_id(Cyfr.PersonId.prefix())
    athanor_id = Cyfr.UUID7.generate_id("ath")

    unboxed(fn ->
      {:ok, _} =
        Arca.Users.mint(
          server(),
          %{
            id: user_id,
            provider: "github",
            email: "ci#{n}@example.com",
            email_verified: true,
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          %{
            key: "github|https://github.com|ci#{n}",
            provider: "github",
            issuer: "https://github.com",
            subject: "ci#{n}",
            first_seen_at: now,
            last_seen_at: now
          }
        )

      {:ok, _} =
        Arca.Athanors.insert(server(), %{
          id: athanor_id,
          kind: "group",
          name: "CI #{n}",
          slug: "ci-#{n}",
          created_by: user_id
        })

      {:ok, _} =
        Arca.Members.seat(Cyfr.Actor.in_athanor(athanor_id), %{user_id: user_id, added_by: "x"})
    end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(Membership, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(Membership, user_id: ^user_id))
        Arca.Repo.delete_all(where(Session, user_id: ^user_id))
        Arca.Repo.delete_all(where(ApiKey, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(User, id: ^user_id))
        Arca.Repo.delete_all(where(Athanor, id: ^athanor_id))
      end)
    end)

    {:ok, user_id: user_id, athanor_id: athanor_id}
  end

  defp targets(user_id, athanor_id),
    do: %{user_id: user_id, athanor_id: athanor_id, membership_id: nil, source: nil}

  # The identity domain's policy in miniature: the person and the estate
  # active at the generations the issuing context read (1, at birth).
  defp at_birth(test) do
    fn rows ->
      send(test, {:read, rows})

      if rows.user.status == "active" and rows.user.security_generation == 1 and
           rows.athanor.status == "active" and rows.athanor.security_generation == 1,
         do: :ok,
         else: {:error, :stale_generation}
    end
  end

  defp session_attrs(user_id, athanor_id) do
    %{
      user_id: user_id,
      provider: "github",
      athanor_id: athanor_id,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
  end

  defp key_attrs(user_id, athanor_id) do
    n = System.unique_integer([:positive])

    %{
      name: "ci-key-#{n}",
      key_hash: :crypto.hash(:sha256, "ci-key-#{n}"),
      key_prefix: "cyfr_sk_ci",
      type: "service",
      created_by: user_id,
      athanor_id: athanor_id
    }
  end

  defp paused_denial(user_id) do
    test = self()

    Task.async(fn ->
      unboxed(fn ->
        SecurityTransitions.deny_user(server(), user_id,
          verify: fn _rows ->
            send(test, :denial_holds)

            receive do
              :go -> send(test, {:released_at, Arca.ServerMetaStorage.now!()})
            end

            :ok
          end
        )
      end)
    end)
  end

  defp paused(test, verify) do
    fn rows ->
      send(test, :issuance_holds)

      receive do
        :go -> verify.(rows)
      end
    end
  end

  describe "an issuance waiting behind a denial" do
    test "a session reads the denial's commit and fresh time, and is refused", %{
      user_id: user_id,
      athanor_id: athanor_id
    } do
      test = self()
      denier = paused_denial(user_id)
      assert_receive :denial_holds, 5_000
      hash = :crypto.strong_rand_bytes(32)

      issuer =
        Task.async(fn ->
          unboxed(fn ->
            Arca.SessionStorage.create_session(hash, session_attrs(user_id, athanor_id),
              lock: targets(user_id, athanor_id),
              verify: at_birth(test)
            )
          end)
        end)

      refute Task.yield(issuer, 300), "the issuance decided while the denial held the person"
      send(denier.pid, :go)
      assert {:ok, %{transitioned: true}} = Task.await(denier, 25_000)
      assert_receive {:released_at, released_at}

      assert {:error, :stale_generation} = Task.await(issuer, 25_000)
      assert_receive {:read, rows}
      assert rows.user.status == "denied"
      assert rows.user.security_generation == 2
      assert DateTime.compare(rows.now, released_at) != :lt

      refute unboxed(fn -> Arca.Repo.exists?(where(Session, token_hash: ^hash)) end)
    end

    test "a key reads the denial's commit and is refused", %{
      user_id: user_id,
      athanor_id: athanor_id
    } do
      test = self()

      # The estate stays open: the person is one of two, so the denial
      # leaves the group standing and the refusal is the person's.
      other = Cyfr.UUID7.generate_id(Cyfr.PersonId.prefix())

      unboxed(fn ->
        Arca.Members.seat(Cyfr.Actor.in_athanor(athanor_id), %{user_id: other, added_by: "x"})
      end)

      denier = paused_denial(user_id)
      assert_receive :denial_holds, 5_000
      attrs = key_attrs(user_id, athanor_id)

      issuer =
        Task.async(fn ->
          unboxed(fn ->
            Arca.ApiKeyStorage.create_key(attrs,
              lock: targets(user_id, athanor_id),
              verify: at_birth(test)
            )
          end)
        end)

      refute Task.yield(issuer, 300)
      send(denier.pid, :go)
      assert {:ok, _} = Task.await(denier, 25_000)
      assert {:error, :stale_generation} = Task.await(issuer, 25_000)

      refute unboxed(fn -> Arca.Repo.exists?(where(ApiKey, key_hash: ^attrs.key_hash)) end)
    end

    test "a rotation reads the archive's commit and is refused", %{
      user_id: user_id,
      athanor_id: athanor_id
    } do
      test = self()
      attrs = key_attrs(user_id, athanor_id)

      :ok =
        unboxed(fn ->
          Arca.ApiKeyStorage.create_key(attrs,
            lock: targets(user_id, athanor_id),
            verify: admit()
          )
        end)

      archiver =
        Task.async(fn ->
          unboxed(fn ->
            SecurityTransitions.archive_athanor(server(), athanor_id,
              verify: fn _rows ->
                send(test, :archive_holds)

                receive do
                  :go -> :ok
                end
              end
            )
          end)
        end)

      assert_receive :archive_holds, 5_000

      rotator =
        Task.async(fn ->
          unboxed(fn ->
            Arca.ApiKeyStorage.rotate_key(
              Cyfr.Actor.in_athanor(athanor_id),
              attrs.name,
              :crypto.hash(:sha256, "rotated"),
              "cyfr_sk_rot",
              lock: targets(user_id, athanor_id),
              verify: at_birth(test)
            )
          end)
        end)

      refute Task.yield(rotator, 300)
      send(archiver.pid, :go)
      assert {:ok, %{transitioned: true}} = Task.await(archiver, 25_000)
      assert {:error, :stale_generation} = Task.await(rotator, 25_000)

      assert unboxed(fn ->
               Arca.Repo.one(from(k in ApiKey, where: k.name == ^attrs.name, select: k.revoked))
             end)
    end
  end

  describe "a denial waiting behind an issuance" do
    test "retires the session the issuance wrote", %{user_id: user_id, athanor_id: athanor_id} do
      test = self()
      hash = :crypto.strong_rand_bytes(32)

      issuer =
        Task.async(fn ->
          unboxed(fn ->
            Arca.SessionStorage.create_session(hash, session_attrs(user_id, athanor_id),
              lock: targets(user_id, athanor_id),
              verify: paused(test, at_birth(test))
            )
          end)
        end)

      assert_receive :issuance_holds, 5_000

      denier =
        Task.async(fn ->
          unboxed(fn -> SecurityTransitions.deny_user(server(), user_id, verify: admit()) end)
        end)

      refute Task.yield(denier, 300), "the denial decided while the issuance held the person"
      send(issuer.pid, :go)
      assert :ok = Task.await(issuer, 25_000)

      assert {:ok, change} = Task.await(denier, 25_000)
      assert change.revoked_session_hashes == [hash]
      refute unboxed(fn -> Arca.Repo.exists?(where(Session, token_hash: ^hash)) end)
    end

    test "revokes the key the issuance wrote, and a rotation's new secret with it", %{
      user_id: user_id,
      athanor_id: athanor_id
    } do
      test = self()
      attrs = key_attrs(user_id, athanor_id)

      :ok =
        unboxed(fn ->
          Arca.ApiKeyStorage.create_key(attrs,
            lock: targets(user_id, athanor_id),
            verify: admit()
          )
        end)

      rotated = :crypto.hash(:sha256, "rotated-#{System.unique_integer([:positive])}")

      rotator =
        Task.async(fn ->
          unboxed(fn ->
            Arca.ApiKeyStorage.rotate_key(
              Cyfr.Actor.in_athanor(athanor_id),
              attrs.name,
              rotated,
              "cyfr_sk_rot",
              lock: targets(user_id, athanor_id),
              verify: paused(test, at_birth(test))
            )
          end)
        end)

      assert_receive :issuance_holds, 5_000

      denier =
        Task.async(fn ->
          unboxed(fn -> SecurityTransitions.deny_user(server(), user_id, verify: admit()) end)
        end)

      refute Task.yield(denier, 300)
      send(rotator.pid, :go)
      assert :ok = Task.await(rotator, 25_000)
      assert {:ok, change} = Task.await(denier, 25_000)
      assert length(change.revoked_api_key_ids) == 1

      assert {:ok, %{revoked: true}} =
               unboxed(fn -> Arca.ApiKeyStorage.get_key_by_hash(rotated) end)
    end
  end
end

defmodule Arca.CredentialIssuanceSandboxTest do
  @moduledoc """
  The issuance transaction on one connection: the policy sees the locked
  rows (nil where there is none), and a refusal from it or from the write
  leaves nothing behind.
  """

  use ExUnit.Case, async: false

  alias Arca.SecurityTransitions.Issuance

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  test "the policy is handed nil for rows that do not exist, and its refusal writes nothing" do
    test = self()
    hash = :crypto.strong_rand_bytes(32)

    assert {:error, :not_standing} =
             Arca.SessionStorage.create_session(
               hash,
               %{
                 user_id: "usr_nobody",
                 provider: "github",
                 expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
               },
               lock: %{
                 user_id: "usr_nobody",
                 athanor_id: "ath_nowhere",
                 membership_id: "mem_none",
                 source: {:api_key, "key_none"}
               },
               verify: fn rows ->
                 send(test, {:rows, rows})
                 {:error, :not_standing}
               end
             )

    assert_received {:rows, %{user: nil, athanor: nil, membership: nil, source: source, now: now}}
    assert source == %{kind: :api_key, row: nil}
    assert %DateTime{} = now
    assert {:error, :not_found} = Arca.SessionStorage.get_session(hash)
  end

  test "a refused write rolls the transaction back" do
    assert {:error, :not_this_time} =
             Issuance.run(
               %{user_id: "usr_nobody", athanor_id: nil, membership_id: nil, source: nil},
               fn _rows -> :ok end,
               fn _rows -> {:error, :not_this_time} end
             )
  end
end
