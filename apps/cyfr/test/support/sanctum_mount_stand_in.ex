# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Mount do
  @moduledoc """
  A test-only stand-in for the login-entry reads of `Sanctum.Mount`, which
  slice S1's Sanctum half builds on its own branch: the three functions the
  programs side calls, with the contract's signatures, answering from login
  entries a test puts (`put_login/2`). Removed when that half is merged,
  which defines the module itself.
  """

  @doc "Put a login entry of `athanor_id`: `%{id, name, program, status}`."
  def put_login(athanor_id, %{id: _, name: _, program: _} = entry) do
    entries = :persistent_term.get({__MODULE__, athanor_id}, %{})
    entry = Map.put_new(entry, :status, "active")
    :persistent_term.put({__MODULE__, athanor_id}, Map.put(entries, entry.id, entry))
  end

  @doc "Forget every login entry of `athanor_id`."
  def clear(athanor_id), do: :persistent_term.erase({__MODULE__, athanor_id})

  def login_entry(%Sanctum.Context{athanor_id: athanor_id}, entry, program) do
    found =
      athanor_id
      |> entries()
      |> Map.values()
      |> Enum.find(&(&1.id == entry or &1.name == entry))

    case found do
      %{status: "active", program: ^program} = e -> {:ok, %{id: e.id, name: e.name}}
      nil -> {:error, :not_found}
      _ -> {:error, :not_usable}
    end
  end

  def home_of(athanor_id, entry_id) do
    cond do
      unavailable?() -> {:error, :unavailable}
      entry = entries(athanor_id)[entry_id] -> {:ok, entry.id}
      true -> :none
    end
  end

  def login_entries(athanor_id) do
    if unavailable?(),
      do: {:error, :unavailable},
      else:
        {:ok,
         for({id, e} <- entries(athanor_id), e.status != "tombstoned", do: id) |> Enum.sort()}
  end

  @doc "Answer every read `{:error, :unavailable}` while `on?`, as a vault outage would."
  def unavailable(on?), do: :persistent_term.put({__MODULE__, :unavailable}, on?)

  defp unavailable?, do: :persistent_term.get({__MODULE__, :unavailable}, false)

  defp entries(athanor_id), do: :persistent_term.get({__MODULE__, athanor_id}, %{})
end
