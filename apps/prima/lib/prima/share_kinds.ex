# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ShareKinds do
  @moduledoc """
  What a share announces happened to it, in one place: created, its
  audience or its caps changed, its source entry rebound or rotated, and
  revoked.

  `Sanctum.Shares` emits one telemetry event per kind, the bus payload
  `Cyfr.Bus.ShareChanged` admits these kinds and no other, and the
  telemetry catalog classifies one event per kind. Each reads the list
  here; spelling it again anywhere else is drift.
  """

  @all [:created, :audience, :caps, :rebound, :rotated, :revoked]

  @type t :: :created | :audience | :caps | :rebound | :rotated | :revoked

  @doc "Every kind a share announces."
  @spec all() :: [t()]
  def all, do: @all
end
