# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary do
  @moduledoc """
  CYFR's external application protocols: MCP in both directions, inbound
  (the JSON-RPC router, a request's response stream and its progress, and
  `subscriptions/listen`, with no session) and outbound to the external
  MCP servers it supervises; the other routes `Emissary.Router` lists;
  and the device channel.

  Each adapter carries declared operations and streams through the gate,
  but for the entries `Cyfr.Admission` names as admitting for
  themselves, and adds no domain meaning: what a fact means and how long
  it is kept belong to the module that owns the fact.

  Emissary owns the transport; each namespace registers its own tools and
  resources (see `Prima.Provider`), the assistant's `thread` and `notes`
  included (`Aqua.Providers.Thread`, `Aqua.Providers.Notes`). Shared
  primitives like `Prima.UUID7` live in the glue namespace, not here.

  Outside its own modules, no shipped module calls or aliases Emissary
  but the composition modules that wire it (`Cyfr.Application`,
  `CyfrWeb.Endpoint`, `CyfrWeb.Router`) and the boundary catalog
  (`Cyfr.Boundaries`); a roster that lists its modules names them as
  strings.
  """

  use Boundary,
    deps: [Sanctum, Arca, Cyfr, Opus, CyfrWeb],
    exports: [
      External.Proxy,
      MCP,
      MCP.Progress,
      MCP.Router,
      MCP.Subscriptions,
      Supervisor
    ],
    check: [aliases: true]
end
