# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Actor do
  @moduledoc """
  Who an execution runs for, as an assignment carries it to a worker: the
  person (`user_id`), the ingress request that started it (`request_id`),
  whether the caller authenticated, and the caller's resolved address
  (`client_ip`). It attributes work and authorizes nothing: what an
  execution may do is its authority's (`Cyfr.Authority`).

  On the wire (`to_wire/1`) an actor is a JCS-ready map with string keys:
  `authenticated` is always present, and each other member only when it is
  set.
  """

  defstruct user_id: nil, request_id: nil, authenticated: false, client_ip: nil

  @type t :: %__MODULE__{
          user_id: String.t() | nil,
          request_id: String.t() | nil,
          authenticated: boolean(),
          client_ip: String.t() | nil
        }

  @optional ["user_id", "request_id", "client_ip"]
  @max_bytes 256
  @keys ["authenticated" | @optional]

  @doc "The actor as its wire map."
  @spec to_wire(t()) :: %{optional(String.t()) => String.t() | boolean()}
  def to_wire(%__MODULE__{} = actor) do
    %{"authenticated" => actor.authenticated}
    |> put_set("user_id", actor.user_id)
    |> put_set("request_id", actor.request_id)
    |> put_set("client_ip", actor.client_ip)
  end

  @doc """
  An actor back from its wire map. Fail-closed: a member other than the
  four, a missing or non-boolean `authenticated`, or a present member that
  is not a string of 1 to 256 bytes is `{:error, :invalid_actor}`. An absent
  `user_id`, `request_id` or `client_ip` is nil.
  """
  @spec from_wire(term()) :: {:ok, t()} | {:error, :invalid_actor}
  def from_wire(%{"authenticated" => authenticated} = wire) when is_boolean(authenticated) do
    with [] <- Map.keys(wire) -- @keys,
         true <- Enum.all?(@optional, &optional_string?(wire, &1)) do
      {:ok,
       %__MODULE__{
         user_id: wire["user_id"],
         request_id: wire["request_id"],
         authenticated: authenticated,
         client_ip: wire["client_ip"]
       }}
    else
      _ -> {:error, :invalid_actor}
    end
  end

  def from_wire(_wire), do: {:error, :invalid_actor}

  defp put_set(map, _key, nil), do: map
  defp put_set(map, key, value), do: Map.put(map, key, value)

  defp optional_string?(wire, key) do
    case Map.fetch(wire, key) do
      :error -> true
      {:ok, value} -> is_binary(value) and byte_size(value) in 1..@max_bytes
    end
  end
end
