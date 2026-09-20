# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Actor do
  @moduledoc """
  Who work runs for. An actor is the projection of a `Sanctum.Context` that
  Arca's facades and the bus accept, and what an assignment carries to a
  worker: the tenant (`athanor_id`), the person (`user_id`), the ingress
  request that started it (`request_id`), whether the caller authenticated
  (`authenticated`), the caller's resolved address (`client_ip`), the
  authorization plane the call is on (`plane`), whether the originating
  caller presented no credentials (`anonymous`), the tenancy scope its
  reads run under (`scope`) and whether it is the server acting as itself
  (`system`). It attributes work and authorizes nothing: what an execution
  may do is its authority's (`Cyfr.Authority`).

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

  `scope` and `system` are the two authorities Arca decides on, and they
  are two fields because they answer two questions. `scope: :platform`
  reads rows across every tenant rather than the actor's own; the record
  readers — executions, schedules, policy and MCP logs — are the callers
  that have it. `system: true` mutates the seed, global and
  tenant-reserved paths an ordinary caller may not touch. Neither implies
  the other: the server's own actor (`system/0`) holds both, and an
  internal task working inside one athanor holds `system: true` with
  `scope: :athanor` and still reads that one tenant. One field could not
  carry both without widening whichever of the two it was asked for.

  On the wire (`to_wire/1`) an actor is a JCS-ready map with string keys
  carrying exactly four members: `authenticated`, always present, and
  `user_id`, `request_id` and `client_ip`, each only when it is set. The
  athanor is a top-level field of the assignment, and the plane, the
  anonymous flag, the scope and the system flag never cross the wire:
  `from_wire/1` refuses all four as unknown members and yields their
  defaults. A worker holds only the authority its assignment was issued
  with, so the two members that would let a returned actor read another
  tenant's rows or write a shared path are exactly the two the decoder
  will not take from it.
  """

  defstruct user_id: nil,
            request_id: nil,
            authenticated: false,
            client_ip: nil,
            athanor_id: nil,
            plane: :external,
            anonymous: false,
            scope: :athanor,
            system: false

  @type plane :: :external | :guest

  @typedoc """
  The tenancy scope an actor's reads run under: its own athanor, or every
  athanor. `:platform` is the cross-tenant read `Sanctum.Context`
  constructs only through its internal builder.

  The vocabulary is `Cyfr.TenancyScope`'s, where the identity domain and
  the stored membership row read it too.
  """
  @type scope :: Cyfr.TenancyScope.t()

  @type t :: %__MODULE__{
          user_id: String.t() | nil,
          request_id: String.t() | nil,
          authenticated: boolean(),
          client_ip: String.t() | nil,
          athanor_id: String.t() | nil,
          plane: plane(),
          anonymous: boolean(),
          scope: scope(),
          system: boolean()
        }

  @optional ["user_id", "request_id", "client_ip"]
  @max_bytes 256
  @keys ["authenticated" | @optional]

  @doc """
  The server's own actor: the control plane acting as itself, for work no
  caller asked for — provisioning a seeded tree, sweeping storage,
  recovering after a restart.

  It carries no tenant and no person, `scope: :platform` so it reads
  across athanors, and `system: true` so it may mutate the seed, global
  and tenant-reserved paths. `authenticated: false`, because nothing
  authenticated: its authority is the `system` flag, never a credential
  someone presented.

  An internal task that works inside one athanor narrows this actor rather
  than widening a caller's:
  `%{Cyfr.Actor.system() | athanor_id: id, scope: :athanor}` keeps the
  system authority and gives up the cross-tenant read.
  """
  @spec system() :: t()
  def system do
    %__MODULE__{athanor_id: nil, authenticated: false, scope: :platform, system: true}
  end

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
  `user_id`, `request_id` or `client_ip` is nil. `athanor_id`, `plane`,
  `anonymous`, `scope` and `system` are not wire members: present, they are
  refused as unknown; the decoded actor carries their defaults, so what
  comes back from a worker is athanor-scoped and not the system.
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
