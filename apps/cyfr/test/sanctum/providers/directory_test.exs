# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.DirectoryTest do
  @moduledoc """
  The `directory` tool: `directory.tombstone` is the platform
  administrator's, destructive and on the external plane, takes the
  account's identifier, and marks the account gone at this CYFR's
  directory only under a fresh confirmation naming that identifier.
  """

  # The directory setting is process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Prima.Identity
  alias Prima.Identity.Entry
  alias Sanctum.Providers.Directory

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    Sanctum.Test.Settings.put("directory_serve", "writer")
    {person, _user} = Sanctum.TestContext.person!(Sanctum.TestContext.local())
    %{person: person, identifier: registered!()}
  end

  # An account registered at this CYFR's directory: a genesis naming its
  # origin, signed by a recovery key.
  defp registered! do
    {:ok, directory} = Prima.Identity.Encoding.canonical_home(Sanctum.origin())
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, genesis} =
      Entry.new(
        kind: :genesis,
        seq: 0,
        at: System.os_time(:millisecond),
        signer: Identity.recovery_signer(pub),
        directory: directory,
        recovery: [pub]
      )

    genesis = Identity.sign(genesis, priv)

    {:ok, %{identifier: identifier, result: :created}} =
      Sanctum.Directory.register(%{genesis: Entry.encode(genesis), source: "203.0.113.9"})

    identifier
  end

  defp page(identifier),
    do: Sanctum.Directory.resolve(%{identifier: identifier, after: -1, source: "203.0.113.9"})

  defp tombstone(ctx, identifier),
    do: Directory.handle(ctx, %{"action" => "tombstone", "identifier" => identifier})

  test "is declared the platform administrator's, destructive, taking the account's identifier" do
    assert %{name: "directory", operations: [operation]} = Directory.definition()
    assert operation.action == "tombstone"
    assert operation.scope == :platform
    assert operation.kind == :destructive
    assert operation.planes == [:external]
    assert [%{name: "identifier", type: :string, required: true}] = operation.args
  end

  test "asks a fresh confirmation, and marks nothing without it", %{
    person: person,
    identifier: identifier
  } do
    assert {:error, {:confirmation_required, %{operation: "directory.tombstone"}}} =
             tombstone(person, identifier)

    assert {:ok, %{length: 1}} = page(identifier)
  end

  test "under its confirmation the account is gone to every read and write", %{
    person: person,
    identifier: identifier
  } do
    assert {:ok, %{identifier: ^identifier, gone: true}} =
             Sanctum.TestContext.confirming(person, &tombstone(&1, identifier))

    assert {:error, :gone} = page(identifier)
  end

  describe "the only administrator's account" do
    # A person of this CYFR whose account is `identifier`, marked an
    # administrator when `admin?`.
    defp person_of!(identifier, admin?) do
      {:ok, user} =
        Sanctum.Test.People.remote(
          %{id: "cyfr|dir|" <> identifier, provider: "cyfr"},
          %{
            identifier: identifier,
            directory_url: "https://dir.example",
            head_hash: Prima.Digest.sha256("head-" <> identifier)
          }
        )

      if admin?, do: {:ok, _} = Sanctum.TestContext.ensure_platform(user.id)
      user
    end

    # Every other administrator's mark taken away, so the person made here
    # is the only one.
    defp only_admins!(keep) do
      Arca.Repo.update_all(
        from(u in Arca.Schemas.User,
          where: not is_nil(u.platform_admin_at) and u.id not in ^keep
        ),
        set: [platform_admin_at: nil]
      )
    end

    @only "This is the only administrator of this CYFR. Make someone else an administrator first."

    test "is refused with the sentence, asking nothing and writing nothing at the directory", %{
      person: person,
      identifier: identifier
    } do
      admin = person_of!(identifier, true)
      only_admins!([admin.id])

      assert {:error, {:invalid_argument, @only}} = tombstone(person, identifier)

      assert {:error, {:invalid_argument, @only}} =
               Sanctum.TestContext.confirming(person, &tombstone(&1, identifier))

      assert {:ok, %{length: 1}} = page(identifier)
    end

    test "closes when another administrator stands", %{person: person, identifier: identifier} do
      admin = person_of!(identifier, true)
      other = person_of!("per_" <> String.duplicate("b", 64), true)
      only_admins!([admin.id, other.id])

      assert {:ok, %{gone: true}} =
               Sanctum.TestContext.confirming(person, &tombstone(&1, identifier))

      assert {:error, :gone} = page(identifier)
    end

    test "a person who is not an administrator closes as built", %{
      person: person,
      identifier: identifier
    } do
      _member = person_of!(identifier, false)

      assert {:ok, %{gone: true}} =
               Sanctum.TestContext.confirming(person, &tombstone(&1, identifier))
    end

    @tag :capture_log
    test "a read that cannot tell refuses, and nothing is written", %{
      person: person,
      identifier: identifier
    } do
      _admin = person_of!(identifier, true)

      Arca.Repo.query!("ALTER TABLE users RENAME TO users_unavailable")
      assert {:error, {:unavailable, _}} = tombstone(person, identifier)
      Arca.Repo.query!("ALTER TABLE users_unavailable RENAME TO users")

      assert {:ok, %{length: 1}} = page(identifier)
    end
  end

  test "a malformed identifier asks nothing, and an account the directory never held is not found",
       %{person: person} do
    assert {:error, {:invalid_argument, _}} = tombstone(person, "usr_someone")

    unknown = "per_" <> String.duplicate("a", 64)

    assert {:error, {:not_found, "account", ^unknown}} =
             Sanctum.TestContext.confirming(person, &tombstone(&1, unknown))
  end
end
