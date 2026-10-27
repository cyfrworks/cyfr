# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Release do
  @moduledoc """
  Release tasks — the operator's hands on the database when the server is
  not the one to touch it.

  By default the server migrates on boot (`CYFR_AUTO_MIGRATE=on`); one node
  fronting one database wants exactly that. Several nodes sharing a
  Postgres, or an operator who wants the schema step in their own hands,
  set `CYFR_AUTO_MIGRATE=off` and run these from the release:

      bin/cyfr eval "Cyfr.Release.migrate()"

  It starts only what a migration needs (no endpoint, no supervisors) and
  stops it again. The schema is one baseline with no `down`: a database
  built from a different version of it is refused
  (`Arca.SchemaFingerprint`), never rolled back.

  ## Key rotation

  Release commands for rotating encryption keys and auditing stored key labels:

      bin/cyfr eval "Cyfr.Release.cipher_audit()"
      bin/cyfr eval "Cyfr.Release.rotate_cipher_keys()"

  Add the new key to `CYFR_CRYPTO_KEYRING` and make it `primary`, keeping the
  old label among the keys. The next boot refuses the changed keyring and
  names its fingerprint (`Cyfr.KeyringFingerprint`); set
  `CYFR_CRYPTO_KEYRING_FINGERPRINT_ACCEPT` to it for that one boot, then
  run the rotation: it re-encrypts every sealed row onto the primary key,
  skipping rows already there. Read `cipher_audit/0` first to see the spread,
  and again afterwards to confirm nothing is left on the old label — only then
  is the old key safe to drop from the keyring. A row a concurrent write
  touched mid-run can keep a column on the old label; the audit shows it,
  and running the rotation again moves it.
  """

  @app :arca

  @doc """
  Run every pending migration, refuse a database built from a different
  schema, then assert the tenant roster still covers the schema — the
  checks every boot runs, answered here before the server starts. A table
  that carries `athanor_id` and is not in `Arca.TenantTables` would survive
  `destroy/1` silently.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))

      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _ ->
          Arca.SchemaFingerprint.verify!()
          Arca.TenantTables.verify_roster!()
        end)
    end

    :ok
  end

  @doc """
  The migrations the repo has not run yet. A database built from another
  version of the baseline records the baseline as run and answers `[]`
  too: whether the schema is this release's is
  `Arca.SchemaFingerprint.verify/0`'s answer, which `migrate/0` and every
  boot give.
  """
  @spec pending() :: [{integer(), String.t()}]
  def pending do
    load_app()

    Enum.flat_map(repos(), fn repo ->
      {:ok, pending, _} =
        Ecto.Migrator.with_repo(repo, fn r ->
          r
          |> Ecto.Migrator.migrations()
          |> Enum.filter(fn {status, _version, _name} -> status == :down end)
          |> Enum.map(fn {_status, version, name} -> {version, name} end)
        end)

      pending
    end)
  end

  @doc """
  The cell's live slots, read with the server stopped: every `cell_leases`
  row whose lease still stands on the database's clock, as
  `%{node, owner, release, lease_until}` (`lease_until` in ISO 8601), the
  answer `Arca.ControlPlane.roster/0` gives a running member.

  `cyfr update` runs it once it has stopped its stack and before it
  snapshots anything, as

      bin/cyfr eval 'IO.puts("CYFR_LIVE_SLOTS=" <> JSON.encode!(%{release: Prima.Version.current(), slots: Cyfr.Release.live_slots()}))'

  where `eval` starts no application: like `migrate/0` it starts the repo
  alone (`Ecto.Migrator.with_repo/2`), migrates nothing and checks no
  fingerprint, so it reads a database of the release that wrote it. The
  update goes on only when every slot it answers is a member already
  running the release being installed — a host of the cell updated before
  this one — so on a single host only an empty list lets it go on. A store
  that cannot answer raises, so `eval` exits non-zero and the update stops,
  never reading an error as an empty cell.
  """
  @spec live_slots() :: [
          %{
            node: String.t(),
            owner: String.t(),
            release: String.t(),
            lease_until: String.t()
          }
        ]
  def live_slots do
    load_app()

    Enum.flat_map(repos(), fn repo ->
      {:ok, slots, _} =
        Ecto.Migrator.with_repo(repo, fn _ ->
          case Arca.ControlPlane.roster() do
            {:ok, rows} ->
              Enum.map(rows, &live_slot/1)

            {:error, reason} ->
              raise "the cluster's slots could not be read: #{Prima.LoggerContext.shape(reason)}"
          end
        end)

      slots
    end)
  end

  defp live_slot(row) do
    %{
      node: row.node,
      owner: row.owner,
      release: row.release,
      lease_until: DateTime.to_iso8601(row.lease_until)
    }
  end

  @doc """
  Declare a restore: write the marker `restore_pending`
  (`Arca.SecurityTransitions.mark_restore/1`), whose value is a new
  restore id, and answer that id; a marker already written is answered
  as it stands, so a second run declares the same restore. The next boot
  consumes it before its gate opens (`ARCHITECTURE.md` §6.9). `cyfr
  restore` runs it with the whole cell stopped, once every part of the
  backup is back, as

      bin/cyfr eval 'IO.puts("CYFR_RESTORE_ID=" <> Cyfr.Release.mark_restore())'

  and an operator who put a backup back by hand runs the same before the
  first start. Like `live_slots/0` it starts the repo alone, migrates
  nothing and checks no fingerprint. A store that cannot answer raises,
  so `eval` exits non-zero and no restore is declared.
  """
  @spec mark_restore() :: String.t()
  def mark_restore do
    load_app()

    [restore_id | _] =
      Enum.map(repos(), fn repo ->
        {:ok, restore_id, _} =
          Ecto.Migrator.with_repo(repo, fn _ ->
            case Arca.SecurityTransitions.mark_restore(Prima.Actor.system()) do
              {:ok, restore_id} ->
                restore_id

              {:error, reason} ->
                raise "the restore could not be declared: #{Prima.LoggerContext.shape(reason)}"
            end
          end)

        restore_id
      end)

    restore_id
  end

  @doc """
  Report which key label every sealed value is encrypted under, each
  sealed column of a row counted, without decrypting anything.

  Run it before a rotation to see the spread, and after one to confirm the old
  label is gone. A non-zero `unknown`, or an `on_other` label the keyring no
  longer carries, means the key is still load-bearing and must not be dropped.
  """
  @spec cipher_audit() :: {:ok, map()}
  def cipher_audit do
    load_app()
    Sanctum.Cipher.Rotation.audit()
  end

  @doc """
  Re-encrypt every sealed row onto the keyring's current primary key.

  `dry_run: true` reports what would change and writes nothing. The run is
  fail-closed and resumable: a row that cannot be decrypted aborts it rather
  than being skipped into permanent unreadability, and rows already on the
  primary are passed over, so re-running after fixing the cause is safe.
  """
  @spec rotate_cipher_keys(keyword()) :: {:ok, map()} | {:error, {atom(), term(), term()}}
  def rotate_cipher_keys(opts \\ []) do
    load_app()
    Sanctum.Cipher.Rotation.reencrypt_all(opts)
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    # A task runs in `bin/cyfr eval`, where no application start installs
    # the log filter, over keys and sealed rows: Logger first, so the filter
    # goes ahead of its translator, then the filter (`Prima.LogFilter`).
    {:ok, _started} = Application.ensure_all_started(:logger)
    :ok = Prima.LogFilter.install()

    # The repositories are the `arca` application's and the key rotation is
    # the `sanctum` application's; both are loaded so their configuration
    # is readable without starting either.
    Application.ensure_loaded(:arca)
    Application.ensure_loaded(:sanctum)
    Application.ensure_all_started(:ssl)
  end
end
