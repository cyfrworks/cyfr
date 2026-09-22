# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cluster.Fixtures do
  @moduledoc """
  The rows a two-node case works on, made **on a member** and committed.

  Nothing here is checked out of a sandbox: a cluster member runs the real
  pool, and a fixture that rolled back at the end of a case would take the
  cell's own rows with it. Each fixture is therefore named uniquely for
  the case that made it, and left behind — the cluster database is the
  suite's own and is recreated, not reused.

  The functions run on whichever member a case names, which is itself part
  of what is under test: an athanor made on one member is read by the
  other because it is a row, not because anything was shared.
  """

  @compile {:no_warn_undefined, [Arca.Athanors, Arca.ThreadStorage, Cyfr.Actor, Cyfr.UUID7]}

  @doc "An athanor of this case's own, created on the member this runs on."
  @spec athanor!(String.t()) :: map()
  def athanor!(label) do
    id = Cyfr.UUID7.generate_id("ath")
    slug = "cell-#{label}-#{System.unique_integer([:positive])}"

    {:ok, athanor} =
      Arca.Athanors.insert(Cyfr.Actor.system(), %{
        id: id,
        kind: "group",
        name: "Cluster #{label}",
        slug: slug,
        created_by: "system"
      })

    %{id: athanor.id, slug: athanor.slug}
  end

  @doc "An actor in `athanor_id`, as every fixture here writes under."
  @spec actor(String.t()) :: struct()
  def actor(athanor_id), do: Cyfr.Actor.in_athanor(athanor_id)

  @doc "A thread of `athanor_id`, with no turn holding it."
  @spec thread!(String.t(), String.t()) :: map()
  def thread!(athanor_id, title) do
    {:ok, thread} = Arca.ThreadStorage.create(actor(athanor_id), %{title: title})
    %{id: thread.id, athanor_id: athanor_id}
  end

  @doc "The thread row as it reads on this member, for a case to look at ownership."
  @spec thread(String.t(), String.t()) :: map() | nil
  def thread(athanor_id, thread_id) do
    case Arca.ThreadStorage.get(actor(athanor_id), thread_id) do
      {:ok, thread} -> thread
      _absent -> nil
    end
  end
end
