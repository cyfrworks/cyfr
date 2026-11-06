# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PasskeysTest do
  @moduledoc """
  The passkeys of a person's account that signed in here, known by the
  key each signed with from the sessions it minted: listed per key, and
  signed out here by ending that key's sessions alone, leaving the
  person's other passkeys, their devices' sessions and other people's
  sessions standing.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.Session
  alias Sanctum.{Context, Passkeys}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp person! do
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())

    {:ok, _person} =
      Arca.Test.People.mint(
        Prima.Actor.system(),
        %{id: user_id, first_seen_at: now, last_seen_at: now, created_at: now, updated_at: now},
        nil
      )

    %{head: head} = Arca.Test.People.account!(user_id)
    %{id: user_id, head: head}
  end

  defp session!(person, provider, kid) do
    hash = :crypto.strong_rand_bytes(32)

    :ok =
      Arca.SessionStorage.create_session(
        hash,
        %{
          user_id: person.id,
          provider: provider,
          kid: kid,
          head: kid && person.head,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        lock: %{user_id: person.id, athanor_id: nil, source: nil},
        verify: fn _rows -> :ok end
      )

    hash
  end

  defp ctx(person),
    do:
      Context.build(
        user_id: person.id,
        auth_method: :oidc,
        authenticated: true,
        permissions: Context.person_permissions()
      )

  defp kid(seed), do: Prima.Digest.sha256("#{seed}-#{System.unique_integer()}")

  defp hashes(person),
    do: Arca.Repo.all(from(s in Session, where: s.user_id == ^person.id, select: s.token_hash))

  test "lists each passkey that signed in here once, with its sessions" do
    person = person!()
    phone = kid("phone")
    laptop = kid("laptop")
    session!(person, "passkey", phone)
    session!(person, "passkey", phone)
    session!(person, "passkey", laptop)
    session!(person, "device", kid("terminal"))
    session!(person, "passkey", nil)

    assert {:ok, listed} = Passkeys.list(ctx(person))

    assert Enum.sort(Enum.map(listed, &{&1.kid, &1.sessions})) ==
             Enum.sort([{phone, 2}, {laptop, 1}])
  end

  test "revoking a passkey ends its sessions here alone" do
    person = person!()
    other = person!()
    phone = kid("phone")
    ended = [session!(person, "passkey", phone), session!(person, "passkey", phone)]
    kept = session!(person, "passkey", kid("laptop"))
    device = session!(person, "device", kid("terminal"))
    theirs = session!(other, "passkey", phone)

    assert {:ok, %{kid: ^phone, sessions: 2}} = Passkeys.revoke(ctx(person), phone)
    assert Enum.sort(hashes(person)) == Enum.sort([kept, device])
    assert hashes(other) == [theirs]
    refute Enum.any?(ended, &(&1 in hashes(person)))

    assert {:error, {:not_found, "passkey", ^phone}} = Passkeys.revoke(ctx(person), phone)
  end

  test "only a person signed in reads or revokes" do
    person = person!()
    anonymous = %{ctx(person) | authenticated: false}

    assert {:error, :unauthenticated} = Passkeys.list(anonymous)
    assert {:error, :unauthenticated} = Passkeys.revoke(%{ctx(person) | plane: :guest}, kid("x"))
  end
end
