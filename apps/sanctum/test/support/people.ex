# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.People do
  @moduledoc """
  The suite's people, made with the rows an admission writes.

  `linked/1` is a fixture's person: an open admission's person with a
  sign-in method linked, made without the door and without the
  installation guard, so a fixture's first person is no administrator and
  needs no setup person before it. `remote/2` is a remote admission's
  person, linked to their CYFR sign-in identity, and `athanor!/1` reads a
  person's own athanor. `first!/1` is the installation's administrator,
  made by the setup admission's own mint
  (`Arca.Users.mint/4`), so the platform grant is the product's. A test of
  admission itself goes through `Sanctum.Newcomer`.
  """

  alias Arca.Schemas.{ExternalIdentity, User}

  @doc """
  The person the identity key `info.id` names, made the first time:
  `info` is `%{id: identity_key, provider:, email:, verified:, name:}`
  (`email`, `verified` and `name` optional). A new person is minted with
  admission `open`, their keys (`Sanctum.Person.mint_keys/1`), their own
  athanor and its seat (`Sanctum.Provisioning.mint_personal/2`, past the
  caps) and that identity linked, in one transaction. A second call with
  the same key answers the same person, with the email, its verification
  (`true`, `false`, or nil for none) and the name it carries written over
  the row as the first call wrote them. Answers `{:ok, user}`, the row as
  `Sanctum.Tenancy.Users.get/1` reads it.
  """
  @spec linked(map()) :: {:ok, Sanctum.Tenancy.Users.user()}
  def linked(%{id: key} = info) when is_binary(key) do
    case Sanctum.Tenancy.Users.get_by_identity(key) do
      {:ok, user} ->
        {:ok, _} = Arca.Users.update(Prima.Actor.system(), user.id, contact(info))
        Sanctum.Tenancy.Users.get(user.id)

      {:error, :not_found} ->
        {:ok, %{id: user_id}} = mint(info)
        Sanctum.Tenancy.Users.get(user_id)
    end
  end

  @doc """
  The person's own athanor, the one their admission made with their seat
  there: the `athanors` row, read by its owner. Raises when they hold none
  (a remote person, or a row a test wrote without one).
  """
  @spec athanor!(String.t() | %{required(:id) => String.t()}) :: map()
  def athanor!(%{id: user_id}), do: athanor!(user_id)

  def athanor!(user_id) when is_binary(user_id) do
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get_by_owner(user_id)
    athanor
  end

  @doc """
  The remote person the CYFR sign-in identity `info.id` names, made the
  first time as the remote admission makes one: admission `remote`, no
  keys and no athanor, the identity linked and an identity row of
  provenance `remote` naming `remote.identifier` and its directory
  (`remote.genesis_hash` and `remote.head_hash` when given). Made without
  the door and without a directory read; a test of the remote admission
  goes through `Sanctum.Newcomer`. The same key again answers the same
  person, with the contact fields rewritten as `linked/1` rewrites them.
  Answers `{:ok, user}` as `Sanctum.Tenancy.Users.get/1` reads it.
  """
  @spec remote(map(), map()) :: {:ok, Sanctum.Tenancy.Users.user()}
  def remote(%{id: key} = info, %{identifier: identifier, directory_url: directory} = remote)
      when is_binary(key) and is_binary(identifier) and is_binary(directory) do
    case Sanctum.Tenancy.Users.get_by_identity(key) do
      {:ok, user} ->
        {:ok, _} = Arca.Users.update(Prima.Actor.system(), user.id, contact(info))
        Sanctum.Tenancy.Users.get(user.id)

      {:error, :not_found} ->
        {:ok, %{id: user_id}} =
          insert(info, "remote", fn person ->
            {:ok, _} =
              Arca.PersonIdentities.create(Prima.Actor.system(), %{
                user_id: person.id,
                provenance: "remote",
                identifier: identifier,
                directory_url: directory,
                genesis_hash: remote[:genesis_hash],
                head_hash: remote[:head_hash]
              })

            :ok
          end)

        Sanctum.Tenancy.Users.get(user_id)
    end
  end

  @doc """
  The installation's first person, its platform administrator, made by
  the setup admission's mint with their keys and their athanor. Raises
  unless the installation holds no person.
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
      Arca.Users.mint(Prima.Actor.system(), user_attrs, nil,
        admission: "setup",
        also: fn person ->
          with :ok <- Sanctum.Person.mint_keys(person),
               {:ok, _athanor} <- Sanctum.Provisioning.mint_personal(person, operator: true),
               do: :ok
        end
      )

    {:ok, user} = Sanctum.Tenancy.Users.get(user_id)
    user
  end

  defp mint(info) do
    insert(info, "open", fn person ->
      :ok = Sanctum.Person.mint_keys(person)
      {:ok, _athanor} = Sanctum.Provisioning.mint_personal(person, operator: true)
      :ok
    end)
  end

  # The person row of `admission` and the identity `info.id` linked, then
  # `also` handed the person, in one transaction.
  defp insert(%{id: key} = info, admission, also) do
    {:ok, %{provider: provider, issuer: issuer, subject: subject}} =
      Sanctum.Auth.Identity.parse(key)

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

    identity_attrs = %{
      id: Prima.UUID7.generate_id("ext"),
      user_id: user_id,
      key: key,
      provider: provider,
      issuer: issuer,
      subject: subject,
      first_seen_at: now,
      last_seen_at: now
    }

    Arca.Repo.transaction(fn ->
      user = %User{} |> User.changeset(user_attrs) |> Arca.Repo.insert!()
      %ExternalIdentity{} |> ExternalIdentity.changeset(identity_attrs) |> Arca.Repo.insert!()
      person = Arca.Data.project(user)
      :ok = also.(person)
      person
    end)
  end

  # The contact fields as the first call wrote them: the email as given,
  # its verification as the provider's three answers, and the name.
  defp contact(info) do
    %{email_verified: verified(Map.get(info, :verified))}
    |> Prima.MapUtil.put_present(:email, Map.get(info, :email))
    |> Prima.MapUtil.put_present(:display_name, Map.get(info, :name))
  end

  defp verified(true), do: true
  defp verified(false), do: false
  defp verified(_unknown), do: nil
end
