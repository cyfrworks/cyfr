# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Passkeys do
  @moduledoc """
  The passkeys of a person's account that signed in here, as this CYFR
  knows them: by the key each signed with (`kid`), from the sessions its
  sign-ins minted (`Sanctum.SignIn`, provider `passkey`). A passkey lives
  in the account's log at the directory and in its person's platform;
  this CYFR holds no registration of it, and a key removed from the
  account ends its sessions here once a refresh reads the removal
  (`Sanctum.IdentityFreshness`).

  `list/1` answers the context person's passkeys signed in here, each its
  `kid`, how many of its sessions stand (`sessions`) and when the newest
  was minted (`signed_in_at`). `revoke/2` ends every session here that
  one passkey signed for, which signs it out of this CYFR and leaves the
  key in the account: removing it from the account is the account pages'
  (`/account/devices`). The person's devices are their paired clients
  (`Sanctum.Pairing`).
  """

  alias Sanctum.Context

  @typedoc "A passkey of the person's account as this CYFR knows it."
  @type listed :: %{kid: String.t(), sessions: pos_integer(), signed_in_at: DateTime.t()}

  @doc "The context person's passkeys signed in here, newest sign-in first (the module doc)."
  @spec list(Context.t()) :: {:ok, [listed()]} | {:error, :unauthenticated}
  def list(%Context{} = ctx) do
    with {:ok, user_id} <- person(ctx) do
      passkeys =
        user_id
        |> signed_in()
        |> Enum.group_by(& &1.kid)
        |> Enum.map(fn {kid, rows} ->
          %{
            kid: kid,
            sessions: length(rows),
            signed_in_at: rows |> Enum.map(& &1.inserted_at) |> Enum.max(DateTime)
          }
        end)
        |> Enum.sort_by(& &1.signed_in_at, {:desc, DateTime})

      {:ok, passkeys}
    end
  end

  @doc """
  End every session here the context person's passkey `kid` signed for
  (the module doc), in one statement (`Arca.SessionStorage.delete_signed_by/2`);
  once it has committed, each ended session's memo is dropped and the
  revocation announced. Answers `%{kid, sessions}`, how many ended;
  `{:not_found, "passkey", kid}` for a key that signed none of theirs;
  `:unavailable` when the store could not delete them, with nothing ended
  and nothing announced.
  """
  @spec revoke(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def revoke(%Context{} = ctx, kid) when is_binary(kid) do
    with {:ok, user_id} <- person(ctx) do
      case Arca.SessionStorage.delete_signed_by(Context.actor(ctx), kid) do
        {:ok, []} ->
          {:error, {:not_found, "passkey", kid}}

        {:ok, hashes} ->
          :ok = Sanctum.Session.announce_revoked(user_id, hashes)
          {:ok, %{kid: kid, sessions: length(hashes)}}

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  # The person's standing sessions a passkey of their account signed for.
  # A row that cannot be read is no passkey's: the list shows fewer, and
  # grants nothing.
  defp signed_in(user_id) do
    for hash <- Arca.SessionStorage.hashes_by_user(user_id),
        {:ok, %{provider: "passkey", kid: kid} = row} <- [Arca.SessionStorage.get_session(hash)],
        is_binary(kid),
        do: %{kid: kid, hash: hash, inserted_at: row.inserted_at}
  end

  # A person signed in, off the guest plane.
  defp person(%Context{plane: :guest}), do: {:error, :unauthenticated}

  defp person(%Context{user_id: user_id} = ctx) when is_binary(user_id) do
    if ctx.authenticated and not ctx.anonymous and Prima.PersonId.person?(user_id),
      do: {:ok, user_id},
      else: {:error, :unauthenticated}
  end

  defp person(%Context{}), do: {:error, :unauthenticated}
end
