# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DirectoryHandlesTest do
  @moduledoc """
  The handle registry beside a CYFR's directory: one personal handle per
  account and one account per handle, a claim's nonce spent once per
  account and only by a claim that commits, an expired request refused on
  the database's clock, and only the platform's own actor reading or
  writing.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.DirectoryHandles
  alias Arca.Schemas.DirectoryNonce

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp server, do: Prima.Actor.system()
  defp identifier, do: "per_" <> Prima.Digest.sha256_hex("h-#{System.unique_integer()}")
  defp nonce, do: :crypto.strong_rand_bytes(16)
  defp later, do: DateTime.add(DateTime.utc_now(), 120, :second)

  defp claim(identifier, handle, nonce \\ nonce(), expires_at \\ later()) do
    DirectoryHandles.claim(server(), %{
      identifier: identifier,
      handle: handle,
      nonce: nonce,
      expires_at: expires_at
    })
  end

  defp nonces(identifier),
    do: Arca.Repo.aggregate(from(n in DirectoryNonce, where: n.identifier == ^identifier), :count)

  test "a handle is an account's once, the same claim again exists, and it resolves" do
    alice = identifier()

    assert {:ok, %{handle: "alice", identifier: ^alice}, :created} = claim(alice, "alice")
    assert {:ok, %{handle: "alice", identifier: ^alice}, :exists} = claim(alice, "alice")
    assert {:ok, %{identifier: ^alice}} = DirectoryHandles.get(server(), "alice")
    assert {:error, :not_found} = DirectoryHandles.get(server(), "nobody")
    assert nonces(alice) == 2
  end

  test "another account's handle is taken, and an account holds one handle" do
    alice = identifier()
    bob = identifier()
    {:ok, _row, :created} = claim(alice, "alice")

    assert {:error, :handle_taken} = claim(bob, "alice")
    assert {:error, :has_other_handle} = claim(alice, "alice-two")
    assert {:error, :not_found} = DirectoryHandles.get(server(), "alice-two")

    # Refused claims spend no nonce.
    assert nonces(bob) == 0
    assert nonces(alice) == 1
  end

  test "a nonce is spent once per account, and an expired request claims nothing" do
    alice = identifier()
    spent = nonce()
    {:ok, _row, :created} = claim(alice, "alice", spent)

    assert {:error, :replayed} = claim(alice, "alice", spent)

    # Another account may carry the same bytes.
    assert {:ok, _row, :created} = claim(identifier(), "bob", spent)

    late = identifier()

    assert {:error, :expired} =
             claim(late, "late", nonce(), DateTime.add(DateTime.utc_now(), -1, :second))

    assert {:error, :not_found} = DirectoryHandles.get(server(), "late")
    assert nonces(late) == 0
  end

  test "malformed attributes are refused, and only the platform's own actor reads or writes" do
    assert {:error, {:invalid, errors}} =
             DirectoryHandles.claim(server(), %{
               identifier: "usr_x",
               handle: "Not A Handle",
               nonce: "short",
               expires_at: "soon"
             })

    assert Map.keys(errors) |> Enum.sort() == [:expires_at, :handle, :identifier, :nonce]

    member = Prima.Actor.in_athanor("ath_test")
    assert {:error, :cross_tenant} = DirectoryHandles.get(member, "alice")
    assert {:error, :cross_tenant} = DirectoryHandles.claim(member, %{})
  end
end
