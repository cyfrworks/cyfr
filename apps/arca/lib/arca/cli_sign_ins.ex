# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CliSignIns do
  @moduledoc """
  A command line's pending sign-ins (`Arca.Schemas.CliSignIn`): one row
  per `cyfr login` waiting for its person to approve it in Prism. A row is
  stored by the hashes of its two secrets and never the secrets: the
  approval secret the link carries (`approval_hash`) and the session
  token the command line holds (`token_hash`). Beside them it keeps the
  code both sides show, the machine the command line named, its state
  and its expiry, set on the database's clock.

  A row is no athanor's and no person's. It is opened before anyone is
  signed in, and the session its approval mints under the command line's
  token (`Arca.SessionStorage`) carries the person and the athanor. It is
  read only by the hash of a secret its reader holds (`by_approval/1`,
  `by_token/1`), as a pairing invitation's lookup is.

  ## State

  `pending` until one of two, and neither is ever left:

    * `approved` by `approve!/2`, a step inside the transaction that
      inserts the session under the row's token
      (`Arca.SessionStorage.create_session/3`'s `also:`), so the session
      and the approval commit together or not at all;
    * `cancelled` by `cancel/1`, from the command line that holds the
      token, which also ends the session an approval that committed first
      minted.

  Both lock the row before they decide, so the second waits for the first
  and then reads what it committed. `sweep/0` deletes every row
  `@grace_ms` past its expiry.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.CliSignIn

  # How long past its expiry a row is kept, so a command line still
  # polling at its deadline reads what became of it.
  @grace_ms 10 * 60 * 1000

  @doc """
  Open a pending sign-in: `attrs` names the `:approval_hash` and
  `:token_hash` (each a SHA-256), the `:token_prefix`, the `:user_code`,
  the `:machine` and its `:lifetime_ms`. Answers `%{id, user_code,
  machine, expires_at}`, the expiry on the database's clock, or `{:error,
  :conflict}` for a hash another row holds.
  """
  @spec open(map()) :: {:ok, map()} | {:error, :conflict | :database_error}
  def open(%{lifetime_ms: lifetime_ms} = attrs)
      when is_integer(lifetime_ms) and lifetime_ms > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.CliSignIns.open", fn ->
      now = Arca.ServerMetaStorage.now!()

      row = %{
        id: Prima.UUID7.generate_id("csi"),
        approval_hash: attrs.approval_hash,
        token_hash: attrs.token_hash,
        token_prefix: attrs.token_prefix,
        user_code: attrs.user_code,
        machine: attrs.machine,
        state: "pending",
        expires_at: DateTime.add(now, lifetime_ms, :millisecond),
        inserted_at: now,
        updated_at: now
      }

      case Arca.Repo.insert_all(CliSignIn, [row], on_conflict: :nothing) do
        {1, _} -> {:ok, Map.take(row, [:id, :user_code, :machine, :expires_at])}
        {0, _} -> {:error, :conflict}
      end
    end)
  end

  @doc """
  The pending sign-in whose approval secret hashes to `approval_hash`:
  `%{id, token_hash, token_prefix, user_code, machine, state, expires_at}`,
  or `{:error, :not_found}`. What the approver is shown and what the
  approval mints under; deciding it is `approve!/2`'s.
  """
  @spec by_approval(binary()) :: {:ok, map()} | {:error, :not_found | :database_error}
  # arca:unscoped-ok the lookup of a pending sign-in by the hash of the bearer
  # secret its link carries: the row has no owner until it is approved.
  def by_approval(approval_hash) when is_binary(approval_hash) do
    read(
      "Arca.CliSignIns.by_approval",
      from(c in CliSignIn, where: c.approval_hash == ^approval_hash)
    )
  end

  @doc """
  The pending sign-in whose session token hashes to `token_hash`, as
  `by_approval/1` answers it, or `{:error, :not_found}`.
  """
  @spec by_token(binary()) :: {:ok, map()} | {:error, :not_found | :database_error}
  # arca:unscoped-ok the command line's lookup of its own pending sign-in by
  # the hash of the token it holds: the row has no owner until it is approved.
  def by_token(token_hash) when is_binary(token_hash) do
    read("Arca.CliSignIns.by_token", from(c in CliSignIn, where: c.token_hash == ^token_hash))
  end

  defp read(tag, query) do
    Arca.Repo.Errors.with_db_rescue(tag, fn ->
      query
      |> select([c], %{
        id: c.id,
        token_hash: c.token_hash,
        token_prefix: c.token_prefix,
        user_code: c.user_code,
        machine: c.machine,
        state: c.state,
        expires_at: c.expires_at
      })
      |> Arca.Repo.one()
      |> case do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
  end

  @doc false
  # Approve the pending sign-in `approval_hash` names, as a step of the
  # transaction that inserted the session under `token_hash`: the row is
  # locked, and must still be pending, unexpired on the database's clock
  # once the lock is won, and the one whose token the session was minted
  # under. Answers `:ok`, or `{:error, reason}` for the caller to roll the
  # session back: `:not_found`, `:expired`, `:approved` or `:cancelled`.
  @spec approve!(binary(), binary()) ::
          :ok | {:error, :not_found | :expired | :approved | :cancelled}
  # arca:unscoped-ok the row is addressed by the hash of the approval secret, inside the
  # transaction that mints the approving person's session.
  # arca:db-raise-ok a transaction step: its caller rescues around the transaction.
  def approve!(approval_hash, token_hash)
      when is_binary(approval_hash) and is_binary(token_hash) do
    row =
      CliSignIn
      |> where([c], c.approval_hash == ^approval_hash)
      |> QueryHelpers.for_update()
      |> Arca.Repo.one()

    now = Arca.ServerMetaStorage.now!()

    case row do
      %CliSignIn{token_hash: ^token_hash, state: "pending", expires_at: expires_at} = row ->
        if DateTime.compare(expires_at, now) == :gt do
          {1, _} =
            Arca.Repo.update_all(from(c in CliSignIn, where: c.id == ^row.id),
              set: [state: "approved", updated_at: now]
            )

          :ok
        else
          {:error, :expired}
        end

      %CliSignIn{token_hash: ^token_hash, state: "approved"} ->
        {:error, :approved}

      %CliSignIn{token_hash: ^token_hash, state: "cancelled"} ->
        {:error, :cancelled}

      _absent_or_another ->
        {:error, :not_found}
    end
  end

  @doc """
  Cancel the pending sign-in whose session token hashes to `token_hash`,
  from the command line that holds it: the row is locked, and a pending
  one becomes `cancelled`; an approved one too, with the session its
  approval minted ended in the same transaction. Answers `{:ok, %{state,
  ended}}`, `state` what the row held when the lock was won and `ended`
  the person whose session ended (nil when none did), or `{:error,
  :not_found}`.
  """
  @spec cancel(binary()) ::
          {:ok, %{state: String.t(), ended: String.t() | nil}}
          | {:error, :not_found | :database_error}
  # arca:unscoped-ok the command line's own pending sign-in, addressed by the hash of
  # the token it holds.
  def cancel(token_hash) when is_binary(token_hash) do
    Arca.Repo.Errors.with_db_rescue("Arca.CliSignIns.cancel", fn ->
      Arca.Repo.locking_transaction(fn ->
        CliSignIn
        |> where([c], c.token_hash == ^token_hash)
        |> QueryHelpers.for_update()
        |> Arca.Repo.one()
        |> cancelled()
        |> Arca.Repo.committed()
      end)
    end)
  end

  defp cancelled(nil), do: {:error, :not_found}

  defp cancelled(%CliSignIn{state: "cancelled"}), do: {:ok, %{state: "cancelled", ended: nil}}

  defp cancelled(%CliSignIn{state: state} = row) do
    ended = if state == "approved", do: Arca.SessionStorage.delete_token!(row.token_hash)

    {1, _} =
      Arca.Repo.update_all(from(c in CliSignIn, where: c.id == ^row.id),
        set: [state: "cancelled", updated_at: Arca.ServerMetaStorage.now!()]
      )

    {:ok, %{state: state, ended: ended}}
  end

  @doc """
  Delete every pending sign-in `@grace_ms` past its expiry, whatever its
  state: housekeeping. Answers how many it deleted.
  """
  @spec sweep() :: {:ok, non_neg_integer()} | {:error, :database_error}
  # arca:unscoped-ok expiry is server-wide housekeeping over rows no one owns.
  def sweep do
    Arca.Repo.Errors.with_db_rescue("Arca.CliSignIns.sweep", fn ->
      cutoff = DateTime.add(Arca.ServerMetaStorage.now!(), -@grace_ms, :millisecond)
      {count, _} = Arca.Repo.delete_all(from(c in CliSignIn, where: c.expires_at < ^cutoff))
      {:ok, count}
    end)
  end
end
