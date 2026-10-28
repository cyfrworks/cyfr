# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CompanyLoginAttemptsTest do
  @moduledoc """
  Company sign-ins in flight: opened by the platform's actor alone, one
  per person, a new one deleting the person's earlier ones; consumed once,
  for the hash of its state and the session that opened it, while
  unconsumed and unexpired, so a replay, a late callback and another
  session's find nothing alike; and gone with the person.
  """

  use ExUnit.Case, async: true

  import Ecto.Query, only: [from: 2]

  alias Arca.CompanyLoginAttempts
  alias Arca.Schemas.{CompanyLoginAttempt, User}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp server, do: Prima.Actor.system()
  defp hash, do: :crypto.strong_rand_bytes(32)

  defp person! do
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
        nil
      )

    person.id
  end

  defp open!(user_id, session_hash \\ hash()) do
    state_hash = hash()

    {:ok, opened} =
      CompanyLoginAttempts.open(server(), %{
        user_id: user_id,
        session_hash: session_hash,
        state_hash: state_hash,
        nonce: "nonce",
        pkce_verifier: "verifier",
        lifetime_ms: 600_000
      })

    %{
      id: opened.id,
      expires_at: opened.expires_at,
      state_hash: state_hash,
      session_hash: session_hash
    }
  end

  defp attempts(user_id),
    do: Arca.Repo.all(from(a in CompanyLoginAttempt, where: a.user_id == ^user_id))

  test "opens for the platform's actor alone, ten minutes out, and replaces the person's earlier attempt" do
    user_id = person!()

    assert {:error, :cross_tenant} =
             CompanyLoginAttempts.open(%Prima.Actor{user_id: user_id}, %{
               user_id: user_id,
               lifetime_ms: 600_000
             })

    first = open!(user_id)
    assert DateTime.diff(first.expires_at, DateTime.utc_now(), :second) in 595..600

    second = open!(user_id)
    assert [%{id: id, consumed_at: nil}] = attempts(user_id)
    assert id == second.id
  end

  test "is consumed once, by its state and its session, and answers what the exchange needs" do
    user_id = person!()
    attempt = open!(user_id)

    assert {:ok, %{id: id, user_id: ^user_id, nonce: "nonce", pkce_verifier: "verifier"} = row} =
             CompanyLoginAttempts.consume(server(), attempt.state_hash, attempt.session_hash)

    assert id == attempt.id
    assert row.session_hash == attempt.session_hash

    assert {:error, :not_found} =
             CompanyLoginAttempts.consume(server(), attempt.state_hash, attempt.session_hash)

    assert [%{consumed_at: %DateTime{}}] = attempts(user_id)
  end

  test "another state, another session or a passed expiry finds nothing, and leaves the attempt as it was" do
    user_id = person!()
    attempt = open!(user_id)

    assert {:error, :not_found} =
             CompanyLoginAttempts.consume(server(), hash(), attempt.session_hash)

    assert {:error, :not_found} =
             CompanyLoginAttempts.consume(server(), attempt.state_hash, hash())

    past = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      Arca.Repo.update_all(from(a in CompanyLoginAttempt, where: a.id == ^attempt.id),
        set: [expires_at: past]
      )

    assert {:error, :not_found} =
             CompanyLoginAttempts.consume(server(), attempt.state_hash, attempt.session_hash)

    assert [%{consumed_at: nil}] = attempts(user_id)
  end

  test "only the platform's actor consumes" do
    user_id = person!()
    attempt = open!(user_id)

    assert {:error, :cross_tenant} =
             CompanyLoginAttempts.consume(
               %Prima.Actor{user_id: user_id},
               attempt.state_hash,
               attempt.session_hash
             )
  end

  test "goes with the person's users row" do
    user_id = person!()
    open!(user_id)
    {1, _} = Arca.Repo.delete_all(from(u in User, where: u.id == ^user_id))
    assert attempts(user_id) == []
  end
end
