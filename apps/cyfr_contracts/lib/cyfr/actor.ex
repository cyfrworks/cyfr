# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Actor do
  @moduledoc """
  Who work runs for. An actor is the projection of a `Sanctum.Context` that
  Arca's facades and the bus accept, and what an assignment carries to a
  worker: the tenant (`athanor_id`), the person (`user_id`), the ingress
  request that started it (`request_id`), whether the caller authenticated,
  the caller's resolved address (`client_ip`), the authorization plane the
  call is on (`plane`) and whether the originating caller presented no
  credentials (`anonymous`). It attributes work and authorizes nothing:
  what an execution may do is its authority's (`Cyfr.Authority`).

  `plane` is `:external` for every real ingress and `:guest` once the
  context has entered a WASM closure (`Sanctum.Context.enter_guest/1`); an
  actor never leaves the guest plane.

  `anonymous: true` and `athanor_id: nil` mean different things, and
  neither is a sentinel. `anonymous: true` is a guest or unauthenticated
  caller that has a tenant — a public tincture invocation runs as one.
  `athanor_id: nil` is no tenant resolved at all. A facade that takes the
  actor matches `%Cyfr.Actor{athanor_id: id} when is_binary(id)` and
  refuses a nil athanor before any query, so the two stay distinguishable
  in every result.

  On the wire (`to_wire/1`) an actor is a JCS-ready map with string keys
  carrying exactly four members: `authenticated`, always present, and
  `user_id`, `request_id` and `client_ip`, each only when it is set. The
  athanor is a top-level field of the assignment, and the plane and the
  anonymous flag never cross the wire: `from_wire/1` refuses all three as
  unknown members and yields their defaults.
  """

  defstruct user_id: nil,
            request_id: nil,
            authenticated: false,
            client_ip: nil,
            athanor_id: nil,
            plane: :external,
            anonymous: false

  @type plane :: :external | :guest

  @type t :: %__MODULE__{
          user_id: String.t() | nil,
          request_id: String.t() | nil,
          authenticated: boolean(),
          client_ip: String.t() | nil,
          athanor_id: String.t() | nil,
          plane: plane(),
          anonymous: boolean()
        }

  @optional ["user_id", "request_id", "client_ip"]
  @max_bytes 256
  @keys ["authenticated" | @optional]

  @doc "The actor as its wire map: the four wire members and nothing else."
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
  `user_id`, `request_id` or `client_ip` is nil. `athanor_id`, `plane` and
  `anonymous` are not wire members: present, they are refused as unknown;
  the decoded actor carries their defaults.
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
