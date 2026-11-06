# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.InstallationClaims do
  @moduledoc """
  Who may mint this installation's first person.

  ## The guard

  `guard!/1` is the check every person mint runs inside its own
  transaction (`Arca.Users.mint/4`), naming the mint's admission. The
  installation's first person is made only by `setup`, and is its
  platform administrator: every other admission needs an existing
  person's act, so on a node with no person it is refused `:not_set_up`.
  A `setup` mint is admitted on a node with no person, and refused
  `:setup_closed` on one that holds a person, whoever made them: the
  setup token binds the installation to its first account and then opens
  nothing.

  ## One order

  Every person mint serializes on one row: the schema fingerprint's in
  `server_meta`, which every database this release accepts holds
  (`Arca.SchemaFingerprint`). On PostgreSQL it is locked
  (`Arca.QueryHelpers.for_update/1`), since two mints each read what the
  other writes and no row of either exists to lock before them; on SQLite
  the locking transaction's write lock is the order. A database without
  the row raises rather than deciding unordered.
  """

  import Ecto.Query

  require Logger

  alias Arca.QueryHelpers

  alias Arca.Schemas.{ServerMeta, User}

  @typedoc """
  What the guard admits: `:first`, the installation's first person, who
  is its platform administrator, or `:ok`, another person.
  """
  @type admitted :: :first | :ok

  @doc false
  @spec guard!(String.t()) :: admitted() | {:error, :not_set_up | :setup_closed}
  # The first-person guard, inside the caller's locking transaction
  # (`Arca.Users.mint/4`): the mint's admission. Answers what it admits or
  # the refusal the caller rolls back with.
  # arca:db-raise-ok a transaction step: the mint that runs it rescues around its transaction.
  def guard!(admission) when is_binary(admission) do
    lock_order!()
    decide(admission)
  end

  @doc """
  What a `setup` would be answered now: `:first` or `:closed`. The guard's
  own decision (`guard!/1`) read outside any transaction and without its
  locks, for a surface that says setup is closed before it starts. The
  mint decides again under the order row, so this answer is advice and
  never authority.
  """
  @spec setup(Prima.Actor.t()) ::
          {:ok, :first | :closed} | {:error, :cross_tenant | :database_error}
  def setup(%Prima.Actor{scope: :platform}) do
    Arca.Repo.Errors.with_db_rescue("Arca.InstallationClaims.setup", fn ->
      case decide("setup") do
        :first -> {:ok, :first}
        {:error, _closed} -> {:ok, :closed}
      end
    end)
  end

  def setup(%Prima.Actor{}), do: {:error, :cross_tenant}

  defp decide(admission) do
    cond do
      empty?() and admission == "setup" -> :first
      empty?() -> {:error, :not_set_up}
      admission == "setup" -> {:error, :setup_closed}
      true -> :ok
    end
  end

  @doc """
  What the line logged once the installation gains its first person
  begins with, after the mint that made them committed
  (`first_person_made/0`): `cyfr` reads it from the cyfr service's log
  after the boot's `Cyfr.Application.not_set_up_marker/0`, which then no
  longer stands.
  """
  @spec set_up_marker() :: String.t()
  def set_up_marker, do: "[Cyfr] Set up:"

  @doc false
  @spec first_person_made() :: :ok
  # Said by `Arca.Users.mint/4` once the mint of the first person, by
  # setup or `cyfr login --setup`, committed. Logged at the
  # boot's notice level, so a log that holds the one holds the other.
  def first_person_made do
    Logger.warning(set_up_marker() <> " this CYFR has its first person.")
  end

  # ---- internals -------------------------------------------------------------

  defp empty?, do: not Arca.Repo.exists?(from(u in User))

  # The one row every first-person decision serializes on (the module doc).
  # Every database this release accepts holds it; one without it has lost
  # the order, and deciding without the order is never safe.
  defp lock_order! do
    from(m in ServerMeta, where: m.key == ^Arca.SchemaFingerprint.key(), select: m.key)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> case do
      nil ->
        raise "Arca.InstallationClaims found no schema fingerprint row to order " <>
                "first-person decisions on; recreate the database (Arca.SchemaFingerprint)."

      _key ->
        :ok
    end
  end
end
