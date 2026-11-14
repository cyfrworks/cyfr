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
  alias Sanctum.Test.{DirectoryServer, RegistryStub}

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

      assert %{identifier: ^identifier} =
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

  describe "the account's name" do
    # The registry names each account; `:close` drops the lookup unanswered.
    defp named!(names, dir), do: RegistryStub.handles!(names, dir.url)

    defp slug(user_id) do
      {:ok, athanor} = Sanctum.Tenancy.Athanors.get_by_owner(user_id)
      {athanor.slug, athanor.name}
    end

    defp entry(identifier) do
      Enum.find(Store.list(), &(&1.value == identifier))
    end

    test "is the person's namespace, their athanor's slug and name, and labels setup's allow",
         %{dir: dir} do
      account = account!(dir)
      named!(%{"mira" => account.identifier}, dir)

      {:ok, %{person: person}} = Newcomer.admit({:setup, @token}, account)

      assert %{namespace: "mira"} = person
      assert slug(person.id) == {"mira", "mira"}

      assert %{effect: "allow", status: "allowed", label: "mira", note: "setup"} =
               entry(account.identifier)

      assert_received {:registry_request, %{path: "/v1/identities/" <> rest}}
      assert rest == account.identifier <> "/handle"
    end

    test "labels an invitation's allow, and the request a refusal at the open door leaves",
         %{dir: dir} do
      {first, _account} = first!(dir)
      invited = account!(dir)
      refused = account!(dir)
      named!(%{"oren" => invited.identifier, "wren" => refused.identifier}, dir)

      ctx = Sanctum.TestContext.session!(first.id) |> Map.put(:platform_admin, true)
      {:ok, %{code: code}} = Sanctum.Invitations.create(ctx, nil)
      {:ok, hash} = Sanctum.Invitations.code_hash(code)

      {:ok, %{person: oren}} = Newcomer.admit({:invitation, hash}, invited)
      assert %{namespace: "oren"} = oren
      assert slug(oren.id) == {"oren", "oren"}
      assert %{effect: "allow", status: "allowed", label: "oren"} = entry(invited.identifier)

      assert {:error, {:door, :not_allowed}} = Newcomer.admit(:open, refused)

      assert [
               %{
                 value: value,
                 status: "requested",
                 requested_by: value,
                 note: "refused at sign-in",
                 label: "wren"
               }
             ] = Store.requests()

      assert value == refused.identifier
    end

    test "a lookup that fails, a name the account lacks, or a name a person here holds admits the person unnamed",
         %{dir: dir} do
      {first, _account} = first!(dir)
      {:ok, _} = Store.allow("wildcard", "*", first.id)
      {:ok, holder} = Sanctum.Tenancy.Users.get(first.id)
      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(holder, "held")

      lost = account!(dir)
      unheld = account!(dir)
      twice = account!(dir)

      # The registry drops `lost`'s lookup unanswered, names `twice` by the
      # name the first person holds here, and names `unheld` by none.
      RegistryStub.start!(fn %{path: "/v1/identities/" <> rest} ->
        case String.replace_suffix(rest, "/handle", "") do
          id when id == lost.identifier -> :close
          id when id == twice.identifier -> {200, name_answer("held", id)}
          _other -> RegistryStub.refusal(:handle_not_found)
        end
      end)

      for account <- [lost, unheld, twice] do
        {:ok, %{person: person}} = Newcomer.admit(:open, account)
        assert %{namespace: nil} = person
        assert {"me" <> _, "Me"} = slug(person.id)
      end
    end

    test "of two accounts taking one name at once, the later is admitted without the namespace, never refused",
         %{dir: dir} do
      {first, _account} = first!(dir)
      {:ok, _} = Store.allow("wildcard", "*", first.id)
      early = account!(dir)
      late = account!(dir)

      # The registry names both accounts by one name, as it does a name it
      # gave the second after the first gave it up.
      RegistryStub.start!(fn %{path: "/v1/identities/" <> rest} ->
        {200, name_answer("mira", String.replace_suffix(rest, "/handle", ""))}
      end)

      # The later admission has learned its name and reads the door; at its
      # first door read, the earlier admission is made and takes the name,
      # before the later one mints.
      test_pid = self()
      handler = "newcomer-race-#{System.unique_integer([:positive])}"

      late_task =
        Task.async(fn ->
          receive do
            :go -> Newcomer.admit(:open, late)
          end
        end)

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, metadata, late_pid ->
            if self() == late_pid and metadata[:source] == "server_allowlist" and
                 Process.get(:early_made) != true do
              Process.put(:early_made, true)
              made = Task.async(fn -> Newcomer.admit(:open, early) end) |> Task.await(30_000)
              send(test_pid, {:early, made})
            end
          end,
          late_task.pid
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      send(late_task.pid, :go)

      assert {:ok, %{person: late_person}} = Task.await(late_task, 30_000)
      assert_receive {:early, {:ok, %{person: early_person}}}, 30_000

      assert %{namespace: "mira"} = early_person
      assert slug(early_person.id) == {"mira", "mira"}
      assert %{namespace: nil} = late_person
      assert {"me" <> _, "Me"} = slug(late_person.id)
    end

    test "a name a sign-in records between the mint's read and its insert admits the person without it",
         %{dir: dir} do
      {first, _account} = first!(dir)
      {:ok, _} = Store.allow("wildcard", "*", first.id)
      late = account!(dir)

      RegistryStub.start!(fn %{path: "/v1/identities/" <> rest} ->
        {200, name_answer("mira", String.replace_suffix(rest, "/handle", ""))}
      end)

      # When the mint has read the name free, a writer outside the mints'
      # order records it for the first person, as a sign-in that learned
      # their name does (`Sanctum.Tenancy.Users.set_namespace/2`).
      handler = "newcomer-taken-#{System.unique_integer([:positive])}"
      {:ok, holder} = Sanctum.Tenancy.Users.get(first.id)

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, metadata, minter ->
            if self() == minter and metadata[:source] == "users" and
                 String.contains?(metadata[:query] || "", "namespace") and
                 Process.get(:name_taken) != true do
              Process.put(:name_taken, true)
              {:ok, _} = Sanctum.Tenancy.Users.set_namespace(holder, "mira")
            end
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, %{person: person}} = Newcomer.admit(:open, late)
      :telemetry.detach(handler)
      assert Process.get(:name_taken)

      assert %{namespace: nil} = person
      assert {"me" <> _, "Me"} = slug(person.id)
      assert {:ok, %{namespace: "mira"}} = Sanctum.Tenancy.Users.get(first.id)
    end

    test "a name another person here holds still labels the allow and the request it leaves", %{
      dir: dir
    } do
      {first, _account} = first!(dir)
      {:ok, holder} = Sanctum.Tenancy.Users.get(first.id)
      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(holder, "held")
      invited = account!(dir)
      refused = account!(dir)

      RegistryStub.start!(fn %{path: "/v1/identities/" <> rest} ->
        {200, name_answer("held", String.replace_suffix(rest, "/handle", ""))}
      end)

      ctx = Sanctum.TestContext.session!(first.id) |> Map.put(:platform_admin, true)
      {:ok, %{code: code}} = Sanctum.Invitations.create(ctx, nil)
      {:ok, hash} = Sanctum.Invitations.code_hash(code)

      {:ok, %{person: person}} = Newcomer.admit({:invitation, hash}, invited)
      assert %{namespace: nil} = person
      assert %{effect: "allow", label: "held"} = entry(invited.identifier)

      assert {:error, {:door, :not_allowed}} = Newcomer.admit(:open, refused)
      assert %{status: "requested", label: "held"} = entry(refused.identifier)
    end

    defp name_answer(name, identifier) do
      RegistryStub.answer(%{
        "protocol" => Prima.HandleAnswer.protocol(),
        "registry" => RegistryStub.host(),
        "handle" => name,
        "identifier" => identifier,
        "directory" => RegistryStub.directory()
      })
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
