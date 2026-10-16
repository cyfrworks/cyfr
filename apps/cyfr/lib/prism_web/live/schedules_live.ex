# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SchedulesLive do
  @moduledoc """
  Cron schedules: list, create, pause, resume and delete through the
  `schedule` tool.

  A schedule runs its component under the profile it names, and a run a
  schedule starts carries the `schedule` origin. Making one for a profile
  whose grant does not admit that origin raises the grant prompt for that
  profile first, in the page's system layer (`PrismWeb.SystemLayer`):
  once the grant is confirmed the page reads the profile's grant again
  and makes the schedule only if it now admits schedules. A grant
  dismissed, or confirmed without that origin, makes no schedule.

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

  @empty_form %{
    "name" => "",
    "reference" => "",
    "profile_id" => "",
    "input" => "",
    "missed_runs" => "skip",
    "catch_up_limit" => ""
  }

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
      |> assign(:feeds, [])
      |> assign(:components, [])
      |> assign(:loading, true)
      |> assign(:show_create, false)
      |> assign(:cron_preset, "")
      |> assign(:cron_custom, "")
      |> assign(:form, to_form(@empty_form))
      |> assign(:focused_id, nil)
      |> assign(:origin_grant, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_create", _params, socket) do
    show = !socket.assigns.show_create

    socket =
      if show do
        socket |> fetch_components()
      else
        socket
      end

    {:noreply, assign(socket, :show_create, show)}
  end

  def handle_event("cron_preset_change", %{"cron_preset" => preset}, socket) do
    {:noreply, assign(socket, :cron_preset, preset)}
  end

  def handle_event("create", %{"name" => name, "reference" => ref} = params, socket) do
    cron =
      case socket.assigns.cron_preset do
        "custom" -> params["cron_custom"] || ""
        "" -> ""
        preset -> preset
      end

    socket =
      socket
      |> assign(:form, to_form(Map.merge(@empty_form, Map.take(params, Map.keys(@empty_form)))))
      |> assign(:cron_custom, params["cron_custom"] || socket.assigns.cron_custom)

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

      {:noreply, create_admitted(socket, args)}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{error_message(reason)}")}
    end
  end

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

  # The grant prompt a schedule waited for. A refused commit leaves the
  # prompt open for the person to try again or dismiss; any other end
  # makes no schedule.
  @impl PrismWeb.SystemLayer.Hook
  def system_layer_report(id, outcome, %{assigns: %{origin_grant: {id, args}}} = socket) do
    case outcome do
      :confirmed ->
        {:noreply, socket |> assign(:origin_grant, nil) |> origin_granted(args)}

      {:refused, reason} when reason != :invalid_prompt ->
        {:noreply, socket}

      _ended ->
        {:noreply,
         socket
         |> assign(:origin_grant, nil)
         |> put_flash(:error, "No schedule was made: the grant was not changed.")}
    end
  end

  def system_layer_report(_id, _outcome, _socket), do: :pass

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

  # A schedule is made only under a grant that admits its runs: one whose
  # profile's grant lacks the `schedule` origin raises the grant prompt
  # for that profile first, and the schedule waits for its outcome.
  defp create_admitted(socket, %{"reference" => ref, "profile_id" => profile_id} = args) do
    case SystemLayer.admits_origin(socket, ref, profile_id, :schedule) do
      {:missing, label} -> ask_origin(socket, args, label)
      _admitted_or_unknown -> create_schedule(socket, args)
    end
  end

  defp ask_origin(socket, %{"reference" => ref} = args, label) do
    id = "grant-schedule-#{System.unique_integer([:positive])}"

    case SystemLayer.grant_prompt(socket, id, ref, label: label) do
      {:ok, prompt} ->
        SystemLayer.show(prompt)

        socket
        |> assign(:origin_grant, {id, args})
        |> put_flash(
          :info,
          "This profile's grant does not let it run on a schedule. " <>
            "Grant it \"Also on a schedule\" to make this schedule."
        )

      {:error, reason} ->
        put_flash(socket, :error, "No schedule was made: #{error_message(reason)}")
    end
  end

  defp create_schedule(socket, args) do
    case call_tool(socket, "schedule", args) do
      {:ok, _} ->
        socket
        |> assign(:show_create, false)
        |> assign(:cron_preset, "")
        |> assign(:cron_custom, "")
        |> assign(:form, to_form(@empty_form))
        |> fetch_schedules()
        |> put_flash(:info, "Schedule created")

      {:error, reason} ->
        put_flash(socket, :error, "Failed: #{error_message(reason)}")
    end
  end

  # The grant the schedule waited for, confirmed: its profile's grant is
  # read again, and the schedule made only if it now admits schedules.
  defp origin_granted(socket, %{"reference" => ref, "profile_id" => profile_id} = args) do
    case SystemLayer.admits_origin(socket, ref, profile_id, :schedule) do
      {:missing, _label} ->
        put_flash(
          socket,
          :error,
          "No schedule was made: the grant does not let this profile run on a schedule."
        )

      _admitted_or_unknown ->
        create_schedule(socket, args)
    end
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

  defp fetch_schedules(socket) do
    schedules =
      case call_tool(socket, "schedule", %{"action" => "list"}) do
        {:ok, %{schedules: list}} ->
          list

        {:ok, list} when is_list(list) ->
          list

        other ->
          Logger.warning("[SchedulesLive] schedule list failed: #{inspect(other)}")
          []
      end

    assign(socket, :schedules, schedules)
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

        {:ok, %{"components" => list}} ->
          list

        {:ok, list} when is_list(list) ->
          list

        other ->
          Logger.warning("[SchedulesLive] component list failed: #{inspect(other)}")
          []
      end

    refs =
      Enum.map(all, fn c ->
        c[:component_ref] || c[:id]
      end)
      |> Enum.reject(&is_nil/1)

    assign(socket, :components, refs)
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
    assigns = assign(assigns, :cron_presets, @cron_presets)

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
          <.form for={@form} phx-submit="create" class="space-y-4 p-4">
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
                    <%= for ref <- @components do %>
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
              <div>
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
              <div>
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
            <div class="flex justify-end gap-2">
              <.button variant="ghost" type="button" phx-click="toggle_create">Cancel</.button>
              <.button variant="primary" type="submit">Create Schedule</.button>
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
                  if(f(sched, :id) == @focused_id,
                    do: "bg-gray-800/80",
                    else: "hover:bg-gray-800/50"
                  )
                ]}>
                  <td class="px-4 py-3 text-sm text-white font-medium truncate">{f(sched, :name)}</td>
                  <td class="px-4 py-3 text-sm text-gray-300 truncate max-w-0">
                    <span class="font-mono text-xs text-blue-400">{f(sched, :reference)}</span>
                  </td>
                  <td class="px-4 py-3 text-sm whitespace-nowrap">
                    <span class="text-gray-300" title={f(sched, :cron_expression)}>
                      {cron_label(f(sched, :cron_expression))}
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
                  </td>
                  <td class="px-4 py-3 text-sm text-right">
                    <div class="flex items-center justify-end gap-1">
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
