# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ProgramsLive do
  @moduledoc """
  The athanor's programs and tool servers — the rows of the `mcp_servers`
  tool, which keeps its name (the page says Programs). A row is one of two
  kinds:

    * `http` — a tool server elsewhere, reached at its URL;
    * `program` — a program the backends service runs, marked `mcp` (CYFR
      speaks MCP to it and offers its tools) or `driven` (a person or a
      brain runs it, such as a coding harness; one backend).

  A program's home is `scratch`, made for each process and scrubbed when
  it ends, or `kept`, one folder per login entry that survives retirement.
  A row may set its memory bound and a kept home's disk bound, and a
  program that signs in names its `login_command`. A program's hosts are
  its network list: the only hosts it reaches beside the deployment's
  private hosts, exact names resolved each time it starts, which the
  program forms set and an expanded program row changes (`mcp_servers.update`
  with the row's config and the new list); none named, every public host.

  Forms add an http server (its config as JSON) and a program, one
  backend named for the program, its mark chosen. **Edit** on an expanded
  program replaces its whole definition (`mcp_servers.update` at the epoch
  it was read at), in the program form, or in the config form when it
  defines more than one backend; its folder is kept. **Edit** on a tool
  server elsewhere opens its address and its headers, one `Name: value`
  per line: a header whose stored value is a literal shows as `[set]`,
  which `mcp_servers.get` answers in its place, and a line left at `[set]`
  keeps that value (`keep_headers`), so no stored value reaches the page. A kept row offers
  **Sign in**: the sign-in terminal
  (`PrismWeb.SignInTerminalComponent`) runs the row's login command in a
  login entry's home, for the entry a kept mcp program names, or for one
  the person picks or makes (`vault.create kind=login`) on a driven
  program. **Reset home** empties a login entry's home under the same uid
  (`mcp_servers.reset_home`).

  An expanded row's details are read again after it is enabled or
  disabled, and when the list says it is disabled, so a disabled program
  reads as stopped.

  `?install=<component_ref>&need=<need>` opens the program form, driven,
  prefilled from that component's login need (`component.setup_plan`): the program
  named, its command and login command as the need's install block
  suggests, its home kept, every field editable. Saving it defines the row,
  makes a login entry for it and opens the sign-in terminal. `?name=` (the
  `ui.mcp_server.focus` intent) expands one row.

  A definition the catalog refuses says why in its form. A server saved
  whose connect is refused, and a Test whose connect is refused, say why
  in the flash, and a definition saved with warnings shows them.

  Adding or replacing a row, and a row's Enable, Disable, Test, Refresh,
  Restart, hosts and Reset folder, call off the page's process (`call/5`): a connect waits up to a
  minute, and the browser gives up on an event it waits on for 30
  seconds. The page says what it is doing until the answer comes, takes
  no other of these meanwhile, and the call runs to its end if the person
  leaves (`PrismWeb.Ops.run_to_end/1`).
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

  @forms ~w(config program)

  # The events that call off the page's process, one at a time.
  @calls ~w(add_server add_program save_server toggle_enabled test refresh restart reset_home set_hosts)

  # What a tool server's Edit shows for a header whose stored value is a
  # literal: `mcp_servers.get` never answers it, and saving the line as it
  # stands keeps the stored value (`keep_headers`).
  @kept "[set]"

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
      # The row whose definition an open form replaces: %{name, epoch,
      # config}, its config as `mcp_servers.get` answered it.
      |> assign(:editing, nil)
      |> assign(:logins, [])
      |> assign(:terminal, nil)
      # What the page is doing until a call's answer comes; nil when idle.
      |> assign(:working, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{working: working}} = socket)
      when event in @calls and is_binary(working),
      do: {:noreply, socket}

  def handle_event("toggle_add", %{"form" => form}, socket) when form in @forms do
    show = if socket.assigns.show_add == form, do: nil, else: form

    {:noreply,
     socket
     |> assign(:show_add, show)
     |> assign(:form_error, nil)
     |> assign(:prefill, %{})
     |> assign(:install, nil)
     |> assign(:editing, nil)}
  end

  # The whole definition of an expanded program, in the form that holds
  # it: the program form for one backend, the config form for more.
  def handle_event("edit", %{"name" => name}, socket) do
    case socket.assigns.detail do
      %{name: ^name, epoch: epoch} = detail ->
        {form, prefill} = edit_prefill(config(detail))

        {:noreply,
         socket
         |> assign(:show_add, form)
         |> assign(:form_error, nil)
         |> assign(:install, nil)
         |> assign(:editing, %{name: name, epoch: epoch, config: config(detail)})
         |> assign(:prefill, Map.put(prefill, "name", name))}

      _not_read ->
        {:noreply, put_flash(socket, :error, "Open the row first, then edit it.")}
    end
  end

  # A tool server's whole definition: its address and its headers, one
  # `Name: value` per line, a line left at [set] keeping its stored value.
  # Every member the form does not show is kept as it was read.
  def handle_event("save_server", %{"url" => url, "headers" => text}, socket) do
    %{name: name, config: read} = socket.assigns.editing

    case parse_headers(text) do
      {:ok, headers} ->
        {kept, given} = Enum.split_with(headers, fn {_name, value} -> value == @kept end)

        config =
          read
          |> Map.merge(%{"url" => String.trim(url), "headers" => Map.new(given)})

        if Map.put(config, "headers", Map.new(headers)) == read,
          do: {:noreply, unchanged(socket, name)},
          else: {:noreply, update_server(socket, name, config, Enum.map(kept, &elem(&1, 0)))}

      {:error, message} ->
        {:noreply, assign(socket, :form_error, message)}
    end
  end

  def handle_event("add_server", %{"config" => config_json} = params, socket) do
    name = form_name(socket, params)

    with {:name, true} <- {:name, name != ""},
         {:json, {:ok, %{} = config}} <- {:json, Jason.decode(config_json)} do
      save(socket, name, config)
    else
      {:name, _} ->
        {:noreply, assign(socket, :form_error, "Name is required.")}

      {:json, {:error, %Jason.DecodeError{} = err}} ->
        {:noreply, assign(socket, :form_error, "Invalid JSON: #{Exception.message(err)}")}

      {:json, _} ->
        {:noreply, assign(socket, :form_error, "Config must be a JSON object.")}
    end
  end

  # One backend, named for the program unless the definition it replaces
  # named it otherwise.
  def handle_event("add_program", params, socket) do
    name = form_name(socket, params)
    backend = blank_nil(trimmed(params, "backend")) || name

    with {:filled, true} <- {:filled, name != "" and trimmed(params, "command") != ""},
         {:ok, program} <- program_config(params) do
      config =
        socket.assigns.editing
        |> edited_base()
        |> Map.merge(program)
        |> Map.merge(%{
          "transport" => "program",
          "backends" => [
            %{"name" => backend, "command" => trimmed(params, "command"), "env" => program["env"]}
          ]
        })
        |> Map.delete("env")
        |> put_entry(params)

      # A new driven program is installed: with a kept home and a sign-in,
      # its login entry is made and its sign-in opened.
      if socket.assigns.editing == nil and config["mark"] == "driven",
        do: install(socket, name, config),
        else: save(socket, name, config)
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

  # Enabling starts nothing here, but the details read after it may: a
  # `get` of an enabled row connects it, so the call runs off the page.
  def handle_event("toggle_enabled", %{"name" => name, "enabled" => enabled}, socket) do
    {action, working} =
      if enabled == "true",
        do: {"disable", "Disabling #{name}…"},
        else: {"enable", "Enabling #{name}…"}

    {:noreply, call(socket, working, {:toggle, name}, "mcp_servers/#{action}", %{"name" => name})}
  end

  def handle_event("test", %{"name" => name}, socket),
    do:
      {:noreply,
       call(socket, "Testing #{name}…", {:test, name}, "mcp_servers/test", %{"name" => name})}

  def handle_event("refresh", %{"name" => name}, socket) do
    {:noreply,
     call(socket, "Refreshing #{name}…", {:refresh, name}, "mcp_servers/refresh", %{
       "name" => name
     })}
  end

  def handle_event("restart", %{"name" => name}, socket) do
    {:noreply,
     call(socket, "Restarting #{name}…", {:restart, name}, "mcp_servers/restart", %{
       "name" => name
     })}
  end

  def handle_event("toggle_expand", %{"name" => name}, socket) do
    if socket.assigns.expanded_name == name do
      {:noreply, socket |> assign(:expanded_name, nil) |> assign(:detail, nil)}
    else
      {:noreply, expand_server(socket, name)}
    end
  end

  # The person signs a kept row in: with the entry an mcp program names, or
  # the entry picked, or a new one made for the program.
  def handle_event("sign_in", %{"name" => name} = params, socket) do
    case sign_in_entry(socket, name, params["entry"]) do
      {:ok, entry} -> {:noreply, open_terminal(socket, name, entry)}
      :new -> {:noreply, new_login(socket, name)}
      {:error, sentence} -> {:noreply, put_flash(socket, :error, sentence)}
    end
  end

  def handle_event("reset_home", %{"entry" => entry}, socket) when entry != "" do
    {:noreply,
     call(socket, "Emptying the folder…", :reset_home, "mcp_servers/reset_home", %{
       "entry" => entry
     })}
  end

  def handle_event("reset_home", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Choose the login entry whose folder to reset.")}

  # A program's network list changes with the rest of its config as it is
  # stored, since an update replaces the config whole, at the epoch the
  # row was read at.
  def handle_event("set_hosts", %{"name" => name} = params, socket) do
    detail = socket.assigns.detail

    config =
      detail
      |> config()
      |> Map.delete("hosts")
      |> put_present("hosts", host_list(params))

    args = %{"name" => name, "epoch" => detail && detail[:epoch], "config" => config}

    {:noreply,
     call(socket, "Saving #{name}'s hosts…", {:set_hosts, name}, "mcp_servers/update", args)}
  end

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

  # The sign-in relay's lines and its end, for the terminal open now; the
  # terminal reads only its own session's.
  def handle_info({Opus.Programs, token, event}, socket) do
    case socket.assigns.terminal do
      %{id: id} ->
        send_update(SignInTerminalComponent, id: id, relay: {token, event})
        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  # The session the terminal open now started, so selecting another target
  # closes it first. One a terminal no longer open started (the person
  # chose another target before its start was heard here) is closed now:
  # no session outlives the terminal it was opened for.
  def handle_info({SignInTerminalComponent, :started, id, token}, socket) do
    case socket.assigns.terminal do
      %{id: ^id} = terminal ->
        {:noreply, assign(socket, :terminal, %{terminal | token: token})}

      _other ->
        CyfrWeb.ContextGuard.guard(socket, fn socket ->
          Opus.Programs.sign_in_close(socket.assigns.context, token)
          {:noreply, socket}
        end)
    end
  end

  def handle_info({SignInTerminalComponent, :closed}, socket),
    do: {:noreply, socket |> assign(:terminal, nil) |> refresh_servers()}

  # A row expanded here and disabled elsewhere has its details read again:
  # a disabled row's `get` starts nothing, so it is read in place.
  def handle_info(%Cyfr.Bus.McpServers{}, socket) do
    socket = refresh_servers(socket)
    name = socket.assigns.expanded_name

    case Enum.find(socket.assigns.servers, &(&1[:name] == name)) do
      %{enabled: false} -> {:noreply, expand_server(socket, name)}
      _other -> {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  @impl true
  def handle_async(:call, {:ok, {tag, answer, outcome}}, socket),
    do:
      CyfrWeb.ContextGuard.deliver(
        assign(socket, :working, nil),
        tag,
        &{:noreply, called(&1, answer, outcome)}
      )

  # Only the node's shutdown stops a call (`run_to_end/1`).
  def handle_async(:call, {:exit, _reason}, socket), do: {:noreply, socket}

  # ————— a row's call —————

  # The call, off the event and run to its end, then the list read again,
  # and the row it names read again when it is the one expanded.
  defp call(socket, working, answer, tool, args) do
    ctx = socket.assigns.context
    tag = CyfrWeb.ContextGuard.capture(ctx)
    expand = expanded_after(answer)

    socket
    |> assign(:working, working)
    |> start_async(
      :call,
      fn ->
        outcome =
          run_to_end(fn ->
            result = call_tool(ctx, tool, args)
            {result, servers(ctx), expand && detail(ctx, expand)}
          end)

        {tag, answer, outcome}
      end,
      supervisor: Prism.TaskSupervisor
    )
  end

  defp expanded_after({kind, name}) when kind in [:restart, :set_hosts, :toggle, :update],
    do: name

  defp expanded_after(_answer), do: nil

  defp called(socket, answer, {:error, _crashed} = result),
    do: answered(socket, answer, result)

  defp called(socket, answer, {result, servers, detail}) do
    socket = assign(socket, :servers, servers)

    socket =
      case expanded_after(answer) do
        name when is_binary(name) and is_map(detail) -> expanded(socket, name, detail)
        _none -> socket
      end

    answered(socket, answer, result)
  end

  defp answered(socket, {:test, name}, {:ok, %{error: sentence}}) when is_binary(sentence),
    do: put_flash(socket, :error, "Test #{name}: #{sentence}")

  defp answered(socket, {:test, name}, {:ok, result}),
    do: put_flash(socket, :info, "Test #{name}: #{result[:status] || "unknown"}")

  defp answered(socket, {:test, _name}, {:error, reason}),
    do: put_flash(socket, :error, "Test failed: #{error_message(reason)}")

  defp answered(socket, {:refresh, name}, {:ok, _}),
    do: put_flash(socket, :info, "Refreshed #{name}.")

  defp answered(socket, {:refresh, _name}, {:error, reason}),
    do: put_flash(socket, :error, "Refresh failed: #{error_message(reason)}")

  defp answered(socket, {:restart, name}, {:ok, result}),
    do: put_flash(socket, :info, "Restarted #{name}: #{result[:status] || "unknown"}")

  defp answered(socket, {:restart, _name}, {:error, reason}),
    do: put_flash(socket, :error, "Restart failed: #{error_message(reason)}")

  defp answered(socket, :reset_home, {:ok, _}),
    do: put_flash(socket, :info, "The folder is empty again.")

  defp answered(socket, :reset_home, {:error, reason}),
    do: put_flash(socket, :error, "Reset failed: #{error_message(reason)}")

  defp answered(socket, {:set_hosts, _name}, {:ok, _}),
    do: put_flash(socket, :info, "The program's hosts are saved; its next start resolves them.")

  defp answered(socket, {:set_hosts, _name}, {:error, reason}),
    do: put_flash(socket, :error, "Saving the hosts failed: #{error_message(reason)}")

  defp answered(socket, {:toggle, _name}, {:ok, _}), do: socket

  defp answered(socket, {:toggle, _name}, {:error, reason}),
    do: put_flash(socket, :error, "Failed: #{error_message(reason)}")

  defp answered(socket, {:update, name}, {:ok, result}) do
    socket
    |> assign(:show_add, nil)
    |> assign(:form_error, nil)
    |> assign(:prefill, %{})
    |> assign(:editing, nil)
    |> saved_flash(name, result)
    |> warnings_flash(result)
  end

  defp answered(socket, {:update, _name}, {:error, reason}),
    do: assign(socket, :form_error, "Failed to save: #{error_message(reason)}")

  defp answered(socket, {:create, name}, {:ok, result}) do
    socket
    |> assign(:show_add, nil)
    |> assign(:form_error, nil)
    |> assign(:prefill, %{})
    |> added_flash(name, result)
    |> warnings_flash(result)
  end

  # A new driven program: the row, then (for a kept home with a sign-in)
  # a login entry for it and the sign-in terminal on it.
  defp answered(socket, {:install, name, config}, {:ok, result}) do
    socket =
      socket
      |> assign(:install, nil)
      |> answered({:create, name}, {:ok, result})

    if config["home"] == "kept" and present?(config["login_command"]),
      do: new_login(socket, name),
      else: socket
  end

  defp answered(socket, _adding, {:error, reason}),
    do: assign(socket, :form_error, "Failed to add: #{error_message(reason)}")

  # ————— defining a row —————

  # A new row, or the whole definition of the row the form edits; a
  # definition the form leaves as it was read is not written at all.
  defp save(%{assigns: %{editing: %{name: name, config: config}}} = socket, name, config),
    do: {:noreply, unchanged(socket, name)}

  defp save(%{assigns: %{editing: %{name: name, epoch: epoch}}} = socket, name, config) do
    args = %{"name" => name, "epoch" => epoch, "config" => config}
    {:noreply, call(socket, "Saving #{name}…", {:update, name}, "mcp_servers/update", args)}
  end

  defp save(socket, name, config) do
    args = %{"name" => name, "config" => config}
    {:noreply, call(socket, "Adding #{name}…", {:create, name}, "mcp_servers/create", args)}
  end

  defp unchanged(socket, name) do
    socket
    |> assign(:show_add, nil)
    |> assign(:editing, nil)
    |> assign(:prefill, %{})
    |> put_flash(:info, "Nothing changed in '#{name}'.")
  end

  defp update_server(socket, name, config, kept) do
    %{epoch: epoch} = socket.assigns.editing
    args = %{"name" => name, "epoch" => epoch, "config" => config, "keep_headers" => kept}
    call(socket, "Saving #{name}…", {:update, name}, "mcp_servers/update", args)
  end

  # One `Name: value` per line; blank lines are skipped.
  defp parse_headers(text) do
    text
    |> String.split(~r/\R/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, headers} ->
      case String.split(line, ":", parts: 2) do
        [name, value] when name != "" ->
          {:cont, {:ok, headers ++ [{String.trim(name), String.trim(value)}]}}

        _ ->
          {:halt, {:error, "Each header line is Name: value — #{inspect(line)} is not."}}
      end
    end)
  end

  # What an edit keeps of the definition it replaces: every member the
  # program form does not show (the timeout, the tool patterns, console
  # reach), exactly as read. The members it shows are its own, a blank one
  # clearing its member.
  @shown ~w(backends mark home memory_bytes home_max_bytes login_command login_entry_id hosts)

  defp edited_base(%{config: config}), do: Map.drop(config, @shown)
  defp edited_base(nil), do: %{}

  # An edit keeps the row's name: an update names the row it replaces.
  defp form_name(%{assigns: %{editing: %{name: name}}}, _params), do: name
  defp form_name(_socket, params), do: trimmed(params, "name")

  # The form an edit opens and what it holds: the program form for one
  # backend, the config form, as JSON, for more.
  defp edit_prefill(%{"backends" => [backend]} = config) do
    {"program",
     %{
       "backend" => backend["name"],
       "command" => backend["command"],
       "env" => Enum.map_join(backend["env"] || %{}, "\n", fn {k, v} -> "#{k}=#{v}" end),
       "mark" => config["mark"],
       "home" => config["home"],
       "memory_mib" => mib_text(config["memory_bytes"]),
       "disk_mib" => mib_text(config["home_max_bytes"]),
       "login_command" => config["login_command"],
       "login_entry_id" => config["login_entry_id"],
       "hosts" => config["hosts"]
     }}
  end

  defp edit_prefill(%{"transport" => "http"} = config) do
    {"server",
     %{
       "url" => config["url"],
       "headers" =>
         Enum.map_join(Enum.sort(config["headers"] || %{}), "\n", fn {k, v} -> "#{k}: #{v}" end)
     }}
  end

  defp edit_prefill(config), do: {"config", %{"config" => Jason.encode!(config, pretty: true)}}

  # A bound as its field shows it: whole MiB, or its exact bytes, so a
  # save leaves it as it was.
  defp mib_text(bytes) when is_integer(bytes) and rem(bytes, @mib) == 0,
    do: Integer.to_string(div(bytes, @mib))

  defp mib_text(bytes) when is_integer(bytes), do: "#{bytes} bytes"
  defp mib_text(_bytes), do: nil

  defp install(socket, name, config) do
    args = %{"name" => name, "config" => config}

    {:noreply,
     call(socket, "Adding #{name}…", {:install, name, config}, "mcp_servers/create", args)}
  end

  # The program form's settings: the mark, the env, the home, the bounds
  # in MiB, the login command and the hosts. Only what is set is sent.
  defp program_config(params) do
    with {:ok, env} <- parse_env(params["env"] || ""),
         {:ok, memory} <- mib(params, "memory_mib", "Memory"),
         {:ok, disk} <- mib(params, "disk_mib", "Disk") do
      home = if params["home"] == "kept", do: "kept", else: "scratch"

      mark = if params["mark"] == "driven", do: "driven", else: "mcp"

      {:ok,
       %{"env" => env, "home" => home, "mark" => mark}
       |> put_present("memory_bytes", memory)
       |> put_present("home_max_bytes", if(home == "kept", do: disk))
       |> put_present("login_command", blank_nil(trimmed(params, "login_command")))
       |> put_present("hosts", host_list(params))}
    end
  end

  # The hosts a form names, split on commas and white space; none, no list.
  defp host_list(params) do
    case String.split(params["hosts"] || "", [",", " ", "\n", "\t", "\r"], trim: true) do
      [] -> nil
      hosts -> hosts
    end
  end

  # A kept mcp program names its login entry.
  defp put_entry(%{"home" => "kept", "mark" => "mcp"} = config, params),
    do: put_present(config, "login_entry_id", blank_nil(trimmed(params, "login_entry")))

  defp put_entry(config, _params), do: config

  defp mib(params, key, what) do
    case trimmed(params, key) do
      "" ->
        {:ok, nil}

      text ->
        case Integer.parse(text) do
          {n, ""} when n > 0 ->
            {:ok, n * @mib}

          {n, " bytes"} when n > 0 ->
            {:ok, n}

          _ ->
            {:error, "#{what} bound is a whole number of MiB, or of bytes followed by \"bytes\"."}
        end
    end
  end

  defp added_flash(socket, name, %{error: sentence}) when is_binary(sentence),
    do: put_flash(socket, :error, "'#{name}' added — #{sentence}")

  defp added_flash(socket, name, result),
    do: put_flash(socket, :info, "'#{name}' added (#{result[:status] || "saved"}).")

  defp saved_flash(socket, name, %{error: sentence}) when is_binary(sentence),
    do: put_flash(socket, :error, "'#{name}' saved — #{sentence}")

  defp saved_flash(socket, name, result),
    do: put_flash(socket, :info, "'#{name}' saved (#{result[:status] || "saved"}).")

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

  # The program form, driven and kept, prefilled from the component's login
  # need: what the need's install block suggests, every field the person's
  # to change.
  defp prefill_install(socket, ref, need_name) do
    with {:ok, plan} <-
           call_tool(socket, "component", %{"action" => "setup_plan", "reference" => ref}),
         %{} = need <- Enum.find(field(plan, :needs) || [], &login_need?(&1, need_name)) do
      install = field(need, :install) || %{}

      socket
      |> assign(:show_add, "program")
      |> assign(:form_error, nil)
      |> assign(:editing, nil)
      |> assign(:install, %{ref: ref, need: need_name, reason: field(need, :reason)})
      |> assign(:prefill, %{
        "mark" => "driven",
        "home" => "kept",
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
      server[:mark] == "mcp" and present?(named) ->
        {:ok, named}

      server[:mark] == "mcp" ->
        {:error, "This program names no login entry; edit it to name one, then sign in."}

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

  # One sign-in at a time: a terminal for a new target closes the session
  # of the one before (or, when that session's start has not been heard
  # here yet, closes it when it is: the `:started` above), and each
  # terminal is a component of its own, so selecting a target, or the same
  # one again after its session ended, starts afresh and never reaches the
  # previous session.
  defp open_terminal(socket, name, entry) do
    close_terminal(socket)
    id = "sign-in-#{System.unique_integer([:positive])}"
    assign(socket, :terminal, %{id: id, row: name, entry: entry, token: nil})
  end

  defp close_terminal(%{assigns: %{terminal: %{token: token}, context: context}})
       when is_binary(token),
       do: Opus.Programs.sign_in_close(context, token)

  defp close_terminal(_socket), do: :ok

  # ————— reading —————

  defp expand_server(socket, name), do: expanded(socket, name, detail(socket, name))

  defp detail(socket_or_ctx, name) do
    case call_tool(socket_or_ctx, "mcp_servers/get", %{"name" => name}) do
      {:ok, result} -> result
      {:error, _} -> nil
    end
  end

  defp expanded(socket, name, detail) do
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

  defp refresh_servers(socket), do: assign(socket, :servers, servers(socket))

  defp servers(socket_or_ctx) do
    case call_tool(socket_or_ctx, "mcp_servers/list", %{}) do
      {:ok, %{servers: list}} -> list
      _ -> []
    end
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
          <.button variant="ghost" phx-click="toggle_add" phx-value-form="program">
            {if @show_add == "program", do: "Cancel", else: "Add program"}
          </.button>
          <.button phx-click="toggle_add" phx-value-form="config">
            {if @show_add == "config", do: "Cancel", else: "Add server"}
          </.button>
        </:actions>
      </.page_header>

      <p :if={@working} role="status" data-test="programs-working" class="text-sm text-gray-300">
        {@working}
      </p>

      <.live_component module={SystemLayer} id={SystemLayer.layer_id()} context={@context} />

      <.live_component
        :if={@terminal}
        module={SignInTerminalComponent}
        id={@terminal.id}
        context={@context}
        row={@terminal.row}
        entry={@terminal.entry}
      />

      <.card :if={@show_add == "program"}>
        <form id="add-program" phx-submit="add_program" class="space-y-4">
          <p :if={@install} class="text-sm text-gray-300" data-test="install-from">
            Install <span class="font-mono">{@prefill["name"]}</span>
            for <span class="font-mono">{@install.ref}</span>
            — {@install.reason}. This is the program as it will run; change anything first.
            Saving it makes a login entry for it and opens its sign-in.
          </p>
          <p :if={@editing} class="text-sm text-gray-300" data-test="editing">
            Replace the whole definition of <span class="font-mono">{@editing.name}</span>.
            Its folder is kept.
          </p>
          <p :if={!@install && !@editing} class="text-xs text-gray-500">
            A program the backends service runs under a user of its own, such as an
            <code class="text-gray-400">npx</code>
            package. Its command fetches or runs it; CYFR ships none.
          </p>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
            <.input
              name="name"
              required
              value={@prefill["name"]}
              disabled={@editing != nil}
              placeholder="github"
              class="max-w-xs font-mono"
            />
            <input type="hidden" name="backend" value={@prefill["backend"]} />
          </div>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">Command</label>
            <.input
              name="command"
              required
              value={@prefill["command"]}
              placeholder="npx -y @modelcontextprotocol/server-github"
              class="font-mono"
            />
          </div>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">How it is spoken to</label>
            <select
              name="mark"
              data-test="mark"
              class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white"
            >
              <option value="mcp" selected={@prefill["mark"] != "driven"}>
                MCP: CYFR offers its tools, named &lt;name&gt;:&lt;name&gt;__&lt;tool&gt;
              </option>
              <option value="driven" selected={@prefill["mark"] == "driven"}>
                driven: a person or a brain runs it, such as a coding harness
              </option>
            </select>
          </div>
          <.program_fields prefill={@prefill} logins={@logins} />
          <div :if={@form_error} class="text-sm text-red-400">{@form_error}</div>
          <.button type="submit">
            {cond do
              @install -> "Install"
              @editing -> "Save program"
              true -> "Add program"
            end}
          </.button>
        </form>
      </.card>

      <.card :if={@show_add == "server" and @editing}>
        <form id="edit-server" phx-submit="save_server" class="space-y-4">
          <p class="text-sm text-gray-300" data-test="editing">
            Replace the whole definition of <span class="font-mono">{@editing.name}</span>, a
            tool server elsewhere. A header shown as <code class="text-gray-400">[set]</code>
            keeps its stored value unless you type a new one.
          </p>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">Address</label>
            <.input name="url" required value={@prefill["url"]} class="font-mono" />
          </div>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">
              Headers (Name: value per line)
            </label>
            <textarea
              name="headers"
              rows="4"
              class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 font-mono"
            >{@prefill["headers"]}</textarea>
            <p class="text-xs text-gray-600 mt-1">
              A value may be <code class="text-gray-500">vault:ENTRY</code>
              or <code class="text-gray-500">Bearer vault:ENTRY</code>, a single-field entry
              whose destination covers this address.
            </p>
          </div>
          <div :if={@form_error} class="text-sm text-red-400">{@form_error}</div>
          <.button type="submit">Save</.button>
        </form>
      </.card>

      <.card :if={@show_add == "config"}>
        <form id="add-config" phx-submit="add_server" class="space-y-4">
          <p :if={@editing} class="text-sm text-gray-300" data-test="editing">
            Replace the whole definition of <span class="font-mono">{@editing.name}</span>.
            Its folder is kept.
          </p>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
            <.input
              name="name"
              required
              value={@prefill["name"]}
              disabled={@editing != nil}
              placeholder="notion"
              class="max-w-xs font-mono"
            />
          </div>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">
              Config (mcp.json format)
            </label>
            <textarea
              name="config"
              rows="6"
              required
              placeholder={@placeholder_config}
              class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 font-mono"
            >{@prefill["config"]}</textarea>
            <p class="text-xs text-gray-600 mt-1">
              A header value may be <code class="text-gray-500">vault:ENTRY</code>
              or <code class="text-gray-500">Bearer vault:ENTRY</code>, a single-field entry
              whose destination covers this server's URL (create one on the Vault page). A program's config is <code class="text-gray-500">{"{\"transport\": \"program\", \"mark\": \"mcp\" | \"driven\", \"backends\": [...], \"home\": ..., ...}"}</code>.
            </p>
          </div>
          <div :if={@form_error} class="text-sm text-red-400">{@form_error}</div>
          <.button type="submit">{if @editing, do: "Save", else: "Add server"}</.button>
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
                  Folder
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
                      {kind(server)}
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
                        :if={server[:transport] == "program"}
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
                            do: bytes(config(@detail)["home_max_bytes"], "the folders' volume"),
                            else: "scratch folder"}
                        </dd>
                        <dt class="text-gray-500">Sign-in command</dt>
                        <dd class="font-mono text-gray-300">
                          {config(@detail)["login_command"] || "none"}
                        </dd>
                        <dt
                          :if={server[:mark] == "mcp" and server[:home] == "kept"}
                          class="text-gray-500"
                        >
                          Login entry
                        </dt>
                        <dd
                          :if={server[:mark] == "mcp" and server[:home] == "kept"}
                          class="font-mono text-gray-300"
                        >
                          {entry_name(@logins, config(@detail)["login_entry_id"]) || "none named"}
                        </dd>
                        <dt class="text-gray-500">Hosts</dt>
                        <dd class="font-mono text-gray-300" data-test="program-hosts">
                          {Enum.join(config(@detail)["hosts"] || ["every public host"], ", ")}
                        </dd>
                      </dl>
                      <form
                        :if={@detail && server[:transport] == "program"}
                        id={"hosts-" <> server[:name]}
                        phx-submit="set_hosts"
                        class="flex flex-wrap items-end gap-2"
                      >
                        <input type="hidden" name="name" value={server[:name]} />
                        <div class="grow">
                          <label class="block text-xs text-gray-500 uppercase mb-1">Hosts</label>
                          <.input
                            name="hosts"
                            value={Enum.join(config(@detail)["hosts"] || [], ", ")}
                            placeholder="every public host"
                            class="font-mono"
                          />
                        </div>
                        <.button type="submit" variant="secondary">Save hosts</.button>
                      </form>
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
                            · folder {bytes(program["home_bytes"], "")}
                          </span>
                          <span :if={program["over_cap"]} class="text-xs text-red-400">
                            over its disk bound: reset its folder to run it again
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
                          :if={@detail}
                          variant="ghost"
                          phx-click="edit"
                          phx-value-name={server[:name]}
                          data-test="edit"
                        >
                          Edit
                        </.button>
                        <.button
                          :if={server[:mark] != "driven"}
                          variant="ghost"
                          phx-click="test"
                          phx-value-name={server[:name]}
                        >
                          Test
                        </.button>
                        <.button
                          :if={server[:mark] != "driven"}
                          variant="ghost"
                          phx-click="refresh"
                          phx-value-name={server[:name]}
                        >
                          Refresh
                        </.button>
                        <.button
                          :if={server[:mark] == "mcp"}
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

  attr :prefill, :map, required: true
  attr :logins, :list, required: true

  # A program's settings beside its name, command and mark.
  defp program_fields(assigns) do
    ~H"""
    <div>
      <label class="block text-xs text-gray-500 uppercase mb-1">Sign-in command</label>
      <.input
        name="login_command"
        value={@prefill["login_command"]}
        placeholder="optional, such as claude auth login"
        class="font-mono"
      />
    </div>
    <div class="grid gap-3 md:grid-cols-3">
      <div>
        <label class="block text-xs text-gray-500 uppercase mb-1">Folder</label>
        <select
          name="home"
          class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white"
        >
          <option value="kept" selected={@prefill["home"] == "kept"}>
            kept: the program keeps its folder and its sign-in
          </option>
          <option value="scratch" selected={@prefill["home"] != "kept"}>
            scratch: a fresh folder each run
          </option>
        </select>
      </div>
      <div>
        <label class="block text-xs text-gray-500 uppercase mb-1">Memory bound (MiB)</label>
        <.input
          name="memory_mib"
          value={@prefill["memory_mib"]}
          placeholder="the service's"
          class="font-mono"
        />
      </div>
      <div>
        <label class="block text-xs text-gray-500 uppercase mb-1">Disk bound (MiB, kept)</label>
        <.input
          name="disk_mib"
          value={@prefill["disk_mib"]}
          placeholder="the folders' volume"
          class="font-mono"
        />
      </div>
    </div>
    <div>
      <label class="block text-xs text-gray-500 uppercase mb-1">Hosts</label>
      <.input
        name="hosts"
        value={Enum.join(@prefill["hosts"] || [], ", ")}
        placeholder="every public host"
        class="font-mono"
      />
      <p class="text-xs text-gray-600 mt-1" data-test="hosts-help">
        The only hosts the program reaches, beside the deployment's private hosts: exact names
        such as <code class="text-gray-500">api.anthropic.com</code>, separated by commas, with
        no wildcard, scheme or port, resolved each time it starts. Left empty, it reaches every
        public host. A name that shares an address with another, as names behind one CDN or
        front end do, admits that other too.
      </p>
    </div>
    <div>
      <label class="block text-xs text-gray-500 uppercase mb-1">
        Login entry (a kept MCP program)
      </label>
      <select
        name="login_entry"
        class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white"
      >
        <option value="">none</option>
        <option
          :for={login <- @logins}
          value={login.id}
          selected={login.id == @prefill["login_entry_id"]}
        >
          {login.name} (program {login.program})
        </option>
      </select>
      <p class="text-xs text-gray-600 mt-1">
        An MCP program that signs in on its own keeps its folder in a login entry naming it. A
        driven program's folder is its component's login entry.
      </p>
    </div>
    <div>
      <label class="block text-xs text-gray-500 uppercase mb-1">Env (NAME=value per line)</label>
      <textarea
        name="env"
        rows="3"
        placeholder="GITHUB_PERSONAL_ACCESS_TOKEN=vault:github-token"
        class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 font-mono"
      >{@prefill["env"]}</textarea>
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
          :if={@server[:mark] == "driven"}
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
          data-confirm="Empty this folder? The program's sign-in and everything it kept there are removed."
        >
          Reset folder
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

  defp home_line(%{transport: "program"} = server), do: server[:home] || "scratch"

  defp home_line(_server), do: "—"

  defp bytes(nil, fallback), do: fallback
  defp bytes(n, _fallback) when is_integer(n) and n >= @mib, do: "#{div(n, @mib)} MiB"
  defp bytes(n, _fallback) when is_integer(n), do: "#{n} bytes"
  defp bytes(_n, fallback), do: fallback

  defp endpoint(%{mark: "mcp"}), do: "MCP (backends service)"
  defp endpoint(%{mark: "driven"}), do: "driven by a person or a brain"
  defp endpoint(server), do: server[:url]

  defp kind(%{transport: "program", mark: mark}), do: "#{mark} program"
  defp kind(_server), do: "http"

  defp status_color(status) when status in ["ready", "connected", "running"], do: "green"
  defp status_color(status) when status in ["error", "crashed", "failed"], do: "red"

  defp status_color(status)
       when status in ["disconnected", "connecting", "starting", "idle", "stopped"],
       do: "yellow"

  defp status_color(_), do: "gray"
end
