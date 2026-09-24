# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CredentialBindingsTest do
  @moduledoc """
  The rows a derived credential names, read under lock: the caller's
  policy is handed plain maps of the person, the estate, the membership
  and the source credential — nil where there is none — with the
  database's own time, and its answer is the check's. Only the identity
  domain calls it.
  """

  use ExUnit.Case, async: false

  alias Arca.CredentialBindings

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp server, do: Prima.Actor.system()

  test "the policy sees each named row, nil for what does not exist, and the time" do
    test = self()
    hash = :crypto.strong_rand_bytes(32)

    :ok =
      Arca.SessionStorage.create_session(
        hash,
        %{
          user_id: "usr_bound",
          provider: "github",
          athanor_id: "ath_test",
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
        },
        Arca.Test.Actor.issuance("usr_bound")
      )

    assert {:ok, :seen} =
             CredentialBindings.check(
               server(),
               %{
                 user_id: "usr_bound",
                 athanor_id: Arca.Test.Actor.athanor!().id,
                 membership_id: "mem_none",
                 source: {:session, hash}
               },
               verify: fn rows ->
                 send(test, {:rows, rows})
                 {:ok, :seen}
               end
             )

    assert_received {:rows, rows}
    assert rows.user == nil
    assert rows.athanor.id == "ath_test"
    assert rows.membership == nil
    assert %{kind: :session, row: %{user_id: "usr_bound"}} = rows.source
    refute Map.has_key?(rows.source.row, :token_hash)
    assert %DateTime{} = rows.now
  end

  test "the policy's refusal is the answer, and a plain :ok passes through" do
    binding = %{user_id: "usr_x", athanor_id: "ath_test", membership_id: nil, source: nil}

    assert {:error, :not_standing} =
             CredentialBindings.check(server(), binding,
               verify: fn _rows -> {:error, :not_standing} end
             )

    assert :ok = CredentialBindings.check(server(), binding, verify: fn _rows -> :ok end)
  end

  test "an actor other than the server's own is refused before any read" do
    assert {:error, :cross_tenant} =
             CredentialBindings.check(
               Prima.Actor.in_athanor("ath_test"),
               %{user_id: "usr_x", athanor_id: "ath_test", membership_id: nil, source: nil},
               verify: fn _rows -> flunk("read under a tenant actor") end
             )
  end

  test "only the identity domain names the check" do
    root = Path.expand("../../../..", __DIR__)

    callers =
      for path <- Prima.Test.SourceTree.files!(Path.join(root, "apps/*/lib/**/*.ex")),
          rel = Path.relative_to(path, root),
          not String.starts_with?(rel, "apps/arca/lib/"),
          not String.starts_with?(rel, "apps/sanctum/lib/"),
          line <- path |> Prima.Test.SourceTree.read() |> Prima.Test.CodeLines.lines(),
          line =~ ~r/\bArca\.CredentialBindings\b/,
          do: rel

    assert callers == []
  end
end

defmodule Arca.CredentialBindingsLockTest do
  @moduledoc """
  A check waiting behind a denial, on two real connections outside the
  sandbox, reads what the denial committed — on PostgreSQL by waiting on
  the person's row, on SQLite at the lock its transaction takes at entry — with the database's time
  read after the wait.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.Schemas.{Athanor, ExternalIdentity, Membership, Session, User}
  alias Ecto.Adapters.SQL.Sandbox

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()

  setup do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    athanor_id = Prima.UUID7.generate_id("ath")

    unboxed(fn ->
      {:ok, _} =
        Arca.Users.mint(
          server(),
          %{
            id: user_id,
            provider: "github",
            email: "cb#{n}@example.com",
            email_verified: true,
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          %{
            key: "github|https://github.com|cb#{n}",
            provider: "github",
            issuer: "https://github.com",
            subject: "cb#{n}",
            first_seen_at: now,
            last_seen_at: now
          }
        )

      {:ok, _} =
        Arca.Athanors.insert(server(), %{
          id: athanor_id,
          kind: "group",
          name: "CB #{n}",
          slug: "cb-#{n}",
          created_by: user_id
        })
    end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(Membership, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(Session, user_id: ^user_id))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(User, id: ^user_id))
        Arca.Repo.delete_all(where(Athanor, id: ^athanor_id))
      end)
    end)

    {:ok, user_id: user_id, athanor_id: athanor_id}
  end

  test "a check waiting behind a denial reads the denial's commit", %{
    user_id: user_id,
    athanor_id: athanor_id
  } do
    test = self()

    {:ok, seat} =
      unboxed(fn ->
        Arca.Members.seat(Prima.Actor.in_athanor(athanor_id), %{user_id: user_id, added_by: "x"})
      end)

    denier =
      Task.async(fn ->
        unboxed(fn ->
          Arca.SecurityTransitions.deny_user(server(), user_id,
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

    assert_receive :denial_holds, 5_000

    checker =
      Task.async(fn ->
        unboxed(fn ->
          Arca.CredentialBindings.check(
            server(),
            %{user_id: user_id, athanor_id: athanor_id, membership_id: seat.id, source: nil},
            verify: fn rows -> {:ok, rows} end
          )
        end)
      end)

    refute Task.yield(checker, 300), "the check read while the denial held the person"
    send(denier.pid, :go)
    assert {:ok, %{transitioned: true}} = Task.await(denier, 25_000)
    assert_receive {:released_at, released_at}

    assert {:ok, rows} = Task.await(checker, 25_000)
    assert rows.user.status == "denied"
    assert rows.user.security_generation == 2
    assert rows.athanor.status == "archived"
    assert rows.membership == nil
    assert DateTime.compare(rows.now, released_at) != :lt
  end
end
