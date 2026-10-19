# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CliSignInsTest do
  @moduledoc """
  A command line's pending sign-ins (`Arca.CliSignIns`) and the sessions
  their approvals mint (`Arca.SessionStorage`'s command-line rows): opened
  by their secrets' hashes, approved once inside the transaction that
  inserts the session and only while pending and unexpired, cancelled by
  the command line with the session an approval minted ended with it, and
  swept past their expiry. A command line's session is listed and deleted
  by its person, and a browser's never is.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{CliSignIns, SessionStorage}
  alias Arca.Schemas.CliSignIn

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp hash(label), do: :crypto.hash(:sha256, "#{label}-#{System.unique_integer([:positive])}")

  defp open!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          approval_hash: hash("approval"),
          token_hash: hash("token"),
          token_prefix: "tokenpre",
          user_code: "K7QM-3XRD",
          machine: "laptop",
          lifetime_ms: 300_000
        },
        overrides
      )

    {:ok, opened} = CliSignIns.open(attrs)
    Map.merge(attrs, opened)
  end

  defp session!(token_hash, user_id, machine) do
    attrs = %{
      user_id: user_id,
      email: "#{user_id}@example.com",
      provider: "github",
      cli_machine: machine,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      token_prefix: "tokenpre"
    }

    :ok = SessionStorage.create_session(token_hash, attrs, Arca.Test.Actor.issuance())
  end

  # The approval as the session's issuance runs it: in one transaction
  # with the session it approves.
  defp approve(sign_in, user_id) do
    Arca.Repo.locking_transaction(fn ->
      session!(sign_in.token_hash, user_id, sign_in.machine)

      sign_in.approval_hash
      |> CliSignIns.approve!(sign_in.token_hash)
      |> case do
        :ok -> :ok
        {:error, reason} -> Arca.Repo.rollback(reason)
      end
    end)
  end

  defp state(sign_in), do: Arca.Repo.get!(CliSignIn, sign_in.id).state

  test "a sign-in is stored by its secrets' hashes and read by either" do
    sign_in = open!()

    assert %{id: "csi_" <> _, user_code: "K7QM-3XRD", machine: "laptop"} = sign_in
    assert DateTime.compare(sign_in.expires_at, DateTime.utc_now()) == :gt

    assert {:ok, by_approval} = CliSignIns.by_approval(sign_in.approval_hash)
    assert {:ok, ^by_approval} = CliSignIns.by_token(sign_in.token_hash)
    assert by_approval.state == "pending"
    assert by_approval.token_hash == sign_in.token_hash

    assert {:error, :not_found} = CliSignIns.by_approval(hash("other"))
    assert {:error, :not_found} = CliSignIns.by_token(hash("other"))

    # A hash another row holds opens nothing.
    assert {:error, :conflict} =
             CliSignIns.open(%{
               approval_hash: sign_in.approval_hash,
               token_hash: hash("token"),
               token_prefix: "x",
               user_code: "AAAA-AAAA",
               machine: "m",
               lifetime_ms: 1_000
             })
  end

  describe "approve!/2, in the session's transaction" do
    test "approves a pending sign-in once, and the session commits with it" do
      sign_in = open!()

      assert {:ok, :ok} = approve(sign_in, "user_cli_1")
      assert state(sign_in) == "approved"
      assert {:ok, %{cli_machine: "laptop"}} = SessionStorage.get_session(sign_in.token_hash)

      # A second approval rolls its own session back.
      assert {:error, :approved} =
               Arca.Repo.locking_transaction(fn ->
                 CliSignIns.approve!(sign_in.approval_hash, sign_in.token_hash)
               end)
               |> then(fn {:ok, answer} -> answer end)
    end

    test "an expired, a cancelled or another token's sign-in rolls the session back" do
      expired = open!()
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      {1, _} =
        Arca.Repo.update_all(from(c in CliSignIn, where: c.id == ^expired.id),
          set: [expires_at: past]
        )

      assert {:error, :expired} = approve(expired, "user_cli_2")
      assert state(expired) == "pending"
      assert {:error, :not_found} = SessionStorage.get_session(expired.token_hash)

      cancelled = open!()
      assert {:ok, %{state: "pending", ended: nil}} = CliSignIns.cancel(cancelled.token_hash)
      assert {:error, :cancelled} = approve(cancelled, "user_cli_2")
      assert {:error, :not_found} = SessionStorage.get_session(cancelled.token_hash)

      mismatched = open!()

      assert {:error, :not_found} =
               approve(%{mismatched | token_hash: hash("token")}, "user_cli_2")

      assert state(mismatched) == "pending"
    end
  end

  describe "cancel/1" do
    test "cancels a pending sign-in, and ends the session an approval minted first" do
      pending = open!()
      assert {:ok, %{state: "pending", ended: nil}} = CliSignIns.cancel(pending.token_hash)
      assert state(pending) == "cancelled"
      assert {:ok, %{state: "cancelled", ended: nil}} = CliSignIns.cancel(pending.token_hash)

      approved = open!()
      {:ok, :ok} = approve(approved, "user_cli_3")

      assert {:ok, %{state: "approved", ended: "user_cli_3"}} =
               CliSignIns.cancel(approved.token_hash)

      assert state(approved) == "cancelled"
      assert {:error, :not_found} = SessionStorage.get_session(approved.token_hash)

      assert {:error, :not_found} = CliSignIns.cancel(hash("nobody"))
    end
  end

  test "sweep/0 deletes what is long past its expiry and keeps the rest" do
    old = open!()
    fresh = open!()
    long_ago = DateTime.add(DateTime.utc_now(), -3_600, :second)

    {1, _} =
      Arca.Repo.update_all(from(c in CliSignIn, where: c.id == ^old.id),
        set: [expires_at: long_ago]
      )

    assert {:ok, count} = CliSignIns.sweep()
    assert count >= 1
    assert {:error, :not_found} = CliSignIns.by_token(old.token_hash)
    assert {:ok, _kept} = CliSignIns.by_token(fresh.token_hash)
  end

  describe "a command line's sessions" do
    test "are listed for their person alone, a browser's session never" do
      session!(hash("cli"), "user_cli_4", "desk")
      session!(hash("cli"), "user_cli_4", "build box")
      session!(hash("browser"), "user_cli_4", nil)
      session!(hash("cli"), "user_cli_5", "theirs")

      assert {:ok, listed} = SessionStorage.list_command_lines("user_cli_4")
      assert Enum.map(listed, & &1.cli_machine) == ["desk", "build box"]
      assert Enum.all?(listed, &match?(%{id: "ses_" <> _}, &1))
      refute Enum.any?(listed, &Map.has_key?(&1, :token_hash))
    end

    test "are deleted by their person alone, answering the token's hash" do
      mine = hash("cli")
      session!(mine, "user_cli_6", "desk")
      browser = hash("browser")
      session!(browser, "user_cli_6", nil)

      {:ok, %{id: mine_id}} = SessionStorage.get_session(mine)
      {:ok, %{id: browser_id}} = SessionStorage.get_session(browser)

      assert {:error, :not_found} = SessionStorage.delete_command_line("user_cli_7", mine_id)
      assert {:error, :not_found} = SessionStorage.delete_command_line("user_cli_6", browser_id)
      assert {:ok, ^mine} = SessionStorage.delete_command_line("user_cli_6", mine_id)
      assert {:error, :not_found} = SessionStorage.get_session(mine)
      assert {:ok, _} = SessionStorage.get_session(browser)
    end
  end
end
