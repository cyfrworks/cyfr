# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Mix.Tasks.Cyfr.Locus.DevStack do
  @shortdoc "The source development stack's settings, read as a mix boot reads them"

  @moduledoc """
  The settings `scripts/dev-stack.sh` starts the source development stack
  with (CONTRIBUTING.md, "Running from source"), derived from what
  `docker-compose.dev.yml` declares and checked against the checkout's
  `.env` and the environment, read by the reader and in the order
  `config/runtime.exs` reads them (`Cyfr.EnvFiles`, the environment over
  the file, an empty value unset and every other value literal, trimmed
  only by the resolver that owns the setting). The script reads no `.env`
  and no declaration of its own.

  DECLARATIONS is the path of `docker-compose.dev.yml` resolved over
  `docker-compose.yml` as JSON (`docker compose config --format json`),
  with the worktree's slot's values interpolated. From it come CYFR's
  settings for the stack: `CYFR_PORT` from Prism's address (`x-prism`),
  `CYFR_PROXY_PORT` from its proxy's (`x-prism-proxy`),
  `CYFR_LOCUS_RUNTIME_WORKERS` from the runtime's id
  and published listener, `CYFR_HOST_API_BIND` and `CYFR_HOST_API_PORT`
  from the runtime's callback address, `CYFR_LOCUS_BACKENDS_URL` and
  `CYFR_LOCUS_BUILDS_URL` from each island guard's fixed address and
  port, and `CYFR_PRIVATE_EGRESS_TARGETS`, the backends guard's address
  and the local cyfr.run's two names. A value `.env` or the environment
  sets for one of them, a `CYFR_HOST_API_URL` other than the callback
  address, or a `CYFR_BIND_ADDRESS` other than Prism's, is refused by
  name: each would serve Prism, or send runs, calls or builds, somewhere
  the stack is not.

  DOMAIN is the local cyfr.run every worktree's loop shares
  (`scripts/dev-stack.sh`), `cyfr.test`: a name of this machine, never
  cyfr.run's, which is refused. Whatever `.env` says, the server's
  registry is DOMAIN (`CYFR_REGISTRY_URL`), its OCI registry
  `registry.DOMAIN` (`CYFR_OCI_REGISTRY_URL`) and its account service
  `https://DOMAIN` (`CYFR_DIRECTORY_URL`), the addresses the local
  cyfr.run derives from its own `DOMAIN`, so a person the stack makes,
  and every pull and publish, exists only there.

      mix cyfr.locus.dev_stack settings DECLARATIONS DOMAIN ROOT

  refuses unless every address both names resolve to, IPv4 and IPv6, is
  this machine's loopback where the local cyfr.run answers (127.0.0.1, or
  ::1 beside it; the server pins the IPv4 one, `Sanctum.Network`), and
  unless ROOT, the PEM of the local cyfr.run's certificate authority, is
  in the operating system's trust store the server's TLS reads
  (`:public_key.cacerts_get/0`); each refusal names the one command, run
  once on the machine, that settles it. It then writes into `.env`, made
  mode 0600 before it is written, each setting a mix boot needs that
  neither `.env` nor the environment sets: `CYFR_SETUP_TOKEN`, `CYFR_LOCUS_RUNTIME_ROOT` and `CYFR_LOCUS_BACKENDS_KEY` minted as
  `cyfr init` mints them, 32 random bytes as 64 lowercase hexadecimal
  digits. `CYFR_LOCUS_BUILDS_KEY`, which a boot refuses without its URL, is
  never written: unset, it is minted for the run. A value already set is
  kept; one the environment sets empty over the file, or one its reader
  at boot refuses, is refused. Nothing is written when anything is
  refused. It then prints `wrote NAME...` when it wrote, and `setup <link>`,
  the setup link at Prism's address (`/setup#<token>`), when it wrote the
  setup token, as `cyfr init` prints it; a `server NAME=VALUE` line for
  each of CYFR's settings above and the builds key; and `compose
  NAME=VALUE` lines for the three keys compose hands the services:
  `LOCUS_RUNTIME_KEY`, the runtime's id's key derived from the root
  (`Prima.WorkerAuth.worker_key/2`), and the backends and builds keys.

      mix cyfr.locus.dev_stack endpoint DECLARATIONS DOMAIN

  writes nothing and prints `CYFR_PORT=<port>`, Prism's port, where
  `scripts/dev-stack.sh check` reaches the server, after the same refusals.

      mix cyfr.locus.dev_stack database

  writes nothing and prints `DEV_STACK_DATABASE_NEW=1` when the dev
  database the checkout configures does not exist yet (under SQLite, its
  file, `data/cyfr.db` unless `CYFR_DATABASE_PATH` names another; under
  PostgreSQL, the database `CYFR_DATABASE_URL` names), else
  `DEV_STACK_DATABASE_NEW=0`: the script records which local cyfr.run a
  new database's people are made at, and refuses one that is not new once
  that cyfr.run has been reset.

  Both refuse a `RELEASE_ROOT`: the stack is a mix boot from the checkout,
  never a release.

  ## arca:bypass-ok=B — entire module

  Every file it touches is the operator's, read or written before any
  boot, with no Arca configured: the checkout's `.env` and `.env.example`,
  the declarations the script resolved into its private directory, and the
  local cyfr.run's certificate authority it copied out.
  """

  use Boundary, classify_to: Cyfr

  use Mix.Task

  import Bitwise

  @root "CYFR_LOCUS_RUNTIME_ROOT"
  @backends_key "CYFR_LOCUS_BACKENDS_KEY"
  @builds_key "CYFR_LOCUS_BUILDS_KEY"
  @setup "CYFR_SETUP_TOKEN"
  @host_api_url "CYFR_HOST_API_URL"
  @bind "CYFR_BIND_ADDRESS"

  # What a mix boot needs that the stack provisions when nothing sets it,
  # in the order the lines are written.
  @provisioned [@setup, @root, @backends_key]
  @keys [@root, @backends_key, @builds_key]

  @loopback6 [{0, 0, 0, 0, 0, 0, 0, 1}, {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}]

  @impl Mix.Task
  def run(args) do
    # A release reads the .env at RELEASE_ROOT (config/runtime.exs); the
    # stack's mix boot reads the checkout's, so the two would read two
    # files. Refused before anything is read.
    if System.get_env("RELEASE_ROOT") != nil do
      Mix.raise(
        "RELEASE_ROOT is set, and it names a release: the dev stack runs CYFR from the " <>
          "checkout, which reads the .env at its root. Unset RELEASE_ROOT and run again."
      )
    end

    case answer(args) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end

  defp answer(["settings", declarations, domain, root]) do
    with {:ok, stack} <- declared(declarations, domain),
         env = environment(),
         :ok <- agree(stack, env),
         :ok <- resolves(stack.names),
         :ok <- trusted(root),
         {:ok, lines} <- provision(env),
         {:ok, builds_key} <- builds_key(env),
         :ok <- write(lines),
         env = environment(),
         {:ok, keys} <- keys(env, stack.service_id, builds_key) do
      if lines != [], do: info("wrote " <> Enum.map_join(lines, " ", &elem(&1, 0)))

      for {@setup, token} <- lines,
          do: info("setup http://localhost:#{stack.prism_port}/setup##{token}")

      for {name, value} <- stack.server ++ stack.registry, do: info("server #{name}=#{value}")
      info("server #{@builds_key}=#{builds_key}")
      for {name, value} <- keys, do: info("compose #{name}=#{value}")
      :ok
    end
  end

  defp answer(["endpoint", declarations, domain]) do
    with {:ok, stack} <- declared(declarations, domain),
         :ok <- agree(stack, environment()) do
      info("CYFR_PORT=" <> stack.prism_port)
    end
  end

  defp answer(["database"]) do
    with {:ok, new?} <- new_database(environment()) do
      info("DEV_STACK_DATABASE_NEW=" <> if(new?, do: "1", else: "0"))
    end
  end

  defp answer(_args) do
    {:error,
     "usage: mix cyfr.locus.dev_stack settings DECLARATIONS DOMAIN ROOT | " <>
       "endpoint DECLARATIONS DOMAIN | database"}
  end

  defp info(line), do: Mix.shell().info(line)

  # The stack docker-compose.dev.yml declares, as compose resolved it, and
  # the local cyfr.run's names.
  defp declared(path, domain) do
    with {:ok, domain} <- domain(domain),
         {:ok, json} <- resolution(path),
         {:ok, prism_port} <- prism(json["x-prism"]),
         {:ok, proxy_port} <- proxy(json["x-prism-proxy"]),
         {:ok, runtime} <- runtime(get_in(json, ["services", "locus-runtime"])),
         {:ok, backends} <- island(json, "locus-backends"),
         {:ok, builds} <- island(json, "locus-builds") do
      {:ok,
       %{
         service_id: runtime.service_id,
         prism_port: prism_port,
         prism_address: "127.0.0.1",
         host_api_url: "http://#{runtime.host_api_bind}:#{runtime.host_api_port}",
         server: [
           {"CYFR_PORT", prism_port},
           {"CYFR_PROXY_PORT", proxy_port},
           {"CYFR_LOCUS_RUNTIME_WORKERS", "#{runtime.service_id}=#{runtime.url}"},
           {"CYFR_HOST_API_BIND", runtime.host_api_bind},
           {"CYFR_HOST_API_PORT", runtime.host_api_port},
           {"CYFR_LOCUS_BACKENDS_URL", "http://#{backends.address}:#{backends.port}"},
           {"CYFR_PRIVATE_EGRESS_TARGETS", "#{backends.address},#{domain},registry.#{domain}"},
           {"CYFR_LOCUS_BUILDS_URL", "http://#{builds.address}:#{builds.port}"}
         ],
         names: [domain, "registry." <> domain],
         registry: [
           {"CYFR_REGISTRY_URL", domain},
           {"CYFR_OCI_REGISTRY_URL", "registry." <> domain},
           {"CYFR_DIRECTORY_URL", "https://" <> domain}
         ]
       }}
    end
  end

  # The local cyfr.run's apex: a lowercase DNS name that is not cyfr.run
  # or under it. The server's own outbound calls reach it by name
  # (`CYFR_PRIVATE_EGRESS_TARGETS` matches the host), so naming 127.0.0.1
  # would open every local port to them.
  defp domain(text) do
    labels = String.split(text, ".")

    cond do
      text == "cyfr.run" or String.ends_with?(text, ".cyfr.run") ->
        {:error,
         "#{text} is the public cyfr.run's name; the dev stack's cyfr.run is a local one."}

      length(labels) >= 2 and
          Enum.all?(labels, &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1)) ->
        {:ok, text}

      true ->
        {:error, "#{text} is not the local cyfr.run's name, a lowercase DNS name."}
    end
  end

  # Every address each name resolves to, IPv4 and IPv6, is this machine's
  # loopback where the local cyfr.run answers: 127.0.0.1, or ::1 or the
  # IPv4-mapped 127.0.0.1 a resolver may answer for it, with at least one
  # IPv4 address, which the server pins first (`Sanctum.Network`). A name
  # with any other address beside it could be pinned elsewhere.
  defp resolves(names) do
    case Enum.find_value(names, &unresolved/1) do
      nil ->
        :ok

      reason ->
        {:error,
         "#{reason}, and both names must resolve to 127.0.0.1 alone on this machine, where " <>
           "the local cyfr.run answers. Map both once: echo '127.0.0.1 #{Enum.join(names, " ")}' " <>
           "| sudo tee -a /etc/hosts"}
    end
  end

  defp unresolved(name) do
    v4 = addresses(name, :inet)
    v6 = addresses(name, :inet6)

    case Enum.reject(v4, &(&1 == {127, 0, 0, 1})) ++ Enum.reject(v6, &(&1 in @loopback6)) do
      [other | _] -> "#{name} resolves to #{:inet.ntoa(other)}, which is not 127.0.0.1"
      [] when v4 == [] -> "#{name} does not resolve to 127.0.0.1"
      [] -> nil
    end
  end

  defp addresses(name, family) do
    case :inet.getaddrs(String.to_charlist(name), family) do
      {:ok, addresses} -> addresses
      {:error, _} -> []
    end
  end

  # The local cyfr.run's certificate authority in the operating system's
  # trust store, which the server's TLS reads: Mint verifies against
  # `:public_key.cacerts_get/0` when it is given no CA file.
  defp trusted(path) do
    with {:ok, pem} <- File.read(path),
         [{:Certificate, der, :not_encrypted}] <- :public_key.pem_decode(pem) do
      if Enum.any?(os_cacerts(), &(elem(&1, 1) == der)),
        do: :ok,
        else:
          {:error,
           "The local cyfr.run's certificate authority (#{path}) is not in this machine's " <>
             "trust store, which the server's TLS reads. Trust it once: #{trust_command(path)}"}
    else
      _ -> {:error, "#{path} holds no certificate as PEM."}
    end
  end

  # An operating system store that cannot be read trusts nothing.
  defp os_cacerts do
    :public_key.cacerts_get()
  rescue
    _ -> []
  end

  defp trust_command(path) do
    cond do
      match?({:unix, :darwin}, :os.type()) ->
        "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain " <>
          path

      System.find_executable("update-ca-trust") ->
        "sudo cp #{path} /etc/pki/ca-trust/source/anchors/cyfr-test-root.crt && " <>
          "sudo update-ca-trust"

      true ->
        "sudo cp #{path} /usr/local/share/ca-certificates/cyfr-test-root.crt && " <>
          "sudo update-ca-certificates"
    end
  end

  # The resolved compose configuration the script wrote.
  defp resolution(path) do
    with {:ok, text} <- File.read(path),
         {:ok, json} when is_map(json) <- Jason.decode(text) do
      {:ok, json}
    else
      _ -> {:error, "#{path} holds no compose configuration as JSON."}
    end
  end

  defp prism("127.0.0.1:" <> port) do
    if port?(port), do: {:ok, port}, else: undeclared("x-prism as 127.0.0.1:<port>")
  end

  defp prism(_), do: undeclared("x-prism as 127.0.0.1:<port>")

  defp proxy(port) when is_integer(port), do: proxy(Integer.to_string(port))

  defp proxy(port) when is_binary(port) do
    if port?(port), do: {:ok, port}, else: undeclared("x-prism-proxy as a port")
  end

  defp proxy(_), do: undeclared("x-prism-proxy as a port")

  defp runtime(%{
         "environment" => %{
           "LOCUS_RUNTIME_SERVICE_ID" => service_id,
           "LOCUS_RUNTIME_HOST_API_URL" => callback
         },
         "ports" => [%{"host_ip" => "127.0.0.1", "published" => published, "target" => 4200}]
       }) do
    case URI.parse(callback) do
      %URI{scheme: "http", host: bind, port: port, path: nil} when is_binary(bind) ->
        {:ok,
         %{
           service_id: service_id,
           url: "http://127.0.0.1:#{published}",
           host_api_bind: bind,
           host_api_port: Integer.to_string(port)
         }}

      _ ->
        undeclared("the runtime's callback as http://<gateway>:<port>")
    end
  end

  defp runtime(_),
    do: undeclared("the runtime's id, callback address and one port on 127.0.0.1")

  # An island's service is reached at its guard's fixed address on the
  # island's network, on the port the guard exposes for it.
  defp island(json, name) do
    case get_in(json, ["services", name <> "-guard"]) do
      %{"expose" => [port], "networks" => %{^name => %{"ipv4_address" => address}}} ->
        {:ok, %{address: address, port: port}}

      _ ->
        undeclared("#{name}-guard with one exposed port and a fixed address on #{name}")
    end
  end

  defp undeclared(what), do: {:error, "docker-compose.dev.yml does not declare #{what}."}

  defp port?(text) do
    case Integer.parse(text) do
      {port, ""} -> port in 1..65_535
      _ -> false
    end
  end

  # Whether the dev database the checkout configures is yet to be made, read
  # as a boot of this build resolves it (`config/runtime.exs`) and asked of
  # Arca, which alone names the adapter.
  defp new_database(env) do
    getenv = fn name -> set(env, name) end

    options =
      case Arca.adapter_facts().adapter do
        :sqlite ->
          with {:ok, %{database_path: path}} <- Cyfr.RuntimeConfig.resolve_paths(getenv),
               do: {:ok, [database: path]}

        :postgres ->
          Cyfr.RuntimeConfig.resolve_postgres(getenv)
      end

    with {:ok, options} <- options do
      case Arca.database_exists(options) do
        {:ok, exists?} ->
          {:ok, not exists?}

        {:error, reason} ->
          {:error,
           "The database server CYFR_DATABASE_URL names could not say whether its database " <>
             "exists (#{Prima.LoggerContext.shape(reason)}). Start it, or fix CYFR_DATABASE_URL."}
      end
    end
  end

  # The names and values a mix boot reads: the .env file at the project
  # root, then the environment over it.
  defp environment,
    do: Cyfr.EnvFiles.source!(env_files() ++ [System.get_env()], side_effect: false)

  defp env_path, do: Path.join(File.cwd!(), ".env")

  defp env_files do
    if File.regular?(env_path()), do: [env_path()], else: []
  end

  # config/runtime.exs's reading (`env!(name, :string?, nil)`): an empty
  # value is unset and every other value is literal. Only the resolver
  # that owns a setting trims it, and a key has none.
  defp set(env, name) do
    case Map.get(env, name) do
      "" -> nil
      value -> value
    end
  end

  # Each setting .env or the environment holds, read by the resolver the
  # boot reads it with, against the stack's value read the same way.
  defp agree(stack, env) do
    stack.server
    |> Enum.concat([{@host_api_url, stack.host_api_url}, {@bind, stack.prism_address}])
    |> Enum.find_value(:ok, fn {name, want} ->
      with have when have != nil <- set(env, name),
           {:ok, value} <- resolved(name, have),
           {:ok, ^value} <- resolved(name, want) do
        nil
      else
        nil ->
          nil

        {:error, message} ->
          {:error, message}

        {:ok, _other} ->
          have = set(env, name)

          {:error,
           "#{name} is #{have}, and the dev stack needs #{want}. Unset it in .env and the " <>
             "environment, or set it to #{want}."}
      end
    end)
  end

  defp resolved(name, text) do
    getenv = fn key -> if key == name, do: text end

    case name do
      "CYFR_LOCUS_RUNTIME_WORKERS" ->
        Cyfr.RuntimeConfig.resolve_workers(getenv)

      "CYFR_HOST_API_" <> field ->
        with {:ok, host_api} <- Cyfr.RuntimeConfig.resolve_host_api(getenv) do
          {:ok, Map.fetch!(host_api, String.to_existing_atom(String.downcase(field)))}
        end

      "CYFR_PRIVATE_EGRESS_TARGETS" ->
        {:ok, text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}

      "CYFR_PROXY_PORT" ->
        case Cyfr.RuntimeConfig.resolve_access(%{
               file: nil,
               process: %{name => text},
               release?: false
             }) do
          {:ok, _access} ->
            {:ok, text |> String.trim() |> String.to_integer()}

          {:error, %{code: code, payload: payload}} ->
            {:error, Prima.Refusal.message({code, payload})}
        end

      access when access in ["CYFR_PORT", @bind] ->
        case Cyfr.RuntimeConfig.resolve_access(%{
               file: nil,
               process: %{name => text},
               release?: false
             }) do
          {:ok, %{listeners: %{loopback: {address, port}}}} ->
            {:ok, if(access == "CYFR_PORT", do: port, else: :inet.parse_address(~c"#{address}"))}

          {:error, %{code: code, payload: payload}} ->
            {:error, Prima.Refusal.message({code, payload})}
        end

      _url ->
        Prima.EnvValue.url(getenv, name)
    end
  end

  # The lines to write for what nothing sets, or the refusal of what is
  # set wrongly; nothing is written until every name has been read.
  defp provision(env) do
    Enum.reduce_while(@provisioned, {:ok, []}, fn name, {:ok, lines} ->
      case provided(name, env) do
        :ok -> {:cont, {:ok, lines}}
        {:write, value} -> {:cont, {:ok, lines ++ [{name, value}]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp provided(name, env) do
    cond do
      System.get_env(name) == "" -> empty_override(name)
      (have = set(env, name)) != nil -> held(name, have)
      true -> minted(name)
    end
  end

  # A value held, checked by the reader the boot checks it with: the root
  # decoded as it stands (`config/runtime.exs`), the setup token trimmed and
  # held to `Prima.Device.setup_token?/1`, an island key through
  # `Prima.EnvValue.hex_key/2`, which trims it. Whitespace alone is
  # refused: it is a value of none of them.
  defp held(name, text) do
    cond do
      String.trim(text) == "" ->
        {:error,
         "#{name} holds only whitespace in .env or the environment. Remove it, or set a value."}

      name == @root ->
        hex_key(name, Prima.MacEnvelope.decode_root(text))

      name == @setup ->
        {:ok, token} = Prima.EnvValue.text(fn _ -> text end, name)

        if Prima.Device.setup_token?(token),
          do: :ok,
          else:
            {:error,
             "#{name} is not 64 lowercase hexadecimal digits. Remove its line from .env and " <>
               "scripts/dev-stack.sh writes one."}

      name in @keys ->
        hex_key(name, Prima.EnvValue.hex_key(fn _ -> text end, name))

      true ->
        :ok
    end
  end

  defp empty_override(name) do
    {:error,
     "#{name} is set empty in the environment, which overrides .env. Unset it there, " <>
       "so the value .env holds is the one the stack uses."}
  end

  # The builds key pairs with CYFR_LOCUS_BUILDS_URL, which the stack hands
  # the server and never writes: in .env without it, every other mix boot
  # of the checkout would refuse to start. The builder holds no state, so
  # a key .env or the environment does not set is minted for each run.
  defp builds_key(env) do
    cond do
      System.get_env(@builds_key) == "" ->
        empty_override(@builds_key)

      (have = set(env, @builds_key)) != nil ->
        with :ok <- held(@builds_key, have), do: {:ok, String.trim(have)}

      true ->
        {:write, key} = minted(@builds_key)
        {:ok, key}
    end
  end

  defp minted(_key),
    do: {:write, Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)}

  # The refusal of a key its reader did not decode.
  defp hex_key(name, read) do
    case read do
      {:ok, bytes} when is_binary(bytes) ->
        :ok

      _not_a_key ->
        {:error,
         "#{name} is not 64 hexadecimal digits. Generate one with `openssl rand -hex 32`, " <>
           "or remove its line from .env and scripts/dev-stack.sh writes one."}
    end
  end

  # The lines appended to .env, which is made mode 0600 first, since it
  # then holds a secret; each must read back as it was written.
  defp write([]), do: :ok

  defp write(lines) do
    path = env_path()

    with :ok <- if(File.exists?(path), do: :ok, else: File.write(path, "")),
         :ok <- File.chmod(path, 0o600),
         {:ok, %File.Stat{mode: mode}} when (mode &&& 0o777) == 0o600 <- File.stat(path),
         {:ok, text} <- File.read(path),
         lead = if(text == "" or String.ends_with?(text, "\n"), do: "", else: "\n"),
         :ok <-
           File.write(path, lead <> Enum.map_join(lines, &"#{elem(&1, 0)}=#{elem(&1, 1)}\n"), [
             :append
           ]) do
      read_back(lines)
    else
      _ ->
        {:error,
         ".env could not be made mode 0600 and written; make it yours (chown) on a " <>
           "filesystem that keeps modes, and run again."}
    end
  end

  defp read_back(lines) do
    env = environment()

    case Enum.find(lines, fn {name, value} -> Map.get(env, name) != value end) do
      nil -> :ok
      {name, _} -> {:error, "#{name} does not read back from .env as it was written."}
    end
  end

  defp keys(env, service_id, builds_key) do
    {:ok, root} = Prima.MacEnvelope.decode_root(set(env, @root))

    case Prima.WorkerAuth.worker_key(root, service_id) do
      {:ok, key} ->
        {:ok,
         [
           {"LOCUS_RUNTIME_KEY", Base.encode16(key, case: :lower)},
           {@backends_key, String.trim(set(env, @backends_key))},
           {@builds_key, builds_key}
         ]}

      {:error, _} ->
        {:error, "#{inspect(service_id)}, the runtime's id, is not a service id."}
    end
  end
end
