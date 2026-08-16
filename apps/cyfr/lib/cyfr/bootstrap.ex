# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bootstrap do
  @moduledoc """
  One-shot boot task: make sure the server's Home athanor holds the seed
  bundle.

  Home is seeded by the baseline migration as a bare row; this task copies
  the bundle into it (`Compendium.AthanorSeeder`) the first time the server
  boots and marks it provisioned. A failure is logged, never fatal — the app
  keeps serving and the next boot retries.

  Disabled by `config :cyfr, provisioning_boot_enabled: false` (the test
  environment, where a boot-time write would precede any sandbox checkout).
  """

  use Task, restart: :temporary
  require Logger

  alias Compendium.AthanorSeeder
  alias Sanctum.Tenancy.Athanors

  def start_link(_opts) do
    Task.start_link(__MODULE__, :run, [])
  end

  @doc false
  def run do
    if Application.get_env(:cyfr, :provisioning_boot_enabled, true) do
      ensure_home_seeded()
    end

    :ok
  end

  defp ensure_home_seeded do
    home = Athanors.home!()

    if is_nil(home.provisioned_at) do
      case AthanorSeeder.seed(home) do
        :ok ->
          {:ok, _} = Athanors.mark_provisioned(home)
          Logger.info("[Cyfr.Bootstrap] Home athanor #{home.id} seeded from the bundle")

        {:error, reason} ->
          Logger.error(
            "[Cyfr.Bootstrap] Home athanor #{home.id} could not be seeded: #{inspect(reason)}"
          )
      end
    end
  rescue
    e ->
      Logger.error("[Cyfr.Bootstrap] Home seeding raised: #{Exception.message(e)}")
  end
end
