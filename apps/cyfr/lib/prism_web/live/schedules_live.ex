# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SchedulesLive do
  @moduledoc """
  Cron schedules: list, create, edit, pause, resume and delete through
  the `schedule` tool.

  New Schedule and a row's Edit open one form: Edit prefills it with the
  schedule and saves through `schedule.update`, sending what it runs (the
  reference) and the profile only when they changed, since naming them is
  binding the schedule again, which the tool authorizes as at create. The
  save names the definition the form was opened with: a schedule changed
  since is refused, and the form shows it as it is now. A
  change of kind, a component's schedule made a line for Aqua or back, is
  the same form's Runs choice. A refusal shows in the form in the tool's
  own words, and the form keeps what was typed.

  A schedule runs its component under the profile it names, standing on
  the person's grant: making it on this page is the person's decision that
  it runs, so no grant asks again who may start it. A run a schedule
  starts records the `schedule` origin.

  A schedule may instead hold a line for Aqua: each time it runs, Aqua is
  sent the line in the person's daily thread, under the schedule's name,
  and uses the tools it is offered (`Aqua.ScheduleTurns`). The person
  makes one here, signed in, and Aqua or a crew member may make one from
  a turn of theirs, which fires in that turn's workspace thread when it
  worked under one. Each row names who set it (the person, or that agent)
  and, for a line for Aqua, where it fires: the daily thread, or the
  workspace thread by its title. A schedule set for one time reads as
  Once; editing it keeps it once unless its time is changed. The newest
  25 show first, and Show more adds 25 older ones at a time, so every
  live schedule can be reached and stopped.

  Below the schedules, the athanor's feeds (`feed.list`): each feed's name,
  binding id, component, operation, interval, the time of its last
  accepted result and its actions' labels, removed through `feed.remove`.
  The page never shows a feed's arguments or a result's content. It reads
  them again when a result is published (`Cyfr.Bus.FeedPublished`) and
  when a run ends. A feed's fire is a scheduled fire to the telemetry and
  the tray, which name it by its binding id.
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  alias PrismWeb.SystemLayer

  require Logger

  @aqua_line Arca.CronSchedule.aqua_line()

  @empty_form %{
    "name" => "",
    "target" => "component",
    "line" => "",
    "reference" => "",
    "profile_id" => "",
    "input" => "",
    "missed_runs" => "skip",
    "catch_up_limit" => ""
  }

  # How many schedules the page shows at first, and how many more each
  # Show more adds; and the most the `schedule` tool lists in one call.
  @page 25
  @tool_page 1000

  @cron_presets [
    {"Every minute", "* * * * *"},
    {"Every 5 minutes", "*/5 * * * *"},
    {"Every 15 minutes", "*/15 * * * *"},
    {"Every 30 minutes", "*/30 * * * *"},
    {"Every hour", "0 * * * *"},
    {"Every 6 hours", "0 */6 * * *"},
    {"Every 12 hours", "0 */12 * * *"},
    {"Daily at midnight", "0 0 * * *"},
    {"Daily at 9am", "0 9 * * *"},
    {"Weekdays at 9am", "0 9 * * 1-5"},
    {"Weekly (Sunday midnight)", "0 0 * * 0"},
    {"Monthly (1st at midnight)", "0 0 1 * *"},
    {"Custom", "custom"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      actor = Sanctum.Context.actor(socket.assigns[:context])

      for topic <- [
            Cyfr.Bus.schedules(actor),
            Cyfr.Bus.executions(actor),
            Cyfr.Bus.components(actor),
            Cyfr.Bus.feeds(actor)
          ],
          do: Cyfr.Bus.subscribe(actor, topic)
    end

    socket =
      socket
      |> assign(:page_title, "Schedules")
      |> assign(:active_nav, "schedules")
      |> assign(:schedules, [])
      |> assign(:shown, @page)
      |> assign(:more?, false)
      |> assign(:rooms, %{})
      |> assign(:feeds, [])
      |> assign(:components, [])
      |> assign(:loading, true)
      |> assign(:show_create, false)
      |> assign(:cron_preset, "")
      |> assign(:cron_custom, "")
      |> assign(:form, to_form(@empty_form))
      |> assign(:editing, nil)
      |> assign(:form_error, nil)
      |> assign(:focused_id, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_create", _params, socket) do
    if socket.assigns.show_create,
      do: {:noreply, close_form(socket)},
      else: {:noreply, socket |> fetch_components() |> assign(:show_create, true)}
  end

  # The next older schedules, after the ones shown.
  def handle_event("show_more", _params, socket),
    do: {:noreply, socket |> assign(:shown, socket.assigns.shown + @page) |> fetch_schedules()}

  # A row's Edit: the one form, prefilled with the schedule as listed.
  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.schedules, &(f(&1, :schedule_id) == id)) do
      nil ->
        {:noreply, socket}

      sched ->
        {:noreply, socket |> fetch_components() |> open_edit(sched)}
    end
  end

  def handle_event("cron_preset_change", %{"cron_preset" => preset}, socket) do
    {:noreply, assign(socket, :cron_preset, preset)}
  end

  # What the schedule runs: a component, or a line for Aqua.
  def handle_event("target_change", %{"target" => target}, socket)
      when target in ["component", "aqua"] do
    form = Map.merge(socket.assigns.form.params, %{"target" => target})
    {:noreply, assign(socket, :form, to_form(form))}
  end

  def handle_event("create", %{"name" => name, "target" => "aqua"} = params, socket) do
    cron = cron_of(socket, params)
    socket = keep_form(socket, params)

    with :ok <- if(cron == "", do: {:error, "Please select a schedule frequency"}, else: :ok),
         {:ok, missed_args} <- missed_input(params) do
      args =
        Map.merge(missed_args, %{
          "action" => "create",
          "name" => name,
          "cron_expression" => cron,
          "reference" => @aqua_line,
          "input" => %{"line" => params["line"] || ""}
        })

      {:noreply, create_schedule(socket, args)}
    else
      {:error, reason} -> {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event("create", %{"name" => name, "reference" => ref} = params, socket) do
    cron = cron_of(socket, params)
    socket = keep_form(socket, params)

    with {:ok, input_args} <- create_input(params, cron),
         {:ok, missed_args} <- missed_input(params) do
      args =
        input_args
        |> Map.merge(missed_args)
        |> Map.merge(%{
          "action" => "create",
          "name" => name,
          "cron_expression" => cron,
          "reference" => ref,
          "profile_id" => params["profile_id"]
        })

      {:noreply, create_schedule(socket, args)}
    else
      {:error, reason} -> {:noreply, refuse(socket, reason)}
    end
  end

  # The edited schedule saved through `schedule.update`; the schedule is
  # the one the form was opened for, never one the submission names.
  def handle_event("save", params, %{assigns: %{editing: %{} = sched}} = socket) do
    socket = keep_form(socket, params)

    with {:ok, args} <- update_args(sched, params, cron_of(socket, params)),
         {:ok, _} <- call_tool(socket, "schedule", args) do
      {:noreply,
       socket |> close_form() |> fetch_schedules() |> put_flash(:info, "Schedule saved")}
    else
      {:error, :schedule_changed} -> {:noreply, reopen(socket, sched)}
      {:error, reason} -> {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  # A schedule's missed-run policy, changed in its row. The tool decides
  # what a limit may be; the page only reads the number it was given.
  def handle_event("missed_runs", %{"schedule_id" => id} = params, socket) do
    with {:ok, missed_args} <- missed_input(params),
         {:ok, _} <-
           call_tool(
             socket,
             "schedule",
             Map.merge(missed_args, %{"action" => "update", "schedule_id" => id})
           ) do
      {:noreply, socket |> fetch_schedules() |> put_flash(:info, "Missed runs saved")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{error_message(reason)}")}
    end
  end

  def handle_event("pause", %{"id" => id}, socket) do
    case call_tool(socket, "schedule", %{"action" => "pause", "schedule_id" => id}) do
      {:ok, _} ->
        {:noreply, fetch_schedules(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{error_message(reason)}")}
    end
  end

  def handle_event("resume", %{"id" => id}, socket) do
    case call_tool(socket, "schedule", %{"action" => "resume", "schedule_id" => id}) do
      {:ok, _} ->
        {:noreply, fetch_schedules(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{error_message(reason)}")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case call_tool(socket, "schedule", %{"action" => "delete", "schedule_id" => id}) do
      {:ok, _} ->
        {:noreply, fetch_schedules(socket) |> put_flash(:info, "Schedule deleted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{error_message(reason)}")}
    end
  end

  def handle_event("remove_feed", %{"id" => id}, socket) do
    case call_tool(socket, "feed", %{"action" => "remove", "binding" => id}) do
      {:ok, _} ->
        {:noreply, fetch_feeds(socket) |> put_flash(:info, "Feed removed")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{error_message(reason)}")}
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> fetch_schedules() |> fetch_feeds()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if connected?(socket), do: send(self(), :load)

    # `ui.schedule.focus` navigates here with `?id=sched_…`. This page has
    # no detail row to open — a schedule IS its row — so focus marks the
    # row instead of expanding it. Unlike the pages with a click-driven
    # expansion, nothing else sets this, so an absent key clears it.
    {:noreply, assign(socket, :focused_id, focused_id(params["id"]))}
  end

  defp focused_id(id) when is_binary(id) and id != "", do: id
  defp focused_id(_id), do: nil

  @impl true
  def handle_info(:load, socket) do
    {:noreply,
     socket
     |> fetch_schedules()
     |> fetch_feeds()
     |> fetch_components()
     |> assign(:loading, false)}
  end

  def handle_info(%Cyfr.Bus.Schedules{}, socket) do
    {:noreply, fetch_schedules(socket)}
  end

  # A feed's result was accepted: its last result time moved.
  def handle_info(%Cyfr.Bus.FeedPublished{}, socket) do
    {:noreply, fetch_feeds(socket)}
  end

  # Refresh schedule and feed stats when executions end (run_count,
  # last_run_at update)
  def handle_info(%Cyfr.Bus.Execution{kind: kind}, socket)
      when kind in [:completed, :failed, :cancelled] do
    {:noreply, socket |> fetch_schedules() |> fetch_feeds()}
  end

  def handle_info(%Cyfr.Bus.Execution{}, socket), do: {:noreply, socket}

  # Refresh the component dropdown when the registry changes, whatever changed it
  def handle_info(%Cyfr.Bus.Components{}, socket) do
    {:noreply, fetch_components(socket)}
  end

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  defp create_schedule(socket, args) do
    case call_tool(socket, "schedule", args) do
      {:ok, _} ->
        socket
        |> close_form()
        |> fetch_schedules()
        |> put_flash(:info, "Schedule created")

      {:error, reason} ->
        refuse(socket, reason)
    end
  end

  defp close_form(socket) do
    assign(socket,
      show_create: false,
      editing: nil,
      form_error: nil,
      cron_preset: "",
      cron_custom: "",
      form: to_form(@empty_form)
    )
  end

  # The form opened for `sched` as listed, its time as a preset or custom.
  defp open_edit(socket, sched) do
    cron = f(sched, :cron_expression)
    preset = if Enum.any?(@cron_presets, &(elem(&1, 1) == cron)), do: cron, else: "custom"

    assign(socket,
      show_create: true,
      editing: sched,
      form_error: nil,
      cron_preset: preset,
      cron_custom: cron,
      form: to_form(edit_params(sched))
    )
  end

  # The schedule changed after the form was opened: the form shows it as
  # it is now, or, when it is gone, says so.
  defp reopen(socket, sched) do
    socket = fetch_schedules(socket)
    id = f(sched, :schedule_id)

    case Enum.find(socket.assigns.schedules, &(f(&1, :schedule_id) == id)) do
      nil ->
        refuse(socket, {:not_found, "Schedule", id})

      now ->
        socket
        |> open_edit(now)
        |> assign(
          :form_error,
          "This schedule changed since you opened it. The form now shows it as it is; make your change again."
        )
    end
  end

  # A refusal, the page's or the tool's, in the form's one line.
  defp refuse(socket, reason), do: assign(socket, :form_error, error_message(reason))

  # The form's fields for a schedule as `schedule.list` answers it.
  defp edit_params(sched) do
    aqua? = f(sched, :reference) == @aqua_line

    Map.merge(@empty_form, %{
      "name" => f(sched, :name),
      "target" => if(aqua?, do: "aqua", else: "component"),
      "line" => line_of(sched),
      "reference" => if(aqua?, do: "", else: f(sched, :reference)),
      "profile_id" => f(sched, :profile_id) || "",
      "input" => if(aqua?, do: "", else: input_text(f(sched, :input))),
      "missed_runs" => f(sched, :missed_runs) || "skip",
      "catch_up_limit" => to_string(f(sched, :catch_up_limit) || "")
    })
  end

  defp input_text(input) when is_map(input), do: Jason.encode!(input)
  defp input_text(_none), do: ""

  # `schedule.update`'s arguments for the form as submitted, against the
  # definition the form was opened with, which the store compares under
  # the row's lock. The name, the time, the missed-run policy and the input
  # or line are always sent; the reference and the profile only when they
  # changed, as naming them binds the schedule again (and resolves an
  # unversioned reference anew). An emptied input clears the component's.
  defp update_args(sched, %{"target" => "aqua"} = params, cron) do
    with :ok <- if(cron == "", do: {:error, "Please select a schedule frequency"}, else: :ok),
         {:ok, missed_args} <- missed_input(params) do
      {:ok,
       missed_args
       |> Map.merge(update_base(sched, params, cron))
       |> Map.put("input", %{"line" => params["line"] || ""})
       |> changed("reference", @aqua_line, f(sched, :reference))}
    end
  end

  defp update_args(sched, params, cron) do
    with {:ok, input_args} <- create_input(params, cron),
         {:ok, missed_args} <- missed_input(params) do
      {:ok,
       missed_args
       |> Map.merge(update_base(sched, params, cron))
       |> Map.put("input", input_args["input"])
       |> changed("reference", params["reference"], f(sched, :reference))
       |> changed("profile_id", params["profile_id"], f(sched, :profile_id))}
    end
  end

  defp update_base(sched, params, cron) do
    %{
      "action" => "update",
      "schedule_id" => f(sched, :schedule_id),
      "definition" => f(sched, :definition),
      "name" => params["name"]
    }
    |> changed("cron_expression", cron, f(sched, :cron_expression))
  end

  defp changed(args, _key, value, value), do: args
  defp changed(args, key, value, _was), do: Map.put(args, key, value)

  # The components the form offers, with the one an edited schedule runs
  # though it is not listed (an unversioned or since-removed reference).
  defp component_options(components, current) when is_binary(current) and current != "",
    do: if(current in components, do: components, else: [current | components])

  defp component_options(components, _current), do: components

  defp cron_of(socket, params) do
    case socket.assigns.cron_preset do
      "custom" -> params["cron_custom"] || ""
      "" -> ""
      preset -> preset
    end
  end

  defp keep_form(socket, params) do
    socket
    |> assign(:form, to_form(Map.merge(@empty_form, Map.take(params, Map.keys(@empty_form)))))
    |> assign(:cron_custom, params["cron_custom"] || socket.assigns.cron_custom)
  end

  defp create_input(params, cron) do
    cond do
      cron == "" ->
        {:error, "Please select a schedule frequency"}

      not is_binary(params["profile_id"]) or String.trim(params["profile_id"]) == "" ->
        {:error, "Please enter the profile that authorizes this schedule"}

      true ->
        decode_input(params["input"])
    end
  end

  # What the form says of missed runs, as the tool's arguments: `skip`
  # takes no limit, and `catch_up` the whole number entered (the tool
  # refuses one out of its range).
  defp missed_input(%{"missed_runs" => "catch_up"} = params) do
    case Integer.parse(String.trim(params["catch_up_limit"] || "")) do
      {limit, ""} -> {:ok, %{"missed_runs" => "catch_up", "catch_up_limit" => limit}}
      _ -> {:error, "Catching up needs how many missed runs to fire, a whole number"}
    end
  end

  defp missed_input(_params), do: {:ok, %{"missed_runs" => "skip"}}

  defp decode_input(input) when input in [nil, ""], do: {:ok, %{}}

  defp decode_input(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, value} when is_map(value) -> {:ok, %{"input" => value}}
      _ -> {:error, "Input must be a valid JSON object"}
    end
  end

  defp decode_input(_input), do: {:error, "Input must be a valid JSON object"}

  # The newest `shown` live schedules, and whether any older one waits
  # behind them: read one past them, in the tool's pages of at most
  # @tool_page.
  defp fetch_schedules(socket) do
    shown = socket.assigns.shown
    rows = list_schedules(socket, 0, shown + 1, [])

    socket
    |> assign(:schedules, Enum.take(rows, shown))
    |> assign(:more?, length(rows) > shown)
    |> assign(:rooms, rooms(socket, Enum.take(rows, shown)))
  end

  defp list_schedules(_socket, _offset, 0, acc), do: acc

  defp list_schedules(socket, offset, wanted, acc) do
    limit = min(wanted, @tool_page)

    case call_tool(socket, "schedule", %{"action" => "list", "limit" => limit, "offset" => offset}) do
      {:ok, %{schedules: page}} when length(page) == limit ->
        list_schedules(socket, offset + limit, wanted - limit, acc ++ page)

      {:ok, %{schedules: page}} ->
        acc ++ page

      other ->
        Logger.warning("[SchedulesLive] schedule list failed: #{inspect(other)}")
        acc
    end
  end

  # The title of each workspace thread a shown line for Aqua fires in, by
  # id; one that does not read is shown by its id. A component's schedule
  # fires in no thread, so none is read for it.
  defp rooms(socket, schedules) do
    actor = Sanctum.Context.actor(socket.assigns[:context])

    for sched <- schedules,
        f(sched, :reference) == @aqua_line,
        id = f(sched, :thread_id),
        is_binary(id),
        uniq: true,
        into: %{} do
      case Arca.ThreadStorage.get(actor, id) do
        {:ok, %{title: title}} when is_binary(title) -> {id, title}
        _unread -> {id, id}
      end
    end
  end

  # Who set a schedule: the person, or the agent whose turn did.
  defp maker_label(sched) do
    case f(sched, :maker) do
      maker when is_binary(maker) -> "Set by " <> maker
      _person -> "Set by you"
    end
  end

  # Where a line for Aqua fires; a component's schedule fires in no thread.
  defp room_label(sched, rooms) do
    cond do
      f(sched, :reference) != @aqua_line -> nil
      id = f(sched, :thread_id) -> "Workspace thread: " <> Map.get(rooms, id, id)
      true -> "Daily thread"
    end
  end

  # `feed.list` answers no arguments and no result's content, so the page
  # has none to show.
  defp fetch_feeds(socket) do
    feeds =
      case call_tool(socket, "feed", %{"action" => "list"}) do
        {:ok, %{feeds: list}} when is_list(list) ->
          list

        other ->
          Logger.warning("[SchedulesLive] feed list failed: #{inspect(other)}")
          []
      end

    assign(socket, :feeds, feeds)
  end

  defp interval_label(1), do: "Every minute"
  defp interval_label(60), do: "Every hour"
  defp interval_label(minutes) when is_integer(minutes), do: "Every #{minutes} minutes"
  defp interval_label(_minutes), do: "-"

  defp action_labels(actions) when is_list(actions),
    do: Enum.map_join(actions, ", ", &f(&1, :label))

  defp action_labels(_actions), do: ""

  defp fetch_components(socket) do
    all =
      case call_tool(socket, "component", %{"action" => "list", "limit" => 1000}) do
        {:ok, %{components: list}} ->
          list

        other ->
          Logger.warning("[SchedulesLive] component list failed: #{inspect(other)}")
          []
      end

    # Every row of `component.list` carries its versioned reference.
    assign(socket, :components, Enum.map(all, & &1.component_ref))
  end

  defp line_of(sched) do
    case f(sched, :input) do
      %{"line" => line} when is_binary(line) -> line
      _none -> ""
    end
  end

  defp status_badge_color("active"), do: "green"
  defp status_badge_color("paused"), do: "yellow"
  defp status_badge_color(_), do: "gray"

  defp cron_label(expr) do
    case Enum.find(@cron_presets, fn {_label, val} -> val == expr end) do
      {label, _} -> label
      nil -> expr
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, cron_presets: @cron_presets, aqua_line: @aqua_line)

    ~H"""
    <div class="space-y-6">
      <.page_header title="Cron Schedules">
        <:actions>
          <.button variant="secondary" size="sm" phx-click="refresh">Refresh</.button>
          <.button variant={if @show_create, do: "ghost", else: "primary"} phx-click="toggle_create">
            {if @show_create, do: "Cancel", else: "New Schedule"}
          </.button>
        </:actions>
      </.page_header>

      <!-- Create form -->
      <div :if={@show_create}>
        <.card>
          <.form
            for={@form}
            id="schedule-form"
            phx-submit={if @editing, do: "save", else: "create"}
            class="space-y-4 p-4"
          >
            <h3 :if={@editing} class="text-sm font-medium text-white" data-test="schedule-editing">
              Edit {f(@editing, :name)}
            </h3>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="block text-xs font-medium text-gray-400 mb-1">Name</label>
                <.input name="name" value={@form[:name].value} placeholder="my-schedule" required />
              </div>
              <div>
                <label class="block text-xs font-medium text-gray-400 mb-1">Frequency</label>
                <select
                  name="cron_preset"
                  phx-change="cron_preset_change"
                  required
                  class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                >
                  <option value="" disabled selected={@cron_preset == ""}>
                    Select a schedule...
                  </option>
                  <%= for {label, value} <- @cron_presets do %>
                    <option value={value} selected={@cron_preset == value}>
                      {label}{if value != "custom", do: " — #{value}", else: ""}
                    </option>
                  <% end %>
                </select>
              </div>
              <div :if={@cron_preset == "custom"}>
                <label class="block text-xs font-medium text-gray-400 mb-1">
                  Custom Cron Expression
                </label>
                <.input
                  name="cron_custom"
                  value={@cron_custom}
                  placeholder="*/5 * * * *"
                  required
                  class="font-mono"
                />
                <p class="mt-1 text-xs text-gray-500">
                  Format: minute hour day-of-month month day-of-week
                </p>
              </div>
              <div>
                <label class="block text-xs font-medium text-gray-400 mb-1">Runs</label>
                <select
                  name="target"
                  phx-change="target_change"
                  data-test="schedule-target"
                  class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                >
                  <option value="component" selected={@form[:target].value != "aqua"}>
                    A component
                  </option>
                  <option value="aqua" selected={@form[:target].value == "aqua"}>
                    A line for Aqua
                  </option>
                </select>
              </div>
              <div :if={@form[:target].value == "aqua"} class="md:col-span-2">
                <label class="block text-xs font-medium text-gray-400 mb-1">Line for Aqua</label>
                <textarea
                  name="line"
                  required
                  rows="3"
                  data-test="schedule-line"
                  placeholder="Summarise what is unread"
                  class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                >{@form[:line].value}</textarea>
                <p class="mt-1 text-xs text-gray-500">
                  Each time it runs, Aqua is sent this line in your daily thread, under the schedule's name. It can use every tool it is offered; what needs you signed in, such as writing a scroll, it cannot do. Nothing is asked of you.
                </p>
              </div>
              <div :if={@form[:target].value != "aqua"}>
                <label class="block text-xs font-medium text-gray-400 mb-1">Component</label>
                <%= if @components != [] do %>
                  <select
                    name="reference"
                    required
                    class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                  >
                    <option value="" disabled selected={@form[:reference].value == ""}>
                      Select a component...
                    </option>
                    <%= for ref <- component_options(@components, @form[:reference].value) do %>
                      <option value={ref} selected={@form[:reference].value == ref}>{ref}</option>
                    <% end %>
                  </select>
                <% else %>
                  <.input
                    name="reference"
                    value={@form[:reference].value}
                    placeholder="catalyst:local.component:1.0.0"
                    required
                    class="font-mono"
                  />
                  <p class="mt-1 text-xs text-gray-500">
                    No registered components found. Enter a reference manually.
                  </p>
                <% end %>
              </div>
              <div :if={@form[:target].value != "aqua"}>
                <label class="block text-xs font-medium text-gray-400 mb-1">Profile</label>
                <.input
                  name="profile_id"
                  value={@form[:profile_id].value}
                  required
                  placeholder="profile id"
                />
                <p class="mt-1 text-xs text-gray-500">
                  Enter a consented profile for this component. Its consent authorizes each run.
                </p>
              </div>
              <div :if={@form[:target].value != "aqua"}>
                <label class="block text-xs font-medium text-gray-400 mb-1">
                  Input (JSON, optional)
                </label>
                <.input
                  name="input"
                  value={@form[:input].value}
                  placeholder='{"key":"value"}'
                  class="font-mono"
                />
              </div>
              <div>
                <label class="block text-xs font-medium text-gray-400 mb-1">Missed runs</label>
                <div class="flex gap-2">
                  <select
                    name="missed_runs"
                    class="rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                  >
                    <option value="skip" selected={@form[:missed_runs].value != "catch_up"}>
                      Skip
                    </option>
                    <option value="catch_up" selected={@form[:missed_runs].value == "catch_up"}>
                      Catch up
                    </option>
                  </select>
                  <.input
                    name="catch_up_limit"
                    type="number"
                    value={@form[:catch_up_limit].value}
                    placeholder="how many"
                  />
                </div>
                <p class="mt-1 text-xs text-gray-500">
                  What becomes of runs the server missed while it was down: skip them, or catch up on up to this many, oldest first.
                </p>
              </div>
            </div>
            <p
              :if={@form_error}
              role="alert"
              data-test="schedule-form-error"
              class="text-sm text-red-400"
            >
              {@form_error}
            </p>
            <div class="flex justify-end gap-2">
              <.button variant="ghost" type="button" phx-click="toggle_create">Cancel</.button>
              <.button variant="primary" type="submit">
                {if @editing, do: "Save", else: "Create Schedule"}
              </.button>
            </div>
          </.form>
        </.card>
      </div>

      <.card>
        <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>
        <div :if={!@loading && @schedules == []} class="py-8">
          <.empty_state message="No schedules found" />
        </div>
        <div :if={!@loading && @schedules != []} class="overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-800 table-fixed">
            <thead>
              <tr>
                <th class="w-[13%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Name
                </th>
                <th class="w-[15%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Reference
                </th>
                <th class="w-[12%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Schedule
                </th>
                <th class="w-[16%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Missed Runs
                </th>
                <th class="w-[8%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Status
                </th>
                <th class="w-[10%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Next Run
                </th>
                <th class="w-[10%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Last Run
                </th>
                <th class="w-[6%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                  Runs
                </th>
                <th class="w-[10%] px-4 py-3 text-right text-xs font-medium uppercase tracking-wider text-gray-500">
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-800">
              <%= for sched <- @schedules do %>
                <tr class={[
                  if(f(sched, :schedule_id) == @focused_id,
                    do: "bg-gray-800/80",
                    else: "hover:bg-gray-800/50"
                  )
                ]}>
                  <td class="px-4 py-3 text-sm text-white font-medium truncate">
                    {f(sched, :name)}
                    <span
                      class="block text-xs font-normal text-gray-500 truncate"
                      data-test="schedule-maker"
                    >
                      {maker_label(sched)}
                    </span>
                    <span
                      :if={room_label(sched, @rooms)}
                      class="block text-xs font-normal text-gray-500 truncate"
                      title={room_label(sched, @rooms)}
                      data-test="schedule-room"
                    >
                      {room_label(sched, @rooms)}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300 truncate max-w-0">
                    <span
                      :if={f(sched, :reference) == @aqua_line}
                      class="text-xs text-blue-400"
                      title={line_of(sched)}
                    >
                      Aqua: {line_of(sched)}
                    </span>
                    <span
                      :if={f(sched, :reference) != @aqua_line}
                      class="font-mono text-xs text-blue-400"
                    >
                      {f(sched, :reference)}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm whitespace-nowrap">
                    <span class="text-gray-300" title={f(sched, :cron_expression)}>
                      {if f(sched, :once), do: "Once", else: cron_label(f(sched, :cron_expression))}
                    </span>
                    <span class="block text-xs text-gray-500 font-mono">
                      {f(sched, :cron_expression)}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm">
                    <form
                      id={"missed-#{f(sched, :schedule_id)}"}
                      phx-submit="missed_runs"
                      class="flex items-center gap-1"
                    >
                      <input type="hidden" name="schedule_id" value={f(sched, :schedule_id)} />
                      <select
                        name="missed_runs"
                        class="rounded bg-gray-800 border border-gray-700 px-2 py-1 text-xs text-white"
                      >
                        <option value="skip" selected={f(sched, :missed_runs) != "catch_up"}>
                          Skip
                        </option>
                        <option value="catch_up" selected={f(sched, :missed_runs) == "catch_up"}>
                          Catch up
                        </option>
                      </select>
                      <input
                        name="catch_up_limit"
                        type="number"
                        min="1"
                        value={f(sched, :catch_up_limit)}
                        class="w-14 rounded bg-gray-800 border border-gray-700 px-2 py-1 text-xs text-white"
                      />
                      <.button variant="ghost" type="submit" class="text-xs px-2 py-1">Save</.button>
                    </form>
                  </td>
                  <td class="px-4 py-3 text-sm whitespace-nowrap">
                    <.badge color={status_badge_color(f(sched, :status))}>
                      {f(sched, :status)}
                    </.badge>
                  </td>
                  <td class="px-4 py-3 text-sm whitespace-nowrap">
                    <span class="text-xs text-gray-400" title={f(sched, :next_run_at)}>
                      {relative_time(f(sched, :next_run_at))}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm whitespace-nowrap">
                    <span class="text-xs text-gray-400" title={f(sched, :last_run_at)}>
                      {relative_time(f(sched, :last_run_at))}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300">
                    <span>{f(sched, :run_count) || 0}</span>
                    <span :if={(f(sched, :error_count) || 0) > 0} class="text-red-400 ml-1">
                      ({f(sched, :error_count)} err)
                    </span>
                    <p :if={f(sched, :last_error)} class="mt-1 text-xs text-red-400 break-words">
                      {f(sched, :last_error)}
                      <.link
                        :if={f(sched, :last_execution_id)}
                        navigate={
                          PrismWeb.Focus.path(
                            @athanor_route,
                            "/executions?id=" <> f(sched, :last_execution_id)
                          )
                        }
                        class="ml-1 underline text-red-300 hover:text-red-200"
                      >
                        Open the run
                      </.link>
                    </p>
                  </td>
                  <td class="px-4 py-3 text-sm text-right">
                    <div class="flex items-center justify-end gap-1">
                      <.button
                        variant="ghost"
                        class="text-xs px-2 py-1"
                        phx-click="edit"
                        phx-value-id={f(sched, :schedule_id)}
                        data-test="schedule-edit"
                      >
                        Edit
                      </.button>
                      <.button
                        :if={f(sched, :status) == "active"}
                        variant="ghost"
                        class="text-xs px-2 py-1"
                        phx-click="pause"
                        phx-value-id={f(sched, :schedule_id)}
                      >
                        Pause
                      </.button>
                      <.button
                        :if={f(sched, :status) == "paused"}
                        variant="ghost"
                        class="text-xs px-2 py-1"
                        phx-click="resume"
                        phx-value-id={f(sched, :schedule_id)}
                      >
                        Resume
                      </.button>
                      <.button
                        variant="danger"
                        class="text-xs px-2 py-1"
                        phx-click="delete"
                        phx-value-id={f(sched, :schedule_id)}
                        data-confirm="Delete this schedule?"
                      >
                        Delete
                      </.button>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        <div :if={!@loading && @more?} class="pt-4 text-center">
          <.button variant="ghost" phx-click="show_more" data-test="schedules-more">
            Show more schedules
          </.button>
        </div>
      </.card>

      <section id="feeds" class="space-y-3">
        <h2 class="text-sm font-semibold uppercase tracking-wider text-gray-400">Feeds</h2>
        <.card>
          <div :if={!@loading && @feeds == []} class="py-8">
            <.empty_state message="No feeds" />
          </div>
          <div :if={@feeds != []} class="overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-800 table-fixed">
              <thead>
                <tr>
                  <th class="w-[14%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                    Name
                  </th>
                  <th class="w-[18%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                    Binding
                  </th>
                  <th class="w-[18%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                    Component
                  </th>
                  <th class="w-[10%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                    Operation
                  </th>
                  <th class="w-[10%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                    Interval
                  </th>
                  <th class="w-[10%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                    Last Result
                  </th>
                  <th class="w-[12%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                    Actions
                  </th>
                  <th class="w-[8%] px-4 py-3 text-right text-xs font-medium uppercase tracking-wider text-gray-500">
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-800">
                <%= for feed <- @feeds do %>
                  <tr id={"feed-#{f(feed, :binding)}"} class="hover:bg-gray-800/50">
                    <td class="px-4 py-3 text-sm text-white font-medium truncate">
                      <span title={f(feed, :label)}>{f(feed, :feed)}</span>
                    </td>
                    <td class="px-4 py-3 text-sm truncate max-w-0">
                      <span class="font-mono text-xs text-gray-400">{f(feed, :binding)}</span>
                    </td>
                    <td class="px-4 py-3 text-sm truncate max-w-0">
                      <span class="font-mono text-xs text-blue-400">{f(feed, :reference)}</span>
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-300 truncate">{f(feed, :operation)}</td>
                    <td class="px-4 py-3 text-sm text-gray-300 whitespace-nowrap">
                      {interval_label(f(feed, :interval_minutes))}
                    </td>
                    <td class="px-4 py-3 text-sm whitespace-nowrap">
                      <span class="text-xs text-gray-400" title={f(feed, :at)}>
                        {relative_time(f(feed, :at))}
                      </span>
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-300 truncate">
                      {action_labels(f(feed, :actions))}
                    </td>
                    <td class="px-4 py-3 text-sm text-right">
                      <.button
                        variant="danger"
                        class="text-xs px-2 py-1"
                        phx-click="remove_feed"
                        phx-value-id={f(feed, :binding)}
                        data-confirm="Remove this feed?"
                      >
                        Remove
                      </.button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </.card>
      </section>
      <.live_component module={SystemLayer} id={SystemLayer.layer_id()} context={@context} />
    </div>
    """
  end
end
