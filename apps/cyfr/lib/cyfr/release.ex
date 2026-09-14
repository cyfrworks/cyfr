# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Release do
  @moduledoc """
  Release tasks — the operator's hands on the database when the server is
  not the one to touch it.

  By default the server migrates on boot (`CYFR_AUTO_MIGRATE=true`); one node
  fronting one database wants exactly that. Several nodes sharing a
  Postgres, or an operator who wants the schema step in their own hands,
  set `CYFR_AUTO_MIGRATE=false` and run these from the release:

      bin/cyfr eval "Cyfr.Release.migrate()"

  It starts only what a migration needs (no endpoint, no supervisors) and
  stops it again. The schema is one baseline with no `down`: a database
  built from a different version of it is refused
  (`Arca.SchemaFingerprint`), never rolled back.

  ## Key rotation

  Release commands for rotating encryption keys and auditing stored key labels:

      bin/cyfr eval "Cyfr.Release.cipher_audit()"
      bin/cyfr eval "Cyfr.Release.rotate_cipher_keys()"

  Add the new key to `CYFR_CRYPTO_KEYRING` and make it `primary`, restart, then
  run the rotation: it re-encrypts every sealed row onto the primary key,
  skipping rows already there. Read `cipher_audit/0` first to see the spread,
  and again afterwards to confirm nothing is left on the old label — only then
  is the old key safe to drop from the keyring.
  """

  @app :cyfr

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
  Report which key label every sealed row is encrypted under, without
  decrypting anything.

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
    Application.ensure_loaded(@app)
    Application.ensure_all_started(:ssl)
  end
end
