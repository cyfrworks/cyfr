# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.People do
  @moduledoc """
  A test's person rows, written straight into the sandbox: the `users`
  row (admission `open` unless the attributes name another) and, when
  given, the sign-in method linked to it, in one transaction. No
  installation guard runs, so a test's first person is no administrator
  and needs no setup before it. A test of the mint itself
  (`Arca.Users.mint/4`), and of the installation guard, calls the mint.
  """

  alias Arca.Schemas.{ExternalIdentity, User}

  @doc """
  Write the person `user_attrs` and the identity `identity_attrs` (nil
  for none), as `Arca.Users.mint/4` writes them, and run `opts[:also]`
  after them in the same transaction, handed the person, as the mint's
  `also:` runs. Answers `{:ok, person}`, the person as a plain map, or the
  refusal of a row that does not validate or of the closure.
  """
  @spec mint(Prima.Actor.t(), map(), map() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def mint(%Prima.Actor{scope: :platform}, user_attrs, identity_attrs, opts \\ []) do
    user_attrs =
      user_attrs |> Map.new() |> Map.delete(:provider) |> Map.put_new(:admission, "open")

    also = Keyword.get(opts, :also, fn _person -> :ok end)

    Arca.Repo.transaction(fn ->
      with {:ok, user} <- %User{} |> User.changeset(user_attrs) |> Arca.Repo.insert(),
           {:ok, _identity} <- identity(identity_attrs, user.id),
           :ok <- also.(Arca.Data.project(user)) do
        user
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          Arca.Repo.rollback(Arca.Data.invalid(changeset))

        {:error, reason} ->
          Arca.Repo.rollback(reason)
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  Give the person `user_id` an account at `https://dir.example`: its
  identity row and this home's cached head of it, at `opts[:head]` (a
  fresh digest by default), as a first read of its log leaves them.
  Answers `%{identifier: identifier, head: head}`.
  """
  @spec account!(String.t(), keyword()) :: %{identifier: String.t(), head: String.t()}
  def account!(user_id, opts \\ []) when is_binary(user_id) do
    n = System.unique_integer([:positive])
    identifier = Keyword.get(opts, :identifier, "per_" <> Prima.Digest.sha256_hex("account-#{n}"))
    head = Keyword.get(opts, :head, Prima.Digest.sha256("head-#{n}"))
    system = Prima.Actor.system()

    {:ok, _row} =
      Arca.PersonIdentities.create(system, %{
        user_id: user_id,
        provenance: "remote",
        identifier: identifier,
        directory_url: "https://dir.example",
        head_hash: head
      })

    {:ok, _head} =
      Arca.DirectoryHeads.put(system, %{
        identifier: identifier,
        genesis: "genesis-bytes",
        directory_url: "https://dir.example",
        head_hash: head,
        state: "{}"
      })

    %{identifier: identifier, head: head}
  end

  defp identity(nil, _user_id), do: {:ok, nil}

  defp identity(attrs, user_id) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:id, Prima.UUID7.generate_id("ext"))
      |> Map.put(:user_id, user_id)

    %ExternalIdentity{} |> ExternalIdentity.changeset(attrs) |> Arca.Repo.insert()
  end
end
