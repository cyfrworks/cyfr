# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PlatformSettingsReadTest do
  @moduledoc """
  Sanctum reads a platform setting from Arca, below it: through
  `Arca.PlatformSettings.effective/1`, with no host module named. The host
  declares the settings and installs their defaults at its boot; this
  suite boots Arca and Sanctum with no host, so it proves both halves of
  that: nothing is installed by the boot (and so no child of either read a
  setting at its own start), and once a declaration is installed the
  accessor answers the default and then the stored row.
  """

  # The installation is one process-wide term.
  use ExUnit.Case, async: false

  alias Arca.PlatformSettings

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    before = PlatformSettings.installed()

    on_exit(fn ->
      if before,
        do: PlatformSettings.install_defaults!(before),
        else: PlatformSettings.uninstall()
    end)

    {:ok, before: before}
  end

  test "a boot of Arca and Sanctum without the host installs no setting", %{before: before} do
    # Only a host installs a declaration: where none booted, there is none,
    # and every read answers that it is uninstalled rather than a value.
    started = Enum.map(Application.started_applications(), &elem(&1, 0))
    assert :arca in started and :sanctum in started

    if :cyfr not in started do
      assert before == nil
      assert PlatformSettings.effective("session_ttl_hours") == {:error, :uninstalled}
    end
  end

  test "with a declaration installed, Sanctum's setting reads its default, then its row" do
    PlatformSettings.install_defaults!(%{"session_ttl_hours" => %{default: 720, stale: :refuse}})

    assert PlatformSettings.effective("session_ttl_hours") == {:ok, 720}

    {:ok, %{revision: revision}} = PlatformSettings.all()
    {:ok, _next} = PlatformSettings.put("session_ttl_hours", 24, revision, "operator@example.com")

    assert PlatformSettings.effective("session_ttl_hours") == {:ok, 24}
  end
end
