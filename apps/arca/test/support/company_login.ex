# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.CompanyLogin do
  @moduledoc """
  A test's company sign-in, written as one finishes: an attempt opened
  and consumed for a session of the person's, then the binding
  (`Arca.CompanyAuthorizations.bind/3`) from that attempt with nothing
  else to verify (`verify:` names another). Answers the binding's
  answer. `consumed_attempt/1` is the attempt alone, by its id.
  """

  @spec bind(String.t(), String.t(), String.t(), keyword()) :: {:ok, atom()} | {:error, term()}
  def bind(user_id, configuration, subject, opts \\ []) do
    Arca.CompanyAuthorizations.bind(
      Prima.Actor.system(),
      %{
        user_id: user_id,
        attempt_id: consumed_attempt(user_id),
        configuration: configuration,
        subject: subject
      },
      verify: Keyword.get(opts, :verify, fn -> :ok end)
    )
  end

  @doc "Open and consume an attempt for `user_id`, as a callback does; answers its id."
  @spec consumed_attempt(String.t()) :: String.t()
  def consumed_attempt(user_id) do
    server = Prima.Actor.system()
    session_hash = :crypto.strong_rand_bytes(32)
    state_hash = :crypto.strong_rand_bytes(32)

    {:ok, %{id: attempt_id}} =
      Arca.CompanyLoginAttempts.open(server, %{
        user_id: user_id,
        session_hash: session_hash,
        state_hash: state_hash,
        lifetime_ms: 600_000
      })

    {:ok, _row} = Arca.CompanyLoginAttempts.consume(server, state_hash, session_hash)
    attempt_id
  end
end
