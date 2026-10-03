# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.FrameRequestSeamTest do
  @moduledoc """
  A frame reaches no session: every pipeline that fetches a session or
  authenticates its caller refuses a request a frame made
  (`CyfrWeb.Plugs.FrameRequest`) before it does either, and the tincture
  pipelines, which a frame reaches by design, do neither.

  The pipelines are read from each route provider's source
  (`Cyfr.Test.RouterSource`), where a `CyfrWeb.Pipelines.browser/2`
  statement stands for `CyfrWeb.Pipelines.browser_plugs/1`, so a new
  pipeline in any provider is held to the rule the day it is declared.
  """

  use ExUnit.Case, async: true

  alias Cyfr.Boundaries
  alias Cyfr.Test.RouterSource

  @frame "CyfrWeb.Plugs.FrameRequest"
  @session_readers [":fetch_session", "CyfrWeb.Plugs.Authenticate"]

  # Every pipeline every route provider declares, as `{provider, name, plugs}`.
  defp pipelines do
    for router <- Boundaries.routers(),
        {name, plugs} <- RouterSource.pipelines(source(router)),
        do: {inspect(router), name, plugs}
  end

  defp source(module), do: module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()

  defp index(plugs, plug), do: Enum.find_index(plugs, &(&1 == plug))

  test "the shared browser pipeline refuses a frame before it fetches the session" do
    for opts <- [[], [root_layout: {PrismWeb.Layouts, :root}]] do
      plugs = Enum.map(CyfrWeb.Pipelines.browser_plugs(opts), &elem(&1, 0))
      frame = Enum.find_index(plugs, &(&1 == CyfrWeb.Plugs.FrameRequest))
      session = Enum.find_index(plugs, &(&1 == :fetch_session))

      assert frame != nil and session != nil and frame < session,
             "browser_plugs(#{inspect(opts)}) must refuse a frame before :fetch_session: " <>
               inspect(plugs)
    end
  end

  test "every pipeline that reads a session refuses a frame first" do
    readers =
      for {provider, name, plugs} <- pipelines(),
          Enum.any?(@session_readers, &(&1 in plugs)),
          do: {provider, name, plugs}

    # The page pipelines, the attachment pipeline, the authenticated API
    # and MCP all read one; an empty list means the source reader broke.
    assert length(readers) >= 5, "found only #{inspect(readers)}"

    for {provider, name, plugs} <- readers, reader <- @session_readers, reader in plugs do
      frame = index(plugs, @frame)

      assert frame != nil and frame < index(plugs, reader),
             "#{provider}'s #{name} pipeline runs #{reader} without refusing a frame " <>
               "before it: #{inspect(plugs)}"
    end
  end

  test "the tincture pipelines read no session and authenticate no one" do
    tinctures =
      for {provider, name, plugs} <- pipelines(),
          String.starts_with?(name, "tincture"),
          do: {provider, name, plugs}

    assert Enum.sort(Enum.map(tinctures, &elem(&1, 1))) ==
             ["tincture", "tincture_asset", "tincture_data"]

    for {provider, name, plugs} <- tinctures, reader <- @session_readers do
      refute reader in plugs, "#{provider}'s #{name} pipeline runs #{reader}"
    end
  end
end
