# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Mix.Tasks.Cyfr.Locus.DevStackTest do
  @moduledoc """
  `mix cyfr.locus.dev_stack` derives CYFR's settings for the source
  development stack from its compose declarations, reads `.env` and the
  environment as a mix boot does, provisions into `.env` what nothing
  sets, and answers the server's settings and the services' keys (the
  runtime's checked against `tests/fixtures/worker_auth.json`), or
  Prism's port; a setting that disagrees with the declarations is
  refused by name, and nothing is written when anything is refused.

  The working directory, the shell and the variables are node-wide, so
  this module runs alone and restores them.
  """

  use ExUnit.Case, async: false

  import Bitwise

  alias Mix.Tasks.Cyfr.Locus.DevStack

  @fixture Path.expand("../../../../tests/fixtures/worker_auth.json", __DIR__)
  @external_resource @fixture
  @vectors @fixture |> File.read!() |> Jason.decode!()

  @server ~w(CYFR_PORT CYFR_LOCUS_RUNTIME_WORKERS CYFR_HOST_API_BIND CYFR_HOST_API_PORT
             CYFR_LOCUS_BACKENDS_URL CYFR_PRIVATE_EGRESS_TARGETS CYFR_LOCUS_BUILDS_URL)
  @provisioned ~w(CYFR_GITHUB_CLIENT_ID CYFR_PLATFORM_ADMIN_EMAILS CYFR_LOCUS_RUNTIME_ROOT
                  CYFR_LOCUS_BACKENDS_KEY CYFR_LOCUS_BUILDS_KEY)
  @names ["RELEASE_ROOT", "CYFR_HOST_API_URL", "CYFR_BIND_ADDRESS", "CYFR_ACCESS"] ++
           @server ++ @provisioned

  @client_id "Ov23example"
  @backends_key String.duplicate("b1", 32)
  @builds_key String.duplicate("c2", 32)

  # A directory of the test's own under the partition's TMPDIR: ExUnit's
  # tmp_dir is the checkout's tmp/<module>/<test>, which two adapters run
  # in one checkout would share and delete under each other.
  setup do
    shell = Mix.shell()
    cwd = File.cwd!()
    saved = Map.new(@names, &{&1, System.get_env(&1)})

    dir =
      Path.join(
        System.tmp_dir!(),
        "dev_stack_task_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.cd!(cwd)
      File.rm_rf!(dir)
      Mix.shell(shell)

      for {name, value} <- saved,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    Mix.shell(Mix.Shell.Process)
    Enum.each(@names, &System.delete_env/1)
    File.mkdir_p!(dir)
    File.cd!(dir)
    File.write!(".env.example", "CYFR_PORT=4000\nCYFR_GITHUB_CLIENT_ID=#{@client_id}\n")
    File.write!("stack.json", Jason.encode!(declarations()))
    {:ok, dir: dir}
  end

  # docker-compose.dev.yml as `docker compose config --format json`
  # resolves it, its values the test's own, and the fields the task reads
  # among the rest.
  defp declarations do
    guard = fn network, address, port ->
      %{
        "image" => "cyfr-locus:dev",
        "expose" => [port],
        "networks" => %{network => %{"aliases" => [network], "ipv4_address" => address}}
      }
    end

    %{
      "name" => "cyfr-dev",
      "x-prism" => "127.0.0.1:4555",
      "services" => %{
        "locus-runtime" => %{
          "image" => "cyfr-locus:dev",
          "environment" => %{
            "LOCUS_RUNTIME_SERVICE_ID" => service(),
            "LOCUS_RUNTIME_HOST_API_URL" => "http://172.16.250.1:4566",
            "LOCUS_RUNTIME_KEY" => ""
          },
          "ports" => [
            %{
              "mode" => "ingress",
              "host_ip" => "127.0.0.1",
              "target" => 4200,
              "published" => "4565",
              "protocol" => "tcp"
            }
          ]
        },
        "locus-backends-guard" => guard.("locus-backends", "172.16.251.2", "4101"),
        "locus-builds-guard" => guard.("locus-builds", "172.16.252.2", "4100")
      }
    }
  end

  defp server_lines do
    [
      "server CYFR_PORT=4555",
      "server CYFR_LOCUS_RUNTIME_WORKERS=#{service()}=http://127.0.0.1:4565",
      "server CYFR_HOST_API_BIND=172.16.250.1",
      "server CYFR_HOST_API_PORT=4566",
      "server CYFR_LOCUS_BACKENDS_URL=http://172.16.251.2:4101",
      "server CYFR_PRIVATE_EGRESS_TARGETS=172.16.251.2",
      "server CYFR_LOCUS_BUILDS_URL=http://172.16.252.2:4100"
    ]
  end

  defp service, do: @vectors["service"]
  defp root, do: @vectors["root_hex"]

  defp complete,
    do: """
    CYFR_GITHUB_CLIENT_ID=#{@client_id}
    CYFR_PLATFORM_ADMIN_EMAILS=dev@example.test
    CYFR_LOCUS_RUNTIME_ROOT=#{root()}
    CYFR_LOCUS_BACKENDS_KEY=#{@backends_key}
    CYFR_LOCUS_BUILDS_KEY=#{@builds_key}
    """

  # The server's settings and the services' keys, the builds key the
  # server's too.
  defp answered(backends \\ @backends_key, builds \\ @builds_key) do
    server_lines() ++
      [
        "server CYFR_LOCUS_BUILDS_KEY=" <> builds,
        "compose LOCUS_RUNTIME_KEY=" <> @vectors["keys"]["worker_hex"],
        "compose CYFR_LOCUS_BACKENDS_KEY=" <> backends,
        "compose CYFR_LOCUS_BUILDS_KEY=" <> builds
      ]
  end

  defp settings!(admin \\ []), do: DevStack.run(["settings", "stack.json" | admin])

  defp answers do
    receive do
      {:mix_shell, :info, [line]} -> [line | answers()]
    after
      0 -> []
    end
  end

  defp refused(message, run \\ &settings!/0) do
    before = File.read(".env")
    error = assert_raise Mix.Error, run
    assert Exception.message(error) =~ message
    assert answers() == []
    assert File.read(".env") == before, ".env changed on a refusal"
  end

  defp mode(path), do: File.stat!(path).mode &&& 0o777

  describe "settings" do
    test "derives CYFR's settings from the declarations and answers each service's key" do
      File.write!(".env", complete())
      settings!()
      assert answers() == answered()
      assert File.read!(".env") == complete()
    end

    test "provisions every missing name into a new .env, mode 0600, as cyfr init mints keys" do
      settings!(["dev@example.test"])

      assert [
               "wrote CYFR_GITHUB_CLIENT_ID CYFR_PLATFORM_ADMIN_EMAILS CYFR_LOCUS_RUNTIME_ROOT " <>
                 "CYFR_LOCUS_BACKENDS_KEY"
               | rest
             ] = answers()

      assert mode(".env") == 0o600

      assert [
               "CYFR_GITHUB_CLIENT_ID=" <> @client_id,
               "CYFR_PLATFORM_ADMIN_EMAILS=dev@example.test",
               "CYFR_LOCUS_RUNTIME_ROOT=" <> minted_root,
               "CYFR_LOCUS_BACKENDS_KEY=" <> backends,
               ""
             ] = String.split(File.read!(".env"), "\n")

      # Every other mix boot of the checkout reads this .env alone, and
      # accepts it: no builds key without its URL.
      file = Cyfr.EnvFiles.source!([".env"], side_effect: false)
      assert {:ok, nil} = Cyfr.RuntimeConfig.resolve_locus_builds(&Map.get(file, &1))

      # The builds key, which a boot refuses without its URL, is the run's
      # alone, the server's as the builder's.
      "server CYFR_LOCUS_BUILDS_KEY=" <> builds = Enum.at(rest, length(server_lines()))

      for key <- [minted_root, backends, builds], do: assert(key =~ ~r/\A[0-9a-f]{64}\z/)
      assert Enum.uniq([minted_root, backends, builds]) |> length() == 3

      {:ok, runtime_key} =
        Prima.WorkerAuth.worker_key(Base.decode16!(minted_root, case: :lower), service())

      assert rest ==
               server_lines() ++
                 [
                   "server CYFR_LOCUS_BUILDS_KEY=" <> builds,
                   "compose LOCUS_RUNTIME_KEY=" <> Base.encode16(runtime_key, case: :lower),
                   "compose CYFR_LOCUS_BACKENDS_KEY=" <> backends,
                   "compose CYFR_LOCUS_BUILDS_KEY=" <> builds
                 ]

      # A second run keeps every value it wrote and writes nothing; the
      # builds key is minted afresh.
      written = File.read!(".env")
      settings!(["other@example.test"])
      again = answers()
      assert Enum.take(again, length(server_lines())) == server_lines()
      refute ("server CYFR_LOCUS_BUILDS_KEY=" <> builds) in again
      assert ("compose CYFR_LOCUS_BACKENDS_KEY=" <> backends) in again
      assert File.read!(".env") == written
    end

    test "keeps what .env or the environment sets, adding only what is missing" do
      kept = "CYFR_LOCUS_RUNTIME_ROOT = #{root()} # the stack's root"
      File.write!(".env", "# mine\n" <> kept)
      File.chmod!(".env", 0o644)
      System.put_env("CYFR_PLATFORM_ADMIN_EMAILS", "env@example.test")
      settings!()

      assert hd(answers()) ==
               "wrote CYFR_GITHUB_CLIENT_ID CYFR_LOCUS_BACKENDS_KEY"

      assert mode(".env") == 0o600

      assert [
               "# mine",
               ^kept,
               "CYFR_GITHUB_CLIENT_ID=" <> @client_id,
               "CYFR_LOCUS_BACKENDS_KEY=" <> _,
               ""
             ] = String.split(File.read!(".env"), "\n")

      # A value only the environment sets, or one .env sets empty and
      # again later, is kept as the boot reads it.
      File.write!(
        ".env",
        String.replace(
          complete(),
          "CYFR_LOCUS_BUILDS_KEY=",
          "CYFR_LOCUS_BUILDS_KEY=\nCYFR_LOCUS_BUILDS_KEY="
        )
      )

      System.put_env("CYFR_LOCUS_BACKENDS_KEY", String.duplicate("d3", 32))
      settings!()
      assert answers() == answered(String.duplicate("d3", 32), @builds_key)
    end

    test "refuses, writing nothing, when no admin email is set or given" do
      for admin <- [[], [""], ["  "]] do
        refused(
          "CYFR_PLATFORM_ADMIN_EMAILS is set in neither .env nor the environment, and the dev " <>
            "stack signs you in as its platform admin. `git config user.email` is not set. Add " <>
            "the line CYFR_PLATFORM_ADMIN_EMAILS=<your email> to .env",
          fn -> settings!(admin) end
        )

        refute File.exists?(".env")
      end
    end

    test "refuses an admin email that is not one address, writing nothing" do
      for email <- [
            "two words@example.test",
            "a@example.test\nCYFR_ACCESS=public",
            "a@b,c@d",
            "x"
          ] do
        refused(
          "`git config user.email` is #{inspect(email)}, not one address. Add the line " <>
            "CYFR_PLATFORM_ADMIN_EMAILS=<your email> to .env",
          fn -> settings!([email]) end
        )
      end
    end

    test "refuses a name the environment sets empty over .env, writing nothing" do
      for name <- @provisioned do
        File.write!(".env", complete())
        System.put_env(name, "")

        refused(
          "#{name} is set empty in the environment, which overrides .env. Unset it there",
          fn -> settings!(["dev@example.test"]) end
        )

        System.delete_env(name)
      end
    end

    test "refuses a malformed key by name" do
      for name <- ~w(CYFR_LOCUS_RUNTIME_ROOT CYFR_LOCUS_BACKENDS_KEY CYFR_LOCUS_BUILDS_KEY),
          bad <- ["abc", String.duplicate("g", 64)] do
        File.write!(".env", complete() <> "#{name}=#{bad}\n")
        refused("#{name} is not 64 hexadecimal digits. Generate one with `openssl rand -hex 32`")
      end
    end

    test "reads a key as the boot does: literal, never trimmed" do
      # A root the boot cannot decode, which trimming would have hidden.
      File.write!(".env", complete())
      System.put_env("CYFR_LOCUS_RUNTIME_ROOT", " " <> root() <> " ")
      refused("CYFR_LOCUS_RUNTIME_ROOT is not 64 hexadecimal digits")
      assert :error = Prima.MacEnvelope.decode_root(" " <> root() <> " ")

      # Whitespace alone is a value the boot reads, refused before anything
      # is written: here, nothing else is set either.
      File.rm!(".env")

      for name <- @provisioned do
        System.put_env(name, " ")

        refused(
          "#{name} holds only whitespace in .env or the environment. Remove it, or set a value.",
          fn -> settings!(["dev@example.test"]) end
        )

        refute File.exists?(".env")
        System.delete_env(name)
      end
    end

    test "reads an island key as the boot does: trimmed, then decoded" do
      File.write!(".env", complete())
      System.put_env("CYFR_LOCUS_BACKENDS_KEY", "  " <> @backends_key <> " ")
      System.put_env("CYFR_LOCUS_BUILDS_KEY", " " <> @builds_key <> "\t")

      assert {:ok, <<_::256>>} =
               Prima.EnvValue.hex_key(&System.get_env/1, "CYFR_LOCUS_BACKENDS_KEY")

      settings!()
      assert answers() == answered()
    end

    test "accepts each server setting .env or the environment sets as the declarations do" do
      File.write!(".env", """
      #{complete()}CYFR_PORT = 4555 # Prism
      CYFR_LOCUS_RUNTIME_WORKERS=#{service()}=http://127.0.0.1:4565
      CYFR_HOST_API_BIND=172.16.250.1
      CYFR_HOST_API_URL=http://172.16.250.1:4566/
      CYFR_LOCUS_BACKENDS_URL=http://172.16.251.2:4101/
      CYFR_PRIVATE_EGRESS_TARGETS= 172.16.251.2 ,
      CYFR_BIND_ADDRESS=127.0.0.1
      """)

      System.put_env("CYFR_HOST_API_PORT", "4566")
      System.put_env("CYFR_LOCUS_BUILDS_URL", "http://172.16.252.2:4100")
      settings!()
      assert answers() == answered()
    end

    test "refuses, by name, a server setting from .env or the environment that disagrees" do
      for {name, value} <- [
            {"CYFR_PORT", "4000"},
            {"CYFR_LOCUS_RUNTIME_WORKERS", "wrk_elsewhere=http://127.0.0.1:4565"},
            {"CYFR_LOCUS_RUNTIME_WORKERS", "#{service()}=http://127.0.0.1:4200"},
            {"CYFR_LOCUS_RUNTIME_WORKERS",
             "#{service()}=http://127.0.0.1:4565,wrk_two=http://h:1"},
            {"CYFR_HOST_API_BIND", "0.0.0.0"},
            {"CYFR_HOST_API_PORT", "4300"},
            {"CYFR_HOST_API_URL", "http://cyfr:4566"},
            {"CYFR_LOCUS_BACKENDS_URL", "http://locus-backends:4101"},
            {"CYFR_PRIVATE_EGRESS_TARGETS", "172.16.251.2,127.0.0.1"},
            {"CYFR_LOCUS_BUILDS_URL", "http://locus-builds:4100"},
            {"CYFR_BIND_ADDRESS", "::1"}
          ] do
        File.write!(".env", complete() <> "#{name} = #{value} # a note\n")
        refused("#{name} is #{value}, and the dev stack needs ")
        File.write!(".env", complete())
        System.put_env(name, value)
        refused("#{name} is #{value}, and the dev stack needs ")
        System.delete_env(name)
      end
    end

    test "refuses a setting its own resolver refuses with the boot's sentence" do
      File.write!(".env", complete() <> "CYFR_BIND_ADDRESS=0.0.0.0\n")
      refused("CYFR_BIND_ADDRESS `0.0.0.0` is not a loopback address")

      File.write!(".env", complete() <> "CYFR_HOST_API_PORT=65536\n")
      refused("CYFR_HOST_API_PORT=\"65536\" is not a port from 1 to 65535.")
    end

    test "refuses declarations it cannot read, naming what is missing" do
      File.write!(".env", complete())

      for {edit, message} <- [
            {&Map.delete(&1, "x-prism"), "does not declare x-prism as 127.0.0.1:<port>"},
            {&Map.put(&1, "x-prism", "0.0.0.0:4000"),
             "does not declare x-prism as 127.0.0.1:<port>"},
            {&put_in(&1, ["services", "locus-runtime", "ports"], []),
             "does not declare the runtime's id, callback address and one port on 127.0.0.1"},
            {&put_in(&1, ["services", "locus-backends-guard", "networks"], %{}),
             "does not declare locus-backends-guard with one exposed port and a fixed address"},
            {&update_in(&1, ["services"], fn s -> Map.delete(s, "locus-builds-guard") end),
             "does not declare locus-builds-guard"}
          ] do
        File.write!("stack.json", Jason.encode!(edit.(declarations())))
        refused(message)
      end

      File.write!("stack.json", "not json")
      refused("stack.json holds no compose configuration as JSON.")
    end
  end

  describe "names" do
    test "answers the project and the one image every service runs, reading nothing else" do
      File.write!(
        "stack.json",
        declarations()
        |> put_in(["services", "locus-backends"], %{"image" => "cyfr-locus:dev"})
        |> Jason.encode!()
      )

      DevStack.run(["names", "stack.json"])
      assert answers() == ["project cyfr-dev", "image cyfr-locus:dev"]
      refute File.exists?(".env")
    end

    test "refuses services on two images, or no project" do
      for edit <- [
            &put_in(&1, ["services", "locus-backends"], %{
              "image" => "ghcr.io/cyfrworks/cyfr-locus:latest"
            }),
            &Map.delete(&1, "name")
          ] do
        File.write!("stack.json", Jason.encode!(edit.(declarations())))

        refused("does not declare a project name and one image for every service", fn ->
          DevStack.run(["names", "stack.json"])
        end)
      end
    end
  end

  describe "endpoint" do
    test "answers Prism's declared port and writes nothing" do
      DevStack.run(["endpoint", "stack.json"])
      assert answers() == ["CYFR_PORT=4555"]
      refute File.exists?(".env")

      File.write!(".env", "CYFR_PORT=4000\n")

      refused("CYFR_PORT is 4000, and the dev stack needs 4555", fn ->
        DevStack.run(["endpoint", "stack.json"])
      end)
    end
  end

  # A release reads the .env at RELEASE_ROOT, the stack's mix boot the
  # checkout's: with it set the two would read two files, so nothing is
  # read or written, and nothing is answered.
  test "RELEASE_ROOT set refuses every command before anything is read", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "release"))
    File.write!(Path.join(dir, "release/.env"), complete())

    for release_root <- [Path.join(dir, "release"), ""],
        args <- [["settings", "stack.json", "dev@example.test"], ["endpoint", "stack.json"], []] do
      System.put_env("RELEASE_ROOT", release_root)
      error = assert_raise Mix.Error, fn -> DevStack.run(args) end

      assert Exception.message(error) ==
               "RELEASE_ROOT is set, and it names a release: the dev stack runs CYFR from the " <>
                 "checkout, which reads the .env at its root. Unset RELEASE_ROOT and run again."

      assert error.mix == 1
      assert answers() == []
      refute File.exists?(".env")
    end
  end

  test "any other arguments are refused with the usage" do
    for args <- [[], ["settings"], ["settings", "stack.json", "a", "b"], ["endpoint"], ["key"]] do
      error = assert_raise Mix.Error, fn -> DevStack.run(args) end
      assert Exception.message(error) =~ "usage: mix cyfr.locus.dev_stack"
    end
  end
end
