# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ApplicationBootTest do
  @moduledoc """
  The host's boot refuses before it mints this boot's name or worker root
  or starts any process: an unreadable platform settings table, and a
  declared stream on a topic the bus does not roster, each raise from
  `Cyfr.Application.start/2` with the message naming the cause.

  `start/2` is called in the test VM, whose application is already
  running, and the steps before the refusals are not all idempotent here:
  the boot installs the roster's settings defaults over the suite's own
  (`Cyfr.Test.Settings.install!/0`), and applies the stored settings to
  the application environment, the log level and three terms of its own.
  Each test reads that state, with the operation table, the drain mark,
  the boot's name, the worker root and the running tree, before the boot
  refuses; puts back what the boot rewrote; and asserts the whole of it
  equal to what it read.
  """

  use ExUnit.Case, async: false

  # The unreadable table is logged where it is read.
  @moduletag :capture_log

  alias Cyfr.Platform.Settings
  alias Cyfr.Platform.Settings.Roster

  # What `Cyfr.Platform.Settings.apply/0` writes at boot besides the
  # application environment and the log level.
  @applied for key <- [:active, :boot_revision, :level_from_row], do: {Settings, key}

  defmodule UnrosteredStream do
    @moduledoc false
    @behaviour Prima.Provider

    @impl true
    def service, do: "unrostered"

    @impl true
    def tools, do: []

    @impl true
    def handle(_tool, _ctx, _args), do: {:error, :unreachable}

    @impl true
    def streams do
      [
        %Prima.Provider.Stream{
          name: "unrostered.changes",
          topic: :no_such_topic,
          projection: ["kind"],
          deadline_bound: 60
        }
      ]
    end
  end

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    before = boot_state()
    on_exit(fn -> restore!(before) end)
    {:ok, before: before}
  end

  test "an unreadable platform settings table refuses the boot", %{before: before} do
    Arca.Repo.query!("DROP TABLE platform_settings")

    error = refused!(before)

    assert error.message =~
             "[Cyfr] FATAL: the platform settings could not be read. The table is created " <>
               "by the schema"
  end

  test "a configured provider's stream on a topic the bus does not roster refuses the boot",
       %{before: before} do
    Application.put_env(
      :sanctum,
      :tool_providers,
      Sanctum.Catalog.configured_providers() ++ [UnrosteredStream]
    )

    error = refused!(before)

    # The stream check's refusal, after the table loaded the provider.
    assert error.message =~
             "declared streams name topics the bus cannot carry or refreshes that do not " <>
               "exist; refusing to boot"

    assert error.message =~
             "#{inspect(UnrosteredStream)} declares unrostered.changes on :no_such_topic"
  end

  # The boot's refusal: once what the boot rewrote is put back, every part
  # of the state it could have touched is as it was, so it raised before
  # this boot's name and worker root were minted and before any process
  # started.
  defp refused!(before) do
    error = assert_raise RuntimeError, fn -> Cyfr.Application.start(:normal, []) end

    restore!(before)
    assert boot_state() == before
    error
  end

  defp boot_state do
    %{
      boot: Prima.Boot.id(),
      # A digest, so a failure never prints the root.
      worker_root: :crypto.hash(:sha256, Opus.Keys.root()),
      tree: Process.whereis(Cyfr.Supervisor),
      draining?: CyfrWeb.LiveSocket.draining?(),
      providers: Application.fetch_env(:sanctum, :tool_providers),
      operations: Sanctum.Catalog.operations(),
      tools: Sanctum.Catalog.list_tools(),
      streams: Sanctum.Catalog.stream_entries(),
      installed: Arca.PlatformSettings.installed(),
      applied: Map.new(@applied, &{&1, :persistent_term.get(&1, :absent)}),
      applied_env: Map.new(applied_env_keys(), &{&1, fetch_applied(&1)})
    }
  end

  # Where `apply/0` writes each restart-scoped setting's value: the log
  # level, and each other's application environment key.
  defp applied_env_keys do
    for %Roster.Entry{apply: {_, _, 1}} = entry <- Roster.entries() do
      case entry do
        %{key: "log_level"} -> :log_level
        %{app: app, config: [name | _]} -> {app, name}
      end
    end
  end

  defp fetch_applied(:log_level), do: Logger.level()
  defp fetch_applied({app, name}), do: Application.fetch_env(app, name)

  defp restore!(before) do
    case before.providers do
      {:ok, providers} -> Application.put_env(:sanctum, :tool_providers, providers)
      :error -> Application.delete_env(:sanctum, :tool_providers)
    end

    :ok = Sanctum.Catalog.load!()
    :ok = Cyfr.Test.Settings.install!()

    for {key, value} <- before.applied do
      if value == :absent,
        do: :persistent_term.erase(key),
        else: :persistent_term.put(key, value)
    end

    for {key, value} <- before.applied_env do
      case {key, value} do
        {:log_level, level} -> Logger.configure(level: level)
        {{app, name}, {:ok, value}} -> Application.put_env(app, name, value)
        {{app, name}, :error} -> Application.delete_env(app, name)
      end
    end

    :ok
  end
end
