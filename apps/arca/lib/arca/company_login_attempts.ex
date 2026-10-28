# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CompanyLoginAttempts do
  @moduledoc """
  Company sign-ins in flight (`Arca.Schemas.CompanyLoginAttempt`): one row
  per sign-in a person began at the company page, owned by the person and
  the session that opened it, stored by the hash of its state and never
  the state, with the OpenID Connect nonce and PKCE verifier the exchange
  needs, and its expiry on the database's clock.

  A person holds at most one: `open/2` deletes their earlier rows in the
  transaction that inserts the new one, so nothing else sweeps them, and
  every row goes with the person's `users` row.

  `consume/3` answers a row once: a conditional write that marks it
  consumed only while it is unconsumed, unexpired and the presenting
  session's, so a replayed or late callback, or one from another
  session, finds nothing. Consumption is final whatever follows it.
  """

  import Ecto.Query

  alias Arca.Schemas.CompanyLoginAttempt

  @typedoc "An attempt as `consume/3` answers it."
  @type row :: %{
          id: String.t(),
          user_id: String.t(),
          session_hash: binary(),
          nonce: String.t() | nil,
          pkce_verifier: String.t() | nil,
          expires_at: DateTime.t()
        }

  @doc """
  Open an attempt: `attrs` names the `:user_id`, the `:session_hash` of
  the session that opens it, the `:state_hash` (each a SHA-256), the
  `:nonce` and `:pkce_verifier` (nil for an issuer that takes none) and
  its `:lifetime_ms`. Answers `%{id, expires_at}`; the platform's own
  actor alone opens one.
  """
  @spec open(Prima.Actor.t(), map()) ::
          {:ok, %{id: String.t(), expires_at: DateTime.t()}}
          | {:error, :cross_tenant | :database_error}
  def open(%Prima.Actor{scope: :platform, system: true}, %{lifetime_ms: lifetime_ms} = attrs)
      when is_integer(lifetime_ms) and lifetime_ms > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.CompanyLoginAttempts.open", fn ->
      fn ->
        now = Arca.ServerMetaStorage.now!()

        Arca.Repo.delete_all(from(a in CompanyLoginAttempt, where: a.user_id == ^attrs.user_id))

        row = %{
          id: Prima.UUID7.generate_id("cla"),
          user_id: attrs.user_id,
          session_hash: attrs.session_hash,
          state_hash: attrs.state_hash,
          nonce: attrs[:nonce],
          pkce_verifier: attrs[:pkce_verifier],
          expires_at: DateTime.add(now, lifetime_ms, :millisecond)
        }

        {1, _} = Arca.Repo.insert_all(CompanyLoginAttempt, [row])
        Map.take(row, [:id, :expires_at])
      end
      |> Arca.Repo.locking_transaction()
    end)
  end

  def open(%Prima.Actor{}, _attrs), do: {:error, :cross_tenant}

  @doc """
  Consume the attempt whose state hashes to `state_hash`, opened by the
  session whose token hashes to `session_hash` (the module doc). Answers
  the row, or `{:error, :not_found}` for one that is unknown, another
  session's, consumed or expired, alike.
  """
  @spec consume(Prima.Actor.t(), binary(), binary()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def consume(%Prima.Actor{scope: :platform, system: true}, state_hash, session_hash)
      when is_binary(state_hash) and is_binary(session_hash) do
    Arca.Repo.Errors.with_db_rescue("Arca.CompanyLoginAttempts.consume", fn ->
      fn ->
        now = Arca.ServerMetaStorage.now!()

        # arca:unscoped-ok an attempt is addressed by the hash of the state its caller holds and the session that opened it.
        live =
          from(a in CompanyLoginAttempt,
            where:
              a.state_hash == ^state_hash and a.session_hash == ^session_hash and
                is_nil(a.consumed_at) and a.expires_at > ^now
          )

        case Arca.Repo.update_all(live, set: [consumed_at: now]) do
          {1, _} ->
            Arca.Repo.one!(
              from(a in CompanyLoginAttempt,
                where: a.state_hash == ^state_hash,
                select: %{
                  id: a.id,
                  user_id: a.user_id,
                  session_hash: a.session_hash,
                  nonce: a.nonce,
                  pkce_verifier: a.pkce_verifier,
                  expires_at: a.expires_at
                }
              )
            )

          {0, _} ->
            Arca.Repo.rollback(:not_found)
        end
      end
      |> Arca.Repo.locking_transaction()
    end)
  end

  def consume(%Prima.Actor{}, _state_hash, _session_hash), do: {:error, :cross_tenant}
end
