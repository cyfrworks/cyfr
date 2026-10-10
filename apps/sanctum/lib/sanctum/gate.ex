# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate do
  @moduledoc """
  The gate's admission entries: the one way an operation is dispatched or
  a stream opened from outside the gate, and nothing else.

  Two entries dispatch, one per plane — `call_external/4` for a person,
  a key or the console, `call_in_chain/5` for a running chain under its
  authority — and every refusal either makes before a handler runs is a
  `%Prima.Refusal{stage: :admission}`. Streams have one entry of their
  own, `open_stream/3`, which admits a declared stream once and answers a
  bounded grant (`Sanctum.Streams`). Every call either entry decides is
  recorded as one admission decision (`Sanctum.Decisions`). These are the
  gate's rows on the host's admission roster, and this module defines no
  other function.

  What else a caller outside Sanctum needs of the gate it calls on the
  module that owns it, under one name: the table this member wrote at
  boot and its reads (`Sanctum.Catalog`, which the composition root also
  names to load it, and whose refusal to be read before then the
  readiness probe names, `Sanctum.Catalog.NotLoadedError`), the
  annotations its declarations carry (`Sanctum.Annotations`), the
  resource index (`Sanctum.Resources`), discovery's narrowing to a
  context (`Sanctum.Visibility`), a refusal's class and sentence
  (`Sanctum.Refusals`), the decision an entry that decides on its own, a
  webhook or a schedule's fire, records (`Sanctum.Decisions`), and the
  cancellation of a call the gate is running (`Sanctum.RunningTasks`).
  `Sanctum.VirtualTools` declares the assistant's virtual tools,
  dispatched inside a formula rather than through the table; the catalog
  classifies them from it, and Aqua and Compendium read it.
  """

  alias Sanctum.Catalog

  @doc "Call a tool from the external plane (`Sanctum.Catalog.call_external/4`)."
  @spec call_external(String.t(), Sanctum.Context.t(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defdelegate call_external(name, ctx, args, opts \\ []), to: Catalog

  @doc "Call a tool from inside a running chain (`Sanctum.Catalog.call_in_chain/5`)."
  @spec call_in_chain(String.t(), Sanctum.Context.t(), term(), Prima.Authority.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defdelegate call_in_chain(name, ctx, args, authority, opts \\ []), to: Catalog

  @doc """
  Open a declared stream (`Sanctum.Streams.open/3`): one decision, and a
  `Prima.StreamGrant` naming the stream's bus roster key, its projection,
  the subject and the deadline, or the admission refusal. `subject` is
  nil for a stream that takes none. The delivery owner above the gate
  subscribes and enforces the grant.
  """
  @spec open_stream(Sanctum.Context.t(), String.t(), String.t() | nil) ::
          {:ok, Prima.StreamGrant.t()} | {:error, Prima.Refusal.t()}
  defdelegate open_stream(ctx, name, subject \\ nil), to: Sanctum.Streams, as: :open
end
