# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Mix.Tasks.Cyfr.Locus.DevStackTest do
  @moduledoc """
  `mix cyfr.locus.dev_stack` reads `.env` and the environment as a mix
  boot does, and answers what the source development stack's runtime
  needs: the key derived for its service id (checked against
  `tests/fixtures/worker_auth.json`) and the host API's port, or the
  endpoint's port; a setting that would send runs or the runtime's calls
  elsewhere is refused by name, and a root set nowhere with exit status 3.

  The working directory, the shell and the variables are node-wide, so
  this module runs alone and restores them.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Cyfr.Locus.DevStack

  @fixture Path.expand("../../../../tests/fixtures/worker_auth.json", __DIR__)
  @external_resource @fixture
  @vectors @fixture |> File.read!() |> Jason.decode!()

  @names ~w(RELEASE_ROOT CYFR_LOCUS_RUNTIME_ROOT CYFR_LOCUS_RUNTIME_WORKERS CYFR_HOST_API_BIND
            CYFR_HOST_API_URL CYFR_HOST_API_PORT CYFR_PORT CYFR_ACCESS)
  @worker_url "http://127.0.0.1:4200"
  @gateway "172.16.231.1"

  setup %{tmp_dir: dir} do
    shell = Mix.shell()
    cwd = File.cwd!()
    saved = Map.new(@names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      File.cd!(cwd)
      Mix.shell(shell)

      for {name, value} <- saved,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    Mix.shell(Mix.Shell.Process)
    Enum.each(@names, &System.delete_env/1)
    File.cd!(dir)
    :ok
  end

  defp service, do: @vectors["service"]
  defp root, do: @vectors["root_hex"]
  defp key_line, do: "LOCUS_RUNTIME_KEY=" <> @vectors["keys"]["worker_hex"]

  defp env_file(text), do: File.write!(".env", text)

  defp key!, do: DevStack.run(["key", service(), @worker_url, @gateway])

  defp answered(lines) do
    for line <- lines, do: assert_received({:mix_shell, :info, [^line]})
    refute_received {:mix_shell, _, _}
  end

  # `Mix.raise/2` keeps the exit status in `:mix`.
  defp refused(message, status \\ 1) do
    error = assert_raise Mix.Error, &key!/0
    assert Exception.message(error) =~ message
    assert error.mix == status
    refute_received {:mix_shell, _, _}
  end

  describe "key" do
    @describetag :tmp_dir

    test "derives the service's key from the root .env holds, in every form the boot reads" do
      for text <- [
            "CYFR_LOCUS_RUNTIME_ROOT=#{root()}\n",
            "CYFR_LOCUS_RUNTIME_ROOT = #{root()}\n",
            "CYFR_LOCUS_RUNTIME_ROOT=#{root()} # the stack's root\n",
            "CYFR_LOCUS_RUNTIME_ROOT=\nCYFR_LOCUS_RUNTIME_ROOT=#{root()}\n"
          ] do
        env_file(text)
        key!()
        answered([key_line(), "CYFR_HOST_API_PORT=4300"])
      end
    end

    test "the environment's root stands over the file's, and its host API port is answered" do
      env_file(
        "CYFR_LOCUS_RUNTIME_ROOT=#{String.duplicate("cd", 32)}\nCYFR_HOST_API_PORT = 4311\n"
      )

      System.put_env("CYFR_LOCUS_RUNTIME_ROOT", root())
      key!()
      answered([key_line(), "CYFR_HOST_API_PORT=4311"])
    end

    test "a root set nowhere, or empty in .env alone, is refused with status 3" do
      refused("CYFR_LOCUS_RUNTIME_ROOT is set in neither .env nor the environment", 3)

      env_file("CYFR_LOCUS_RUNTIME_ROOT=\n")
      refused("CYFR_LOCUS_RUNTIME_ROOT is set in neither .env nor the environment", 3)
    end

    test "a root the environment sets empty over the file's is refused, not replaced" do
      env_file("CYFR_LOCUS_RUNTIME_ROOT=#{root()}\n")
      System.put_env("CYFR_LOCUS_RUNTIME_ROOT", "")
      refused("CYFR_LOCUS_RUNTIME_ROOT is set empty in the environment, which overrides .env")
    end

    test "a malformed root is refused by name" do
      for text <- ["abc", String.duplicate("g", 64), "  "] do
        System.put_env("CYFR_LOCUS_RUNTIME_ROOT", text)
        refused("CYFR_LOCUS_RUNTIME_ROOT is not 64 hexadecimal digits")
      end
    end

    test "workers, a bind and a host API URL that agree with the stack are accepted" do
      env_file("""
      CYFR_LOCUS_RUNTIME_ROOT=#{root()}
      CYFR_LOCUS_RUNTIME_WORKERS = #{service()}=#{@worker_url}
      CYFR_HOST_API_BIND=#{@gateway}
      CYFR_HOST_API_URL=http://#{@gateway}:4300/
      """)

      key!()
      answered([key_line(), "CYFR_HOST_API_PORT=4300"])
    end

    test "workers, a bind or a host API URL elsewhere, from .env or the environment, is refused by name" do
      env_file("CYFR_LOCUS_RUNTIME_ROOT=#{root()}\n")

      for {name, value} <- [
            {"CYFR_LOCUS_RUNTIME_WORKERS", "wrk_elsewhere=http://127.0.0.1:4999"},
            {"CYFR_LOCUS_RUNTIME_WORKERS", "#{service()}=#{@worker_url},wrk_two=http://h:1"},
            {"CYFR_HOST_API_BIND", "0.0.0.0"},
            {"CYFR_HOST_API_URL", "http://cyfr:4300"}
          ] do
        env_file("CYFR_LOCUS_RUNTIME_ROOT=#{root()}\n#{name} = #{value} # a note\n")
        refused("#{name} is #{value}, and the dev stack needs")
        File.rm!(".env")

        env_file("CYFR_LOCUS_RUNTIME_ROOT=#{root()}\n")
        System.put_env(name, value)
        refused("#{name} is #{value}, and the dev stack needs")
        System.delete_env(name)
      end

      # The URL follows the port the host API listens on.
      env_file(
        "CYFR_LOCUS_RUNTIME_ROOT=#{root()}\nCYFR_HOST_API_PORT=4311\n" <>
          "CYFR_HOST_API_URL=http://#{@gateway}:4300\n"
      )

      refused(
        "CYFR_HOST_API_URL is http://#{@gateway}:4300, and the dev stack needs " <>
          "http://#{@gateway}:4311"
      )
    end

    test "a malformed workers entry or port is refused with its resolver's sentence" do
      env_file("CYFR_LOCUS_RUNTIME_ROOT=#{root()}\nCYFR_LOCUS_RUNTIME_WORKERS=runtime\n")
      refused("CYFR_LOCUS_RUNTIME_WORKERS entry \"runtime\" is not <service_id>=<url>")

      env_file("CYFR_LOCUS_RUNTIME_ROOT=#{root()}\nCYFR_HOST_API_PORT=65536\n")
      refused("CYFR_HOST_API_PORT=\"65536\" is not a port from 1 to 65535.")
    end
  end

  describe "endpoint" do
    @describetag :tmp_dir

    test "answers the loopback listener's port, from .env or its default" do
      DevStack.run(["endpoint"])
      answered(["CYFR_PORT=4000"])

      env_file("CYFR_PORT = 4555\n")
      DevStack.run(["endpoint"])
      answered(["CYFR_PORT=4555"])
    end
  end

  # A release reads the .env at RELEASE_ROOT, the stack's mix boot the
  # checkout's: with it set the two would read two files, so nothing is
  # read, a root set nowhere included, and nothing is answered.
  @tag :tmp_dir
  test "RELEASE_ROOT set refuses every command before anything is read", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "release"))

    File.write!(
      Path.join(dir, "release/.env"),
      "CYFR_LOCUS_RUNTIME_ROOT=#{root()}\nCYFR_PORT=4557\n"
    )

    for release_root <- [Path.join(dir, "release"), ""],
        args <- [["key", service(), @worker_url, @gateway], ["endpoint"], []] do
      System.put_env("RELEASE_ROOT", release_root)
      error = assert_raise Mix.Error, fn -> DevStack.run(args) end

      assert Exception.message(error) ==
               "RELEASE_ROOT is set, and it names a release: the dev stack runs CYFR from the " <>
                 "checkout, which reads the .env at its root. Unset RELEASE_ROOT and run again."

      assert error.mix == 1
      refute_received {:mix_shell, _, _}
    end
  end

  @tag :tmp_dir
  test "any other arguments are refused with the usage" do
    for args <- [[], ["key", service()], ["endpoint", "x"]] do
      error = assert_raise Mix.Error, fn -> DevStack.run(args) end
      assert Exception.message(error) =~ "usage: mix cyfr.locus.dev_stack"
    end
  end
end
