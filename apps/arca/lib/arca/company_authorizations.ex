# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CompanyAuthorizations do
  @moduledoc """
  A person's company sign-in (`Arca.Schemas.CompanyAuthorization`): one
  row per person, naming the company configuration it was given under,
  the subject that configuration's issuer names the person by, and when
  they last signed in with it. Unique on configuration and subject, so
  one company account binds one person under one configuration. The row
  is the person's, never an athanor's, and goes with their `users` row.

  Arca stores and compares strings: which configuration is current, and
  whether a row stands under it, is the identity domain's
  (`Sanctum.CompanyLogin`).

  `bind/3` writes in one transaction that proves this member still owns
  its slot (`Arca.Repo.owned/2`), locks the person, runs the caller's
  `verify:` closure, then decides on the row as it is under that lock:

    * a row under the same configuration: the subject must be the row's,
      and `authorized_at` moves to the database's clock (`:refreshed`);
      another subject is refused `:subject_bound`;
    * no row, or one under another configuration: the subject is bound,
      replacing that row (`:bound`);
    * another person's row under the same configuration and subject: the
      unique index refuses the insert, `:subject_bound`. Two bindings of
      one subject at once are decided by the index the same way: the one
      that commits second inserts nothing.
  """

  import Ecto.Query

  alias Arca.Schemas.CompanyAuthorization

  @typedoc "A company authorization row, as a plain map."
  @type row :: %{
          user_id: String.t(),
          configuration: String.t(),
          subject: String.t(),
          authorized_at: DateTime.t()
        }

  @doc """
  The person `user_id`'s row, read by its primary key, for the platform's
  actor or the person themselves.
  """
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def get(%Prima.Actor{} = actor, user_id) when is_binary(user_id) do
    with :ok <- reach(actor, user_id) do
      Arca.Repo.Errors.with_db_rescue("Arca.CompanyAuthorizations.get", fn ->
        case Arca.Repo.get(CompanyAuthorization, user_id) do
          nil -> {:error, :not_found}
          row -> {:ok, plain(row)}
        end
      end)
    end
  end

  @doc """
  Bind or refresh `user_id`'s company sign-in under `configuration` and
  `subject` (the module doc). `verify:` runs first under the person's
  lock, inside the transaction, and answers `:ok` or `{:error, reason}`,
  which rolls it back. Answers `{:ok, :bound}` or `{:ok, :refreshed}`,
  or `:subject_bound`, `:not_owner`, `:cross_tenant`,
  `:database_error` or the closure's reason. The platform's own actor
  alone binds.
  """
  @spec bind(Prima.Actor.t(), map(), keyword()) ::
          {:ok, :bound | :refreshed} | {:error, term()}
  def bind(
        %Prima.Actor{scope: :platform, system: true},
        %{user_id: user_id, configuration: configuration, subject: subject},
        opts
      )
      when is_binary(user_id) and is_binary(configuration) and is_binary(subject) and
             is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)

    Arca.Repo.owned("Arca.CompanyAuthorizations.bind", fn ->
      _person = Arca.DirectoryHeads.lock_person!(user_id)

      with :ok <- verify.() do
        now = Arca.ServerMetaStorage.now!()

        case Arca.Repo.get(CompanyAuthorization, user_id) do
          %CompanyAuthorization{configuration: ^configuration, subject: ^subject} ->
            refresh(user_id, now)

          %CompanyAuthorization{configuration: ^configuration} ->
            {:error, :subject_bound}

          held ->
            insert(held, %{
              user_id: user_id,
              configuration: configuration,
              subject: subject,
              authorized_at: now
            })
        end
      end
    end)
  end

  def bind(%Prima.Actor{}, _binding, _opts), do: {:error, :cross_tenant}

  defp refresh(user_id, now) do
    {1, _} =
      Arca.Repo.update_all(from(c in CompanyAuthorization, where: c.user_id == ^user_id),
        set: [authorized_at: now]
      )

    {:ok, :refreshed}
  end

  # A row under another configuration gives way; the insert that follows
  # is the unique index's to refuse, which on_conflict answers as no row
  # rather than an error that would abort the transaction.
  defp insert(held, row) do
    if held, do: Arca.Repo.delete!(held)

    case Arca.Repo.insert_all(CompanyAuthorization, [row], on_conflict: :nothing) do
      {1, _} -> {:ok, :bound}
      {0, _} -> {:error, :subject_bound}
    end
  end

  defp reach(%Prima.Actor{scope: :platform}, _user_id), do: :ok

  defp reach(%Prima.Actor{user_id: user_id}, user_id) when is_binary(user_id) and user_id != "",
    do: :ok

  defp reach(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

  defp plain(%CompanyAuthorization{} = row),
    do: Map.take(row, [:user_id, :configuration, :subject, :authorized_at])
end
