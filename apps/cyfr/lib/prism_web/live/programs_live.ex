# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ProgramsLive do
  @moduledoc """
  The athanor's programs and external MCP servers — the rows of the
  `mcp_servers` tool, which keeps its name (the page says Programs). Each
  row has a transport:

    * `http` — a remote MCP server reached at its URL;
    * `stdio` — an MCP server the backends service runs as a program, CYFR
      speaking MCP over its lines;
    * `pipe` — a program a component drives (a coding harness), one
      backend, run with a kept home.

  A program's home is `scratch`, made for each process and scrubbed when
  it ends, or `kept`, one folder per login entry that survives retirement.
  A row may set its memory bound and a kept home's disk bound, and a
  program that signs in names its `login_command`.

  Forms add an http server (its config as JSON), a stdio server and a pipe
  program. A kept row offers **Sign in**: the sign-in terminal
  (`PrismWeb.SignInTerminalComponent`) runs the row's login command in a
  login entry's home, for the entry a kept stdio row names, or for one the
  person picks or makes (`vault.create kind=login`) on a pipe row. **Reset
  home** empties a login entry's home under the same uid
  (`mcp_servers.reset_home`).

  `?install=<component_ref>&need=<need>` opens the pipe form prefilled
  from that component's login need (`component.setup_plan`): the program
  named, its command and login command as the need's install block
  suggests, its home kept, every field editable. Saving it defines the row,
  makes a login entry for it and opens the sign-in terminal. `?name=` (the
  `ui.mcp_server.focus` intent) expands one row.

  A definition the catalog refuses says why in its form. A server saved
  whose connect is refused, and a Test whose connect is refused, say why
  in the flash, and a definition saved with warnings shows them.
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  alias PrismWeb.{SignInTerminalComponent, SystemLayer}

  @mib 1_048_576

  @placeholder_config Jason.encode!(
                        %{
                          "url" => "https://mcp.example.com/mcp",
                          "headers" => %{"Authorization" => "Bearer vault:my-connection"}
                        },
                        pretty: true
                      )

  @placeholder_env "GITHUB_PERSONAL_ACCESS_TOKEN=vault:github-token"

  @forms ~w(config stdio pipe)

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe once, at mount — handle_params re-fires on every patch,
    # and PubSub's :duplicate registry would deliver every message twice.
    if connected?(socket) do
      actor = Sanctum.Context.actor(socket.assigns[:context])
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.mcp_servers(actor))
    end

    socket =
      socket
      |> assign(:page_title, "Programs")
      |> assign(:active_nav, "programs")
      |> assign(:servers, [])
      |> assign(:show_add, nil)
      |> assign(:loading, true)
      |> assign(:expanded_name, nil)
      |> assign(:detail, nil)
      |> assign(:form_error, nil)
      |> assign(:prefill, %{})
      |> assign(:install, nil)
      |> assign(:logins, [])
      |> assign(:terminal, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_add", %{"form" => form}, socket) when form in @forms do
    show = if socket.assigns.show_add == form, do: nil, else: form

    {:noreply,
     socket
     |> assign(:show_add, show)
     |> assign(:form_error, nil)
     |> assign(:prefill, %{})
     |> assign(:install, nil)}
  end

  def handle_event("add_server", %{"name" => name, "config" => config_json}, socket) do
    with {:name, true} <- {:name, name != ""},
         {:json, {:ok, %{} = config}} <- {:json, Jason.decode(config_json)} do
      create(socket, name, config)
    else
      {:name, _} ->
        {:noreply, assign(socket, :form_error, "Name is required.")}

      {:json, {:error, %Jason.DecodeError{} = err}} ->
        {:noreply, assign(socket, :form_error, "Invalid JSON: #{Exception.message(err)}")}

      {:json, _} ->
        {:noreply, assign(socket, :form_error, "Config must be a JSON object.")}
    end
  end

  def handle_event("add_stdio", params, socket) do
    name = trimmed(params, "name")
    backend = trimmed(params, "backend")

    with {:filled, true} <-
           {:filled, name != "" and backend != "" and trimmed(params, "command") != ""},
         {:ok, program} <- program_config(params) do
      config =
        Map.merge(program, %{
          "transport" => "stdio",
          "backends" => [
            %{"name" => backend, "command" => trimmed(params, "command"), "env" => program["env"]}
          ]
        })
        |> Map.delete("env")
        |> put_entry(params)

      create(socket, name, config)
    else
      {:filled, false} ->
        {:noreply, assign(socket, :form_error, "Name, backend name and command are required.")}

      {:error, message} ->
        {:noreply, assign(socket, :form_error, message)}
    end
  end

  def handle_event("add_pipe", params, socket) do
    name = trimmed(params, "name")

    with {:filled, true} <- {:filled, name != "" and trimmed(params, "command") != ""},
         {:ok, program} <- program_config(Map.put_new(params, "home", "kept")) do
      config =
        Map.merge(program, %{
          "transport" => "pipe",
          "backends" => [
            %{"name" => name, "command" => trimmed(params, "command"), "env" => program["env"]}
          ]
        })
        |> Map.delete("env")

      install(socket, name, config)
    else
      {:filled, false} ->
        {:noreply, assign(socket, :form_error, "Name and command are required.")}

      {:error, message} ->
        {:noreply, assign(socket, :form_error, message)}
    end
  end

  def handle_event("delete", %{"name" => name}, socket) do
    case call_tool(socket, "mcp_servers/delete", %{"name" => name}) do
      {:ok, _} ->
        servers = Enum.reject(socket.assigns.servers, &(&1[:name] == name))

        expanded_name =
          if socket.assigns.expanded_name == name, do: nil, else: socket.assigns.expanded_name

        {:noreply,
         socket
         |> assign(:servers, servers)
         |> assign(:expanded_name, expanded_name)
         |> assign(:detail, if(expanded_name == nil, do: nil, else: socket.assigns.detail))
         |> put_flash(:info, "'#{name}' deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{error_message(reason)}")}
    end
  end

  def handle_event("toggle_enabled", %{"name" => name, "enabled" => enabled}, socket) do
    action = if enabled == "true", do: "disable", else: "enable"

    case call_tool(socket, "mcp_servers/#{action}", %{"name" => name}) do
      {:ok, _} ->
        {:noreply, refresh_servers(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{error_message(reason)}")}
    end
  end

  def handle_event("test", %{"name" => name}, socket) do
    case call_tool(socket, "mcp_servers/test", %{"name" => name}) do
      {:ok, %{error: sentence}} when is_binary(sentence) ->
        {:noreply, socket |> refresh_servers() |> put_flash(:error, "Test #{name}: #{sentence}")}

      {:ok, result} ->
        status = result[:status] || "unknown"
        {:noreply, socket |> refresh_servers() |> put_flash(:info, "Test #{name}: #{status}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Test failed: #{error_message(reason)}")}
    end
  end

  def handle_event("refresh", %{"name" => name}, socket) do
    case call_tool(socket, "mcp_servers/refresh", %{"name" => name}) do
      {:ok, _} ->
        {:noreply, socket |> refresh_servers() |> put_flash(:info, "Refreshed #{name}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Refresh failed: #{error_message(reason)}")}
    end
  end

  def handle_event("restart", %{"name" => name}, socket) do
    case call_tool(socket, "mcp_servers/restart", %{"name" => name}) do
      {:ok, result} ->
        {:noreply,
         socket
         |> refresh_servers()
         |> expand_server(name)
         |> put_flash(:info, "Restarted #{name}: #{result[:status] || "unknown"}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Restart failed: #{error_message(reason)}")}
    end
  end

  def handle_event("toggle_expand", %{"name" => name}, socket) do
    if socket.assigns.expanded_name == name do
      {:noreply, socket |> assign(:expanded_name, nil) |> assign(:detail, nil)}
    else
      {:noreply, expand_server(socket, name)}
    end
  end

  # The person signs a kept row in: with the entry a stdio row names, or
  # the entry picked, or a new one made for the program.
  def handle_event("sign_in", %{"name" => name} = params, socket) do
    case sign_in_entry(socket, name, params["entry"]) do
      {:ok, entry} -> {:noreply, open_terminal(socket, name, entry)}
      :new -> {:noreply, new_login(socket, name)}
      {:error, sentence} -> {:noreply, put_flash(socket, :error, sentence)}
    end
  end

  def handle_event("reset_home", %{"entry" => entry}, socket) when entry != "" do
    case call_tool(socket, "mcp_servers/reset_home", %{"entry" => entry}) do
      {:ok, _} ->
        {:noreply, socket |> refresh_servers() |> put_flash(:info, "The home is empty again.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reset failed: #{error_message(reason)}")}
    end
  end

  def handle_event("reset_home", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Choose the login entry whose home to reset.")}

  @impl true
  def handle_params(params, _uri, socket) do
    # Paint the frame first — refresh_servers probes every server.
    if connected?(socket) do
      send(self(), :load)

      # `ui.mcp_server.focus` navigates here with `?name=`, the agent's half
      # of the act a person performs by clicking the row. Deferred behind
      # `:load` for the same reason as the list itself.
      case params["name"] do
        name when is_binary(name) and name != "" -> send(self(), {:focus, name})
        _ -> :ok
      end

      case params do
        %{"install" => ref, "need" => need} when ref != "" and need != "" ->
          send(self(), {:install, ref, need})

        _ ->
          :ok
      end
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:load, socket) do
    {:noreply, socket |> refresh_servers() |> refresh_logins() |> assign(:loading, false)}
  end

  def handle_info({:focus, name}, socket) do
    if socket.assigns.expanded_name == name,
      do: {:noreply, socket},
      else: {:noreply, expand_server(socket, name)}
  end

  def handle_info({:install, ref, need}, socket),
    do: {:noreply, prefill_install(socket, ref, need)}

  # The sign-in relay's lines and its end, for the terminal open now.
  def handle_info({Opus.Programs, token, event}, socket) do
    case socket.assigns.terminal do
      %{} ->
        send_update(SignInTerminalComponent, id: "sign-in", relay: {token, event})
        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info({SignInTerminalComponent, :closed}, socket),
    do: {:noreply, socket |> assign(:terminal, nil) |> refresh_servers()}

  def handle_info(%Cyfr.Bus.McpServers{}, socket), do: {:noreply, refresh_servers(socket)}

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # ————— defining a row —————

  defp create(socket, name, config) do
    case call_tool(socket, "mcp_servers/create", %{"name" => name, "config" => config}) do
      {:ok, result} ->
        {:noreply,
         socket
         |> refresh_servers()
         |> assign(:show_add, nil)
         |> assign(:form_error, nil)
         |> assign(:prefill, %{})
         |> added_flash(name, result)
         |> warnings_flash(result)}

      {:error, reason} ->
        {:noreply, assign(socket, :form_error, "Failed to add: #{error_message(reason)}")}
    end
  end

  # A pipe program: the row, then (from an install, or for any kept home)
  # a login entry for it and the sign-in terminal on it.
  defp install(socket, name, config) do
    with {:ok, result} <-
           call_tool(socket, "mcp_servers/create", %{"name" => name, "config" => config}) do
      socket =
        socket
        |> refresh_servers()
        |> assign(:show_add, nil)
        |> assign(:form_error, nil)
        |> assign(:prefill, %{})
        |> assign(:install, nil)
        |> added_flash(name, result)
        |> warnings_flash(result)

      if config["home"] == "kept" and present?(config["login_command"]) do
        {:noreply, new_login(socket, name)}
      else
        {:noreply, socket}
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, :form_error, "Failed to add: #{error_message(reason)}")}
    end
  end

  # The program fields both program forms share: the env, the home, the
  # bounds in MiB and the login command. Only what is set is sent.
  defp program_config(params) do
    with {:ok, env} <- parse_env(params["env"] || ""),
         {:ok, memory} <- mib(params, "memory_mib", "Memory"),
         {:ok, disk} <- mib(params, "disk_mib", "Disk") do
      home = if params["home"] == "kept", do: "kept", else: "scratch"

      {:ok,
       %{"env" => env, "home" => home}
       |> put_present("memory_bytes", memory)
       |> put_present("home_max_bytes", if(home == "kept", do: disk))
       |> put_present("login_command", blank_nil(trimmed(params, "login_command")))}
    end
  end

  # A kept stdio row names its login entry.
  defp put_entry(%{"home" => "kept"} = config, params),
    do: put_present(config, "login_entry_id", blank_nil(trimmed(params, "login_entry")))

  defp put_entry(config, _params), do: config

  defp mib(params, key, what) do
    case trimmed(params, key) do
      "" ->
        {:ok, nil}

      text ->
        case Integer.parse(text) do
          {n, ""} when n > 0 -> {:ok, n * @mib}
          _ -> {:error, "#{what} bound is a whole number of MiB."}
        end
    end
  end

  defp added_flash(socket, name, %{error: sentence}) when is_binary(sentence),
    do: put_flash(socket, :error, "'#{name}' added — #{sentence}")

  defp added_flash(socket, name, result),
    do: put_flash(socket, :info, "'#{name}' added (#{result[:status] || "saved"}).")

  defp warnings_flash(socket, %{warnings: [_ | _] = warnings}),
    do: put_flash(socket, :warning, Enum.join(warnings, " "))

  defp warnings_flash(socket, _result), do: socket

  # One `NAME=value` per line; blank lines are skipped.
  defp parse_env(text) do
    text
    |> String.split(~r/\R/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, env} ->
      case String.split(line, "=", parts: 2) do
        [name, value] when name != "" ->
          {:cont, {:ok, Map.put(env, String.trim(name), String.trim(value))}}

        _ ->
          {:halt, {:error, "Each env line is NAME=value — #{inspect(line)} is not."}}
      end
    end)
  end

  # ————— installing from a component's need —————

  # The pipe form, prefilled from the component's login need: what the
  # need's install block suggests, every field the person's to change.
  defp prefill_install(socket, ref, need_name) do
    with {:ok, plan} <-
           call_tool(socket, "component", %{"action" => "setup_plan", "reference" => ref}),
         %{} = need <- Enum.find(field(plan, :needs) || [], &login_need?(&1, need_name)) do
      install = field(need, :install) || %{}

      socket
      |> assign(:show_add, "pipe")
      |> assign(:form_error, nil)
      |> assign(:install, %{ref: ref, need: need_name, reason: field(need, :reason)})
      |> assign(:prefill, %{
        "name" => field(need, :program),
        "command" => field(install, :command),
        "login_command" => field(install, :login_command)
      })
    else
      _ ->
        put_flash(
          socket,
          :error,
          "#{ref} declares no login need named '#{need_name}' to install from."
        )
    end
  end

  defp login_need?(need, name),
    do: field(need, :kind) == "login" and field(need, :name) == name

  # ————— signing in —————

  defp sign_in_entry(socket, name, entry) do
    server = Enum.find(socket.assigns.servers, &(&1[:name] == name)) || %{}
    named = config(socket.assigns.detail)["login_entry_id"]

    cond do
      server[:transport] == "stdio" and present?(named) ->
        {:ok, named}

      server[:transport] == "stdio" ->
        {:error, "This server names no login entry; edit it to name one, then sign in."}

      entry in [nil, "", "new"] ->
        :new

      true ->
        {:ok, entry}
    end
  end

  # A new login entry for `program`, named for it, its home the box makes
  # at the first sign-in; the sign-in opens on it once it is made. Making a
  # vault entry is a sensitive change: the system layer asks for its
  # confirmation, and `system_layer_repeat/4` makes it again once given.
  defp new_login(socket, program) do
    name = unused_name(socket.assigns.logins, program <> "-login")
    args = %{"name" => name, "kind" => "login", "program" => program}
    made_login(SystemLayer.call(socket, {:login, program}, "vault/create", args), program)
  end

  defp made_login({:ok, result, socket}, program) do
    case field(field(result, :entry) || %{}, :id) do
      id when is_binary(id) -> socket |> refresh_logins() |> open_terminal(program, id)
      _ -> put_flash(socket, :error, "The login entry was made, but its id was not answered.")
    end
  end

  defp made_login({:asked, socket}, _program), do: socket

  defp made_login({:error, reason, socket}, _program),
    do: put_flash(socket, :error, "Could not make a login entry: #{error_message(reason)}")

  # The login entry a person confirmed is made, once, and its sign-in opens.
  @impl PrismWeb.SystemLayer.Hook
  def system_layer_repeat({:login, program} = tag, tool, args, socket),
    do: {:noreply, made_login(SystemLayer.call(socket, tag, tool, args), program)}

  defp unused_name(logins, base) do
    taken = MapSet.new(logins, & &1.name)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}-#{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp open_terminal(socket, name, entry),
    do: assign(socket, :terminal, %{row: name, entry: entry})

  # ————— reading —————

  defp expand_server(socket, name) do
    detail =
      case call_tool(socket, "mcp_servers/get", %{"name" => name}) do
        {:ok, result} -> result
        {:error, _} -> nil
      end

    servers =
      if detail do
        Enum.map(socket.assigns.servers, fn s ->
          if s[:name] == name do
            s
            |> Map.put(:status, detail[:status])
            |> Map.put(:tool_count, length(detail[:tools] || []))
          else
            s
          end
        end)
      else
        socket.assigns.servers
      end

    socket
    |> assign(:servers, servers)
    |> assign(:expanded_name, name)
    |> assign(:detail, detail)
  end

  defp refresh_servers(socket) do
    servers =
      case call_tool(socket, "mcp_servers/list", %{}) do
        {:ok, %{servers: list}} -> list
        _ -> []
      end

    assign(socket, :servers, servers)
  end

  # The athanor's login entries, each with the program its destination
  # names.
  defp refresh_logins(socket) do
    logins =
      case call_tool(socket, "vault/list", %{}) do
        {:ok, %{entries: list}} when is_list(list) ->
          for entry <- list, field(entry, :kind) == "login" do
            %{
              id: field(entry, :id),
              name: field(entry, :name),
              status: field(entry, :status),
              program: program_of(field(entry, :destination))
            }
          end

        _ ->
          []
      end

    assign(socket, :logins, logins)
  end

  defp program_of(%{"program" => program}), do: program
  defp program_of(%{program: program}), do: program

  defp program_of(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"program" => program}} -> program
      _ -> nil
    end
  end

  defp program_of(_), do: nil

  # ————— small helpers —————

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

  defp trimmed(params, key), do: String.trim(params[key] || "")

  defp blank_nil(""), do: nil
  defp blank_nil(text), do: text

  defp present?(value), do: is_binary(value) and value != ""

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # ————— the page —————

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:placeholder_config, @placeholder_config)
      |> assign(:placeholder_env, @placeholder_env)

    ~H"""
    <div class="space-y-6">
      <.page_header title="Programs">
        <:actions>
          <.button variant="ghost" phx-click="toggle_add" phx-value-form="pipe">
            {if @show_add == "pipe", do: "Cancel", else: "Add program"}
          </.button>
          <.button variant="ghost" phx-click="toggle_add" phx-value-form="stdio">
            {if @show_add == "stdio", do: "Cancel", else: "Add stdio server"}
          </.button>
          <.button phx-click="toggle_add" phx-value-form="config">
            {if @show_add == "config", do: "Cancel", else: "Add server"}
          </.button>
        </:actions>
      </.page_header>

      <.live_component module={SystemLayer} id={SystemLayer.layer_id()} context={@context} />

      <.live_component
        :if={@terminal}
        module={SignInTerminalComponent}
        id="sign-in"
        context={@context}
        row={@terminal.row}
        entry={@terminal.entry}
      />

      <.card :if={@show_add == "pipe"}>
        <form id="add-pipe" phx-submit="add_pipe" class="space-y-4">
          <p :if={@install} class="text-sm text-gray-300" data-test="install-from">
            Install <span class="font-mono">{@prefill["name"]}</span>
            for <span class="font-mono">{@install.ref}</span>
            — {@install.reason}. This is the row as it will run; change anything first.
            Saving it makes a login entry for it and opens its sign-in.
          </p>
          <p :if={!@install} class="text-xs text-gray-500">
            A program a component drives, such as a coding harness. Its command fetches or runs
            it; CYFR ships none. With a kept home it keeps its own sign-in between runs.
          </p>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
            <.input
              name="name"
              required
              value={@prefill["name"]}
              placeholder="claude"
              class="max-w-xs font-mono"
            />
          </div>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">Command</label>
            <.input
              name="command"
              required
              value={@prefill["command"]}
              placeholder="npx -y @anthropic-ai/claude-code"
              class="font-mono"
            />
          </div>
          <.program_fields kind="pipe" prefill={@prefill} logins={[]} />
          <div :if={@form_error} class="text-sm text-red-400">{@form_error}</div>
          <.button type="submit">{if @install, do: "Install", else: "Add program"}</.button>
        </form>
      </.card>

      <.card :if={@show_add == "stdio"}>
        <form id="add-stdio" phx-submit="add_stdio" class="space-y-4">
          <p class="text-xs text-gray-500">
            A stdio MCP server (for example an <code class="text-gray-400">npx</code>
            package) that the backends service runs as a program under a user of its own. Its tools
            appear as <span class="font-mono">&lt;name&gt;:&lt;backend&gt;__&lt;tool&gt;</span>.
          </p>
          <div class="grid gap-3 md:grid-cols-2">
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
              <.input name="name" required placeholder="github" class="font-mono" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Backend name</label>
              <.input name="backend" required placeholder="github" class="font-mono" />
            </div>
          </div>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">Command</label>
            <.input
              name="command"
              required
              placeholder="npx -y @modelcontextprotocol/server-github"
              class="font-mono"
            />
          </div>
          <.program_fields kind="stdio" prefill={%{}} logins={@logins} />
          <div :if={@form_error} class="text-sm text-red-400">{@form_error}</div>
          <.button type="submit">Add stdio server</.button>
        </form>
      </.card>

      <.card :if={@show_add == "config"}>
        <form id="add-config" phx-submit="add_server" class="space-y-4">
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
            <.input name="name" required placeholder="notion" class="max-w-xs font-mono" />
          </div>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">
              Config (mcp.json format)
            </label>
            <.textarea
              name="config"
              rows="6"
              required
              placeholder={@placeholder_config}
              class="font-mono"
            />
            <p class="text-xs text-gray-600 mt-1">
              A header value may be <code class="text-gray-500">vault:ENTRY</code>
              or <code class="text-gray-500">Bearer vault:ENTRY</code>, a single-field entry
              whose destination covers this server's URL (create one on the Vault page). A program's config is <code class="text-gray-500">{"{\"transport\": \"stdio\" | \"pipe\", \"backends\": [...], \"home\": ..., ...}"}</code>.
            </p>
          </div>
          <div :if={@form_error} class="text-sm text-red-400">{@form_error}</div>
          <.button type="submit">Add server</.button>
        </form>
      </.card>

      <.card>
        <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>
        <div :if={!@loading && @servers == []} class="py-8">
          <.empty_state message="No programs or external MCP servers yet" />
        </div>
        <div :if={!@loading && @servers != []} class="overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-800" id="programs">
            <thead>
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Name
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Runs
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Home
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Status
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Tools
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-800">
              <%= for server <- @servers do %>
                <tr
                  class="cursor-pointer hover:bg-gray-800/50 transition-colors"
                  phx-click="toggle_expand"
                  phx-value-name={server[:name]}
                  data-test="program-row"
                  data-name={server[:name]}
                >
                  <td class="px-4 py-3 text-sm whitespace-nowrap">
                    <span class="font-mono text-blue-400">{server[:name]}</span>
                    <span class="ml-2 text-xs text-gray-500" data-test="transport">
                      {server[:transport] || "http"}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300 whitespace-nowrap">
                    <span class="text-gray-400 text-xs font-mono truncate max-w-xs inline-block">
                      {endpoint(server)}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-xs text-gray-400 whitespace-nowrap" data-test="home">
                    {home_line(server)}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300 whitespace-nowrap">
                    <.badge color={status_color(server[:status])}>
                      {server[:status] || "unknown"}
                    </.badge>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300 whitespace-nowrap">
                    {server[:tool_count] || 0}
                  </td>
                </tr>
                <tr :if={@expanded_name == server[:name]} class="bg-gray-900/60">
                  <td colspan="5" class="px-4 py-4">
                    <div class="space-y-4">
                      <div
                        :for={warning <- (@detail && @detail[:warnings]) || []}
                        class="text-sm text-yellow-300"
                      >
                        {warning}
                      </div>
                      <dl
                        :if={server[:transport] in ["stdio", "pipe"]}
                        class="grid grid-cols-2 gap-x-6 gap-y-1 text-xs md:grid-cols-4"
                        data-test="program-settings"
                      >
                        <dt class="text-gray-500">Memory bound</dt>
                        <dd class="text-gray-300">
                          {bytes(config(@detail)["memory_bytes"], "the service's")}
                        </dd>
                        <dt class="text-gray-500">Disk bound</dt>
                        <dd class="text-gray-300">
                          {if server[:home] == "kept",
                            do: bytes(config(@detail)["home_max_bytes"], "the homes volume"),
                            else: "scratch home"}
                        </dd>
                        <dt class="text-gray-500">Sign-in command</dt>
                        <dd class="font-mono text-gray-300">
                          {config(@detail)["login_command"] || "none"}
                        </dd>
                        <dt
                          :if={server[:transport] == "stdio" and server[:home] == "kept"}
                          class="text-gray-500"
                        >
                          Login entry
                        </dt>
                        <dd
                          :if={server[:transport] == "stdio" and server[:home] == "kept"}
                          class="font-mono text-gray-300"
                        >
                          {entry_name(@logins, config(@detail)["login_entry_id"]) || "none named"}
                        </dd>
                      </dl>
                      <div :if={@detail && programs(@detail) != []} class="space-y-2">
                        <h4 class="text-sm font-medium text-gray-400 mb-2">Programs</h4>
                        <div
                          :for={program <- programs(@detail)}
                          class="flex flex-wrap items-baseline gap-2 text-sm px-2 py-1 rounded bg-gray-800/50"
                          data-test="program-status"
                        >
                          <span class="font-mono text-blue-400">{program["name"]}</span>
                          <.badge color={status_color(program["status"])}>
                            {program["status"] || "unknown"}
                          </.badge>
                          <span class="text-gray-500 text-xs">
                            {program["sessions"] || 0} sessions · {program["restarts"] || 0} crashes
                          </span>
                          <span :if={program["home_bytes"]} class="text-gray-500 text-xs">
                            · home {bytes(program["home_bytes"], "")}
                          </span>
                          <span :if={program["over_cap"]} class="text-xs text-red-400">
                            over its disk bound: reset the home to run it again
                          </span>
                          <span :if={program["error"]} class="text-xs text-red-400 truncate">
                            {program["error"]}
                          </span>
                        </div>
                      </div>
                      <div :if={@detail && (@detail[:tools] || []) != []} class="space-y-2">
                        <h4 class="text-sm font-medium text-gray-400 mb-2">
                          Discovered Tools ({length(@detail[:tools] || [])})
                        </h4>
                        <div class="space-y-1">
                          <div
                            :for={tool <- @detail[:tools] || []}
                            class="flex items-baseline gap-2 text-sm px-2 py-1 rounded bg-gray-800/50"
                          >
                            <span class="font-mono text-blue-400">{tool["name"]}</span>
                            <span class="text-gray-500 text-xs truncate">{tool["description"]}</span>
                          </div>
                        </div>
                      </div>
                      <.home_actions server={server} config={config(@detail)} logins={@logins} />
                      <div class="flex flex-wrap gap-2 pt-2 border-t border-gray-800">
                        <.button
                          variant="ghost"
                          phx-click="toggle_enabled"
                          phx-value-name={server[:name]}
                          phx-value-enabled={to_string(server[:enabled])}
                        >
                          {if server[:enabled] == true, do: "Disable", else: "Enable"}
                        </.button>
                        <.button
                          :if={server[:transport] != "pipe"}
                          variant="ghost"
                          phx-click="test"
                          phx-value-name={server[:name]}
                        >
                          Test
                        </.button>
                        <.button
                          :if={server[:transport] != "pipe"}
                          variant="ghost"
                          phx-click="refresh"
                          phx-value-name={server[:name]}
                        >
                          Refresh
                        </.button>
                        <.button
                          :if={server[:transport] == "stdio"}
                          variant="ghost"
                          phx-click="restart"
                          phx-value-name={server[:name]}
                        >
                          Restart
                        </.button>
                        <.button
                          variant="ghost"
                          phx-click="delete"
                          phx-value-name={server[:name]}
                          data-confirm="Delete this row?"
                        >
                          Delete
                        </.button>
                      </div>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </.card>
    </div>
    """
  end

  attr :kind, :string, required: true
  attr :prefill, :map, required: true
  attr :logins, :list, required: true

  # The fields a stdio server and a pipe program share.
  defp program_fields(assigns) do
    ~H"""
    <div>
      <label class="block text-xs text-gray-500 uppercase mb-1">Sign-in command</label>
      <.input
        name="login_command"
        value={@prefill["login_command"]}
        placeholder={if @kind == "pipe", do: "claude auth login", else: "optional"}
        class="font-mono"
      />
    </div>
    <div class="grid gap-3 md:grid-cols-3">
      <div>
        <label class="block text-xs text-gray-500 uppercase mb-1">Home</label>
        <select
          name="home"
          class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white"
        >
          <option value="kept" selected={@kind == "pipe"}>kept: survives, keeps its sign-in</option>
          <option value="scratch" selected={@kind != "pipe"}>scratch: scrubbed each run</option>
        </select>
      </div>
      <div>
        <label class="block text-xs text-gray-500 uppercase mb-1">Memory bound (MiB)</label>
        <.input name="memory_mib" placeholder="the service's" class="font-mono" />
      </div>
      <div>
        <label class="block text-xs text-gray-500 uppercase mb-1">Disk bound (MiB, kept)</label>
        <.input name="disk_mib" placeholder="the homes volume" class="font-mono" />
      </div>
    </div>
    <div :if={@kind == "stdio"}>
      <label class="block text-xs text-gray-500 uppercase mb-1">Login entry (kept home)</label>
      <select
        name="login_entry"
        class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white"
      >
        <option value="">none</option>
        <option :for={login <- @logins} value={login.id}>
          {login.name} (program {login.program})
        </option>
      </select>
      <p class="text-xs text-gray-600 mt-1">
        A server that signs in on its own keeps its home in a login entry naming this server.
      </p>
    </div>
    <div>
      <label class="block text-xs text-gray-500 uppercase mb-1">Env (NAME=value per line)</label>
      <.textarea
        name="env"
        rows="3"
        placeholder="GITHUB_PERSONAL_ACCESS_TOKEN=vault:github-token"
        class="font-mono"
      />
      <p class="text-xs text-gray-600 mt-1">
        A value is <code class="text-gray-500">vault:ENTRY</code>, a single-field
        disclosed entry on the Vault page; only NODE_ENV, LOG_LEVEL, TZ, LANG,
        LC_ALL, NO_COLOR and DEBUG may hold a literal. A command never names a vault entry.
      </p>
    </div>
    """
  end

  attr :server, :map, required: true
  attr :config, :map, required: true
  attr :logins, :list, required: true

  # Sign-in and reset for a kept row.
  defp home_actions(assigns) do
    assigns =
      assign(
        assigns,
        :entries,
        Enum.filter(assigns.logins, &(&1.program == assigns.server[:name]))
      )

    ~H"""
    <div
      :if={@server[:home] == "kept"}
      class="flex flex-wrap items-end gap-3 pt-2 border-t border-gray-800"
      data-test="home-actions"
    >
      <form :if={@config["login_command"]} phx-submit="sign_in" class="flex items-end gap-2">
        <input type="hidden" name="name" value={@server[:name]} />
        <select
          :if={@server[:transport] == "pipe"}
          name="entry"
          class="rounded-lg bg-gray-800 border border-gray-700 px-3 py-1.5 text-sm text-white"
        >
          <option :for={entry <- @entries} value={entry.id}>{entry.name}</option>
          <option value="new">a new login entry</option>
        </select>
        <.button type="submit" variant="ghost">Sign in</.button>
      </form>
      <form :if={@entries != []} phx-submit="reset_home" class="flex items-end gap-2">
        <select
          name="entry"
          class="rounded-lg bg-gray-800 border border-gray-700 px-3 py-1.5 text-sm text-white"
        >
          <option :for={entry <- @entries} value={entry.id}>{entry.name}</option>
        </select>
        <.button
          type="submit"
          variant="ghost"
          data-confirm="Empty this home? The program's sign-in and everything it kept there are removed."
        >
          Reset home
        </.button>
      </form>
    </div>
    """
  end

  defp programs(detail), do: detail[:programs] || []

  # The expanded row's settings, as `mcp_servers.get` answers them.
  defp config(%{config: %{} = config}), do: config
  defp config(_detail), do: %{}

  defp entry_name(_logins, nil), do: nil
  defp entry_name(logins, id), do: Enum.find_value(logins, id, &(&1.id == id && &1.name))

  defp home_line(%{transport: transport} = server) when transport in ["stdio", "pipe"],
    do: server[:home] || "scratch"

  defp home_line(_server), do: "—"

  defp bytes(nil, fallback), do: fallback
  defp bytes(n, _fallback) when is_integer(n) and n >= @mib, do: "#{div(n, @mib)} MiB"
  defp bytes(n, _fallback) when is_integer(n), do: "#{n} bytes"
  defp bytes(_n, fallback), do: fallback

  defp endpoint(%{transport: "stdio"}), do: "stdio (backends service)"
  defp endpoint(%{transport: "pipe"}), do: "pipe (a component drives it)"
  defp endpoint(server), do: server[:url]

  defp status_color(status) when status in ["ready", "connected", "running"], do: "green"
  defp status_color(status) when status in ["error", "crashed", "failed"], do: "red"

  defp status_color(status) when status in ["disconnected", "connecting", "starting", "idle"],
    do: "yellow"

  defp status_color(_), do: "gray"
end
