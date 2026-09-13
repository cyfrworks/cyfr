# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RuntimeConfigWiringTest do
  @moduledoc """
  Evaluates runtime.exs outside its test-environment guard to check
  resolver wiring, release selection, and deployment validation.

  `Config.Reader.read!/2` evaluates the file the way a booting release does,
  without applying the result, so the prod branch can be exercised from the
  test run.
  """
  use ExUnit.Case, async: false

  @root Path.expand("../../../..", __DIR__)

  # Enough for the prod branch to reach the database section; everything else
  # has a default or is gated behind a knob this test does not set.
  defp base_env do
    %{
      "CYFR_SECRET_KEY_BASE" => Base.encode64(:crypto.strong_rand_bytes(48)),
      "RELEASE_NAME" => "cyfr"
    }
  end

  defp with_env(overrides, fun) do
    env = Map.merge(base_env(), overrides)
    previous = Map.new(env, fn {k, _} -> {k, System.get_env(k)} end)

    try do
      Enum.each(env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      fun.()
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp read_prod_config! do
    Config.Reader.read!(Path.join(@root, "config/runtime.exs"),
      env: :prod,
      imports: :disabled
    )
  end

  describe "the prod branch evaluates" do
    test "with only the required secrets set" do
      with_env(%{"CYFR_DATABASE" => nil}, fn ->
        config = read_prod_config!()

        assert is_list(config)
        assert Keyword.has_key?(config, :cyfr)
      end)
    end

    test "and supplies connection config for the adapter that was built" do
      with_env(%{"CYFR_DATABASE" => nil}, fn ->
        repo_config = read_prod_config!() |> get_in([:cyfr, Arca.Repo])

        assert is_list(repo_config)

        case Cyfr.RuntimeConfig.repo_adapter() do
          Ecto.Adapters.SQLite3 ->
            # SQLite-only keys must be present here and never in a Postgres
            # build — the split config.exs documents.
            assert Keyword.has_key?(repo_config, :database)
            assert repo_config[:journal_mode] == :wal

          Ecto.Adapters.Postgres ->
            assert Keyword.has_key?(repo_config, :url)
            refute Keyword.has_key?(repo_config, :journal_mode)
        end
      end)
    end
  end

  describe "CYFR_DATABASE — the one setting `.env` cannot decide" do
    # Verify .env selection agrees with the compile-time adapter; Ecto cannot switch adapters at runtime.

    test "agreeing with the built adapter is accepted" do
      built =
        case Cyfr.RuntimeConfig.repo_adapter() do
          Ecto.Adapters.SQLite3 -> "sqlite"
          Ecto.Adapters.Postgres -> "postgres"
        end

      with_env(%{"CYFR_DATABASE" => built}, fn ->
        assert is_list(read_prod_config!())
      end)
    end

    test "asking for the adapter that was NOT built refuses the boot" do
      other =
        case Cyfr.RuntimeConfig.repo_adapter() do
          Ecto.Adapters.SQLite3 -> "postgres"
          Ecto.Adapters.Postgres -> "sqlite"
        end

      with_env(%{"CYFR_DATABASE" => other}, fn ->
        error = assert_raise RuntimeError, fn -> read_prod_config!() end

        assert Exception.message(error) =~ "CYFR_DATABASE asks for"
        assert Exception.message(error) =~ "chosen when the release is COMPILED"
      end)
    end

    test "an unrecognised value refuses the boot rather than defaulting" do
      with_env(%{"CYFR_DATABASE" => "mysql"}, fn ->
        error = assert_raise RuntimeError, fn -> read_prod_config!() end
        assert Exception.message(error) =~ "unknown CYFR_DATABASE=mysql"
      end)
    end

    test "an empty value is a blank line, not a request" do
      # Copying `.env.example` leaves `CYFR_DATABASE=` behind; that must read
      # as "unset", matching the blank-vs-unset doctrine this file documents.
      with_env(%{"CYFR_DATABASE" => ""}, fn ->
        assert is_list(read_prod_config!())
      end)
    end
  end
end
