# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ResourceReadAuditTest do
  # Not async: reads the live resource registry the application owns.
  use ExUnit.Case, async: false

  alias Emissary.MCP.ResourceRegistry
  alias Sanctum.Context

  @moduledoc """
  `resources/read` is the one provider entry point outside the tool
  dispatcher's annotation gate — the Router leaves it unauthenticated by
  design and each provider's `read/2` enforces its own authorization. This
  audit holds every registered resource to that contract: an anonymous read
  either refuses or returns nothing beyond the caller's own (empty) context.
  A new resource that serves tenant data without a gate fails here.
  """

  test "every registered resource refuses anonymous reads or echoes only the caller" do
    anonymous =
      Context.build(
        user_id: nil,
        org_id: nil,
        permissions: [],
        auth_method: nil,
        authenticated: false
      )

    self_describing = ["sanctum://identity", "sanctum://permissions"]

    for %{"uri" => uri} <- ResourceRegistry.list_resources() do
      case ResourceRegistry.read(anonymous, uri) do
        {:error, _reason} ->
          :ok

        {:ok, _content} ->
          assert uri in self_describing,
                 "anonymous read of #{uri} succeeded — a resource read handler " <>
                   "must enforce its own authorization (the Router deliberately does not)"
      end
    end
  end
end
