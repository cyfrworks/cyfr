# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Directory do
  @moduledoc """
  The `directory` tool: the operator's acts on the directory this CYFR
  serves (`Sanctum.Directory`). Platform administrators only
  (`scope: :platform`).

  `tombstone` marks an account gone: every later read and write of its
  log answers `gone`, its entries stay, and its name stays reserved at the
  registry this CYFR serves beside it. It takes the account's
  `identifier`, and it is a sensitive change (`directory_tombstone`): the
  administrator's fresh confirmation names the identifier
  (`Sanctum.Consent.Authz.confirm/3`). Every CYFR that reads the account
  then retires what it bound to it (`Sanctum.IdentityFreshness`).
  """

  require Logger

  alias Sanctum.Consent.Authz
  alias Sanctum.Context

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    alias Prima.{Arg, Operation}

    Operation.tool(
      [
        Operation.new(
          "directory",
          "tombstone",
          "Mark an account gone at this CYFR's directory",
          [
            Arg.new("identifier", :string,
              required: true,
              description: "The account's identifier (per_…)"
            )
          ],
          scope: :platform,
          kind: :destructive,
          planes: [:external]
        )
      ],
      description:
        "The directory this CYFR serves — platform admins only. A tombstone marks an account gone: every later read and write of its log answers gone, and its name stays reserved. It needs your fresh confirmation.",
      title: "Directory"
    )
  end

  def handle(%Context{} = ctx, %{"action" => "tombstone", "identifier" => identifier})
      when is_binary(identifier) do
    with :ok <- spelled(identifier),
         :ok <-
           Authz.confirm(ctx, :directory_tombstone, %{
             operation: "directory.tombstone",
             arguments: %{"identifier" => identifier},
             resource: identifier
           }) do
      case Sanctum.Directory.tombstone(identifier) do
        :ok ->
          Logger.info("[Sanctum.Providers.Directory] #{identifier} is tombstoned")
          {:ok, %{identifier: identifier, gone: true}}

        {:error, :not_found} ->
          {:error, {:not_found, "account", identifier}}

        {:error, :not_served} ->
          {:error, {:invalid_argument, "This CYFR serves no directory"}}

        {:error, :read_only} ->
          {:error,
           {:invalid_argument,
            "This CYFR's directory is a mirror: tombstone the account at its writer"}}

        {:error, _unavailable} ->
          {:error, {:unavailable, "The directory"}}
      end
    end
  end

  def handle(_ctx, %{"action" => "tombstone"}),
    do: {:error, {:invalid_argument, "identifier is required"}}

  def handle(_ctx, %{"action" => action}),
    do: {:error, {:unknown_action, "directory.#{action}"}}

  def handle(_ctx, _args), do: {:error, :action_missing}

  defp spelled(identifier) do
    if Prima.Identity.Encoding.identifier?(identifier),
      do: :ok,
      else: {:error, {:invalid_argument, "That is not an account's identifier (per_…)"}}
  end
end
