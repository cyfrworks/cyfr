# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.People do
  @moduledoc """
  The suite's people, made with the rows an admission writes.

  `linked/1` is a fixture's person: an open admission's person with an
  account at the suite's directory (`Sanctum.TestContext.account!/1`),
  whose keys only the suite holds, made without the door and without the
  installation guard, so a fixture's first person is no administrator and
  needs no setup person before it. `remote/2` is a person admitted by an
  account the test names, and `athanor!/1` reads a person's own athanor.
  `first!/1` is the installation's administrator, made by the setup
  admission's own mint (`Arca.Users.mint/3`), so the platform
  administrator's mark is the product's. A test of admission itself goes
  through `Sanctum.Newcomer`.
  """

  alias Arca.Schemas.User

  @doc """
  A new person: `info` is `%{id: label, provider:, email:, verified:,
  name:}` (`email`, `verified` and `name` optional), the `id` and
  `provider` naming the fixture and nothing stored. The person is minted
  with admission `open`, their account (`Sanctum.TestContext.account!/1`)
  and their own athanor (`Sanctum.Provisioning.mint_personal/1`, past the
  caps), in one transaction, with the email, its verification (`true`,
  `false`, or nil for none) and the name `info` carries. Answers
  `{:ok, user}`, the row as `Sanctum.Tenancy.Users.get/1` reads it.
  """
  @spec linked(map()) :: {:ok, Sanctum.Tenancy.Users.user()}
  def linked(%{id: key} = info) when is_binary(key) do
    {:ok, %{id: user_id}} = mint(info)
    Sanctum.Tenancy.Users.get(user_id)
  end

  @doc """
  The person's own athanor, the one their admission made: the `athanors`
  row, read by its owner. Raises when they hold none
  (a remote person, or a row a test wrote without one).
  """
  @spec athanor!(String.t() | %{required(:id) => String.t()}) :: map()
  def athanor!(%{id: user_id}), do: athanor!(user_id)

  def athanor!(user_id) when is_binary(user_id) do
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get_by_owner(user_id)
    athanor
  end

  @doc """
  A new person admitted by the account `remote` names: admission
  `remote`, no athanor, and the identity row naming `remote.identifier`,
  its directory and `remote.head_hash`, the head read, with the contact
  fields `info` carries as `linked/1` writes them. Made without the door
  and without a directory read; a test of admission goes through
  `Sanctum.Newcomer`. Answers `{:ok, user}` as
  `Sanctum.Tenancy.Users.get/1` reads it.
  """
  @spec remote(map(), map()) :: {:ok, Sanctum.Tenancy.Users.user()}
  def remote(
        %{id: key} = info,
        %{identifier: identifier, directory_url: directory, head_hash: head}
      )
      when is_binary(key) and is_binary(identifier) and is_binary(directory) and is_binary(head) do
    {:ok, %{id: user_id}} =
      insert(info, "remote", fn person ->
        {:ok, _} =
          Arca.PersonIdentities.create(Prima.Actor.system(), %{
            user_id: person.id,
            identifier: identifier,
            directory_url: directory,
            head_hash: head
          })

        :ok
      end)

    Sanctum.Tenancy.Users.get(user_id)
  end

  @doc """
  The installation's first person, its platform administrator, made by
  the setup admission's mint with their account
  (`Sanctum.TestContext.account!/1`) and their athanor. Raises unless the
  installation holds no person.
  """
  @spec first!(map()) :: Sanctum.Tenancy.Users.user()
  def first!(attrs \\ %{}) do
    now = DateTime.utc_now()

    user_attrs =
      Map.merge(
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          prefs: Jason.encode!(%{}),
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        Map.take(attrs, [:email, :email_verified, :display_name])
      )

    {:ok, %{id: user_id}} =
      Arca.Users.mint(Prima.Actor.system(), user_attrs,
        admission: "setup",
        also: fn person ->
          _account = Sanctum.TestContext.account!(person.id)

          with {:ok, _athanor} <- Sanctum.Provisioning.mint_personal(person), do: :ok
        end
      )

    {:ok, user} = Sanctum.Tenancy.Users.get(user_id)
    user
  end

  defp mint(info) do
    insert(info, "open", fn person ->
      _account = Sanctum.TestContext.account!(person.id)
      {:ok, _athanor} = Sanctum.Provisioning.mint_personal(person)
      :ok
    end)
  end

  # The person row of `admission`, then `also` handed the person, in one
  # transaction.
  defp insert(info, admission, also) do
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())

    user_attrs =
      Map.merge(
        %{
          id: user_id,
          admission: admission,
          prefs: Jason.encode!(%{}),
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        contact(info)
      )

    Arca.Repo.transaction(fn ->
      user = %User{} |> User.changeset(user_attrs) |> Arca.Repo.insert!()
      person = Arca.Data.project(user)
      :ok = also.(person)
      person
    end)
  end

  # The contact fields: the email as given, its verification as one of
  # three answers, and the name.
  defp contact(info) do
    %{email_verified: verified(Map.get(info, :verified))}
    |> Prima.MapUtil.put_present(:email, Map.get(info, :email))
    |> Prima.MapUtil.put_present(:display_name, Map.get(info, :name))
  end

  defp verified(true), do: true
  defp verified(false), do: false
  defp verified(_unknown), do: nil
end
