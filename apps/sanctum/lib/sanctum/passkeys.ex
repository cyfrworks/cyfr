# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Passkeys do
  @moduledoc """
  The passkeys of a person's account that signed in here, as this CYFR
  knows them: each a paired client of the person's, known by the key it
  signs with (`kid`), which its first sign-in here recorded
  (`Sanctum.SignIn`, `Arca.PairedClients.record_passkey/2`) and its
  sessions stand on. A passkey lives in the account's log at the
  directory and in its person's platform; this CYFR holds no registration
  of it, and a key removed from the account ends its client and sessions
  here once a refresh reads the removal (`Sanctum.IdentityFreshness`).

  `list/1` answers the context person's passkeys that stand here, each its
  `kid`, its client (`client_id`) and when it first signed in here
  (`signed_in_at`). `revoke/2` revokes one passkey's client here, which
  ends every session it signed for and signs it out of this CYFR, and
  leaves the key in the account: its next sign-in here is recorded anew,
  and removing it from the account is the account pages'
  (`/account/devices`). The person's devices are their other paired
  clients (`Sanctum.Pairing`).
  """

  alias Sanctum.Context

  @typedoc "A passkey of the person's account as this CYFR knows it."
  @type listed :: %{kid: String.t(), client_id: String.t(), signed_in_at: DateTime.t()}

  @doc "The context person's passkeys that stand here, newest first (the module doc)."
  @spec list(Context.t()) :: {:ok, [listed()]} | {:error, :unauthenticated | :unavailable}
  def list(%Context{} = ctx) do
    with {:ok, user_id} <- person(ctx),
         {:ok, clients} <- standing(user_id) do
      passkeys =
        clients
        |> Enum.map(&%{kid: &1.kid, client_id: &1.id, signed_in_at: &1.inserted_at})
        |> Enum.sort_by(& &1.signed_in_at, {:desc, DateTime})

      {:ok, passkeys}
    end
  end

  @doc """
  Revoke the context person's passkey `kid` here (the module doc): its
  client, with every session it signed for
  (`Arca.PairedClients.revoke/2`); once that has committed, each ended
  session's memo is dropped and the revocation announced. Answers `%{kid,
  sessions}`, how many sessions ended; `{:not_found, "passkey", kid}` for
  a key with no client of theirs standing here; `:unavailable` when the
  store could not revoke it, with nothing ended and nothing announced.
  """
  @spec revoke(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def revoke(%Context{} = ctx, kid) when is_binary(kid) do
    with {:ok, user_id} <- person(ctx),
         {:ok, clients} <- standing(user_id) do
      # A passkey's client is recorded in its person's own athanor under
      # their lock, so one at most stands.
      case Enum.find(clients, &(&1.kid == kid)) do
        nil -> {:error, {:not_found, "passkey", kid}}
        client -> revoked(user_id, kid, client)
      end
    end
  end

  defp revoked(user_id, kid, client) do
    case Arca.PairedClients.revoke(Prima.Actor.in_athanor(client.athanor_id), client.id) do
      {:ok, %{revoked_session_hashes: hashes}} ->
        :ok = Sanctum.Session.announce_revoked(user_id, hashes)
        {:ok, %{kid: kid, sessions: length(hashes)}}

      {:error, _unrevoked} ->
        {:error, :unavailable}
    end
  end

  # The person's passkey clients that stand, in every athanor.
  defp standing(user_id) do
    case Arca.PairedClients.list(Prima.Actor.system(), user_id: user_id, standing: :active) do
      {:ok, clients} -> {:ok, Enum.filter(clients, &(&1.source_kind == "passkey"))}
      {:error, _unanswered} -> {:error, :unavailable}
    end
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
