# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.NewcomerTest do
  @moduledoc """
  A person is made here only by an admission of an account by its
  identifier (`Sanctum.Newcomer.admit/2`), with the account's identity
  row (identifier, directory, head, no key) and an athanor in one
  transaction. Setup makes the installation's first person, its platform
  administrator, writes their identifier's allow, and then opens nothing.
  An invitation admits without the door's allow rule, unless a deny names
  the identifier, redeeming the invitation and writing the identifier's
  allow in the admission's transaction. The open door admits an
  identifier `*` or an allow names. An admission onto an empty
  installation other than setup is refused; an identifier already a
  person here is a conflict.
  """

  # The setup token and the directory seam are process-wide.
  use ExUnit.Case, async: false

  alias Arca.Schemas.{Invitation, PersonIdentity, User}
  alias Sanctum.Door.Store
  alias Sanctum.Newcomer
  alias Sanctum.Test.DirectoryServer

  @token String.duplicate("5e", 32)

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup %{tls: tls} = tags do
    Arca.Test.Sandbox.setup!(tags)
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    dir = DirectoryServer.start!(tls)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)

    # The installation holds no person inside this test's transaction.
    Arca.Repo.delete_all(User)
    %{dir: dir}
  end

  # An account at the scripted directory, its head read and cached here as
  # the caller's verification leaves it.
  defp account!(dir) do
    account = DirectoryServer.account!(dir.dir, dir.url)
    head = DirectoryServer.cached!(account)
    %{identifier: account.identifier, directory_url: dir.url, head_hash: head.head_hash}
  end

  defp people, do: Arca.Repo.aggregate(User, :count)

  defp first!(dir) do
    account = account!(dir)
    {:ok, %{person: person}} = Newcomer.admit({:setup, @token}, account)
    {person, account}
  end

  describe "setup" do
    test "makes the first person, their account's row, athanor and allow, and then opens nothing",
         %{dir: dir} do
      assert :ok = Newcomer.setup_open(@token)
      {person, account} = first!(dir)

      assert person.admission == "setup"
      assert person.platform_admin_at
      identifier = account.identifier

      assert %{provenance: "remote", identifier: ^identifier, live_public_key: nil} =
               Arca.Repo.get_by!(PersonIdentity, user_id: person.id)

      assert {:ok, %{owner_user_id: owner}} = Sanctum.Tenancy.Athanors.get_by_owner(person.id)
      assert owner == person.id
      assert {:ok, true} = Store.allowed("identifier", identifier)

      assert {:error, :setup_closed} = Newcomer.setup_open(@token)
      assert {:error, :setup_closed} = Newcomer.admit({:setup, @token}, account!(dir))
      assert people() == 1
    end

    test "a token that is not the configured one, or none configured, opens nothing", %{
      dir: dir
    } do
      assert {:error, :setup_closed} =
               Newcomer.admit({:setup, String.duplicate("00", 32)}, account!(dir))

      assert {:error, :setup_closed} = Newcomer.setup_open("short")
      Prima.Test.Env.put_app_env(:sanctum, :setup_token, nil)
      assert {:error, :setup_closed} = Newcomer.admit({:setup, @token}, account!(dir))
      refute Newcomer.setup_token?(@token)
      assert people() == 0
    end
  end

  describe "the open door" do
    test "admits nobody onto an empty installation", %{dir: dir} do
      {:ok, _} = Store.allow("wildcard", "*", nil)
      assert {:error, :not_set_up} = Newcomer.admit(:open, account!(dir))
      assert people() == 0
    end

    test "admits an identifier * or an allow names, and a deny wins", %{dir: dir} do
      {first, _account} = first!(dir)

      stranger = account!(dir)
      assert {:error, {:door, :not_allowed}} = Newcomer.admit(:open, stranger)

      {:ok, _} = Store.allow("identifier", stranger.identifier, first.id)
      assert {:ok, %{person: %{admission: "open"}}} = Newcomer.admit(:open, stranger)

      denied = account!(dir)
      {:ok, _} = Store.allow("wildcard", "*", first.id)
      {:ok, _} = Store.deny("identifier", denied.identifier, first.id)
      assert {:error, {:door, :denied}} = Newcomer.admit(:open, denied)
    end

    test "an identifier already a person here is a conflict", %{dir: dir} do
      {first, account} = first!(dir)
      {:ok, _} = Store.allow("wildcard", "*", first.id)

      assert {:error, :conflict} = Newcomer.admit(:open, account)
      assert people() == 1
    end
  end

  describe "an invitation" do
    setup %{dir: dir} do
      {first, _account} = first!(dir)
      ctx = Sanctum.TestContext.session!(first.id) |> Map.put(:platform_admin, true)
      {:ok, %{invitation: invitation, code: code}} = Sanctum.Invitations.create(ctx, nil)
      {:ok, hash} = Sanctum.Invitations.code_hash(code)
      %{first: first, invitation: invitation, hash: hash}
    end

    test "admits by its hash without the door, redeems it once and allows the identifier", %{
      dir: dir,
      invitation: invitation,
      hash: hash
    } do
      account = account!(dir)

      assert {:ok, %{person: %{admission: "invitation", id: user_id}}} =
               Newcomer.admit({:invitation, hash}, account)

      assert %{redeemed_by: ^user_id} = Arca.Repo.get!(Invitation, invitation.id)
      assert {:ok, true} = Store.allowed("identifier", account.identifier)

      assert {:error, :invitation_invalid} = Newcomer.admit({:invitation, hash}, account!(dir))
    end

    test "a deny of the identifier wins, and leaves the invitation unspent", %{
      dir: dir,
      first: first,
      invitation: invitation,
      hash: hash
    } do
      account = account!(dir)
      {:ok, _} = Store.deny("identifier", account.identifier, first.id)

      assert {:error, {:door, :denied}} = Newcomer.admit({:invitation, hash}, account)
      assert %{redeemed_by: nil} = Arca.Repo.get!(Invitation, invitation.id)
      assert people() == 1
    end

    test "a hash that names no invitation admits no one", %{dir: dir} do
      assert {:error, :invitation_invalid} =
               Newcomer.admit({:invitation, String.duplicate("0", 64)}, account!(dir))

      assert {:error, :invitation_invalid} = Newcomer.admit({:invitation, nil}, account!(dir))
    end
  end

  test "an account that does not read admits no one" do
    for account <- [
          %{identifier: "per_x", directory_url: "https://dir.example", head_hash: "sha256:x"},
          :none,
          %{}
        ] do
      assert {:error, {:invalid_argument, _}} = Newcomer.admit({:setup, @token}, account)
    end

    assert people() == 0
  end
end
