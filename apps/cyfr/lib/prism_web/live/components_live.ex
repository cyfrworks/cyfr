# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ComponentsLive do
  use PrismWeb, :live_view
  require Logger

  alias PrismWeb.ComponentsLive.Editor

  # The one spelling of the local namespace. Exact equality on purpose: a
  # nil publisher is a display question, not `local_publisher?/1`'s
  # nil-collapses-to-local policy question.
  @local_publisher Compendium.ComponentPath.default_publisher()

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Prism.Topics.components(ctx))
    end

    socket =
      socket
      |> assign(:page_title, "Components")
      |> assign(:active_nav, "components")
      # In HEEx `@local_publisher` reads THIS assign — the same-named
      # module attribute is invisible there, and expanding a row crashed
      # on the missing key until this was assigned.
      |> assign(:local_publisher, @local_publisher)
      |> assign(:components, [])
      |> assign(:grouped, %{})
      |> assign(:type_filter, nil)
      |> assign(:loading, true)
      |> assign(:expanded_ref, nil)
      |> assign(:expanded_detail, nil)
      |> assign(:expanded_plan, nil)
      |> assign(:consent_sheet_ref, nil)
      |> assign(:pushing, false)
      |> assign(:setup_readiness, %{})
      |> assign(:component_groups, [])
      |> assign(:expanded_versions, [])
      |> assign(:search_query, "")
      |> assign(:search_results, nil)
      |> assign(:search_searching, false)
      |> assign(:search_note, nil)
      |> assign(:search_expanded, nil)
      |> assign(:pulling, MapSet.new())
      |> assign(:pull_results, %{})
      |> assign(:registering, false)
      |> assign(:register_log, [])
      |> assign(:register_id, nil)
      |> assign(:progress_log, [])
      |> assign(:progress_id, nil)

    {:ok, socket}
  end

  # --- Registry search events ---

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply,
       socket
       |> assign(:search_query, "")
       |> assign(:search_results, nil)
       |> assign(:search_note, nil)}
    else
      send(self(), {:do_search, query})

      {:noreply,
       socket
       |> assign(:search_query, query)
       |> assign(:search_searching, true)
       |> assign(:search_note, nil)}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:search_results, nil)
     |> assign(:search_note, nil)
     |> assign(:search_expanded, nil)
     |> assign(:pull_results, %{})}
  end

  def handle_event("toggle_search_expand", %{"name" => name}, socket) do
    current = socket.assigns.search_expanded

    {:noreply, assign(socket, :search_expanded, if(current == name, do: nil, else: name))}
  end

  def handle_event("pull", %{"ref" => ref}, socket) do
    progress_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    Phoenix.PubSub.subscribe(
      Emissary.PubSub,
      Prism.Topics.progress(progress_id, socket.assigns[:context])
    )

    socket =
      socket
      |> assign(:pulling, MapSet.put(socket.assigns.pulling, ref))
      |> assign(:progress_id, progress_id)
      |> assign(:progress_log, [])

    lv = self()
    ctx = socket.assigns.context

    case Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
           result =
             try do
               {name, merged_args} =
                 {"component",
                  %{"action" => "pull", "reference" => ref, "progress_id" => progress_id}}

               Emissary.MCP.ToolRegistry.call_external(name, ctx, merged_args)
             rescue
               e -> {:error, Exception.message(e)}
             end

           send(lv, {:pull_complete, ref, result})
         end) do
      {:ok, _pid} ->
        Process.send_after(self(), {:task_timeout, :pull}, 120_000)
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to start pull task: #{inspect(reason)}")
        {:noreply, socket |> assign(:pulling, false) |> put_flash(:error, "Failed to start pull")}
    end
  end

  # --- Installed component events ---

  def handle_event("filter_type", %{"type" => type}, socket) do
    type = if type == "", do: nil, else: type

    {:noreply,
     socket
     |> assign(:type_filter, type)
     |> fetch_components()}
  end

  def handle_event("register", _params, socket) do
    register_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    Phoenix.PubSub.subscribe(
      Emissary.PubSub,
      Prism.Topics.register(register_id, socket.assigns[:context])
    )

    socket =
      socket
      |> assign(:registering, true)
      |> assign(:register_id, register_id)
      |> assign(:register_log, [])

    lv = self()

    case Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
           result =
             call_tool(socket, "component", %{
               "action" => "register",
               "register_id" => register_id
             })

           send(lv, {:register_complete, result})
         end) do
      {:ok, _pid} ->
        Process.send_after(self(), {:task_timeout, :register}, 120_000)
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to start register task: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:registering, false)
         |> put_flash(:error, "Failed to start registration")}
    end
  end

  def handle_event("toggle_expand", %{"ref" => name_ref}, socket) do
    if socket.assigns.expanded_ref == name_ref do
      {:noreply, collapse(socket)}
    else
      group =
        Enum.find(socket.assigns.component_groups, fn g -> g.name_ref == name_ref end)

      if group do
        latest_ref = comp_ref(group.latest)

        detail =
          case call_tool(socket, "component/inspect", %{"reference" => latest_ref}) do
            {:ok, result} ->
              result

            other ->
              Logger.warning("[ComponentsLive] component/inspect failed: #{inspect(other)}")
              nil
          end

        plan =
          case call_tool(socket, "component", %{
                 "action" => "setup_plan",
                 "reference" => latest_ref
               }) do
            {:ok, result} ->
              result

            other ->
              Logger.warning("[ComponentsLive] setup_plan failed: #{inspect(other)}")
              nil
          end

        {:noreply,
         socket
         |> assign(:expanded_ref, name_ref)
         |> assign(:expanded_detail, detail)
         |> assign(:expanded_plan, plan)
         |> assign(:expanded_versions, group.versions)
         |> assign(:pushing, false)
         |> assign(:progress_log, [])
         |> assign(:progress_id, nil)}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_event("open_consent", %{"ref" => _ref}, socket) do
    # The consent sheet plans against the latest versioned ref; the walk
    # itself decides what the grant covers.
    {:noreply, assign(socket, :consent_sheet_ref, latest_versioned_ref(socket))}
  end

  def handle_event("push", %{"ref" => ref}, socket) do
    progress_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    Phoenix.PubSub.subscribe(
      Emissary.PubSub,
      Prism.Topics.progress(progress_id, socket.assigns[:context])
    )

    socket =
      socket
      |> assign(:pushing, ref)
      |> assign(:progress_id, progress_id)
      |> assign(:progress_log, [])

    lv = self()
    ctx = socket.assigns.context

    case Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
           result =
             try do
               Emissary.MCP.ToolRegistry.call_external("component", ctx, %{
                 "action" => "push",
                 "reference" => ref,
                 "progress_id" => progress_id
               })
             rescue
               e -> {:error, Exception.message(e)}
             end

           send(lv, {:push_complete, ref, result})
         end) do
      {:ok, _pid} ->
        Process.send_after(self(), {:task_timeout, :push}, 120_000)
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to start push task: #{inspect(reason)}")

        {:noreply, socket |> assign(:pushing, false) |> put_flash(:error, "Failed to start push")}
    end
  end

  def handle_event("remove", %{"ref" => ref}, socket) do
    case call_tool(socket, "component", %{"action" => "delete", "reference" => ref}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> collapse()
         |> fetch_components()
         |> put_flash(:info, "Deleted #{ref}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to remove: " <> error_message(reason))}
    end
  end

  def handle_event("reset", %{"ref" => ref}, socket) do
    case call_tool(socket, "component", %{"action" => "reset", "reference" => ref}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> collapse()
         |> fetch_components()
         |> put_flash(:info, "Reset #{ref} to the shipped version")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to reset: " <> error_message(reason))}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      socket = socket |> fetch_components() |> assign(:loading, false)

      socket =
        case params do
          %{"ref" => ref, "setup" => "true"} ->
            tap(socket, fn _ -> send(self(), {:deep_link_setup, ref}) end)

          _ ->
            socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # --- PubSub handlers ---

  @impl true
  def handle_info({:consent_granted, _ref, _result}, socket) do
    {:noreply,
     socket
     |> assign(:consent_sheet_ref, nil)
     |> refresh_expanded_plan()}
  end

  def handle_info({:consent_sheet_closed, _ref}, socket) do
    {:noreply, assign(socket, :consent_sheet_ref, nil)}
  end

  def handle_info(:components_changed, socket) do
    {:noreply, fetch_components(socket)}
  end

  def handle_info({:register_progress, %{phase: phase, message: message}}, socket) do
    entry = %{phase: phase, message: message, at: DateTime.utc_now()}
    {:noreply, assign(socket, :register_log, socket.assigns.register_log ++ [entry])}
  end

  def handle_info({:register_complete, {:ok, result}}, socket) do
    if socket.assigns.register_id do
      Phoenix.PubSub.unsubscribe(
        Emissary.PubSub,
        Prism.Topics.register(socket.assigns.register_id, socket.assigns[:context])
      )
    end

    total = result[:total] || result["total"] || 0
    registered = result[:registered] || result["registered"] || 0

    {:noreply,
     socket
     |> assign(:registering, false)
     |> assign(:register_id, nil)
     |> assign(:register_log, [])
     |> fetch_components()
     |> put_flash(:info, "Registered #{registered}/#{total} components")}
  end

  def handle_info({:register_complete, {:error, reason}}, socket) do
    if socket.assigns.register_id do
      Phoenix.PubSub.unsubscribe(
        Emissary.PubSub,
        Prism.Topics.register(socket.assigns.register_id, socket.assigns[:context])
      )
    end

    {:noreply,
     socket
     |> assign(:registering, false)
     |> assign(:register_id, nil)
     |> assign(:register_log, [])
     |> put_flash(:error, "Register failed: #{inspect(reason)}")}
  end

  def handle_info({:do_search, query}, socket) do
    {:noreply, do_registry_search(socket, query)}
  end

  def handle_info({:progress, %{phase: phase, message: message}}, socket) do
    entry = %{phase: phase, message: message, at: DateTime.utc_now()}
    {:noreply, assign(socket, :progress_log, socket.assigns.progress_log ++ [entry])}
  end

  def handle_info({:pull_complete, ref, {:ok, result}}, socket) do
    unsubscribe_progress(socket)

    {:noreply,
     socket
     |> assign(:pulling, MapSet.delete(socket.assigns.pulling, ref))
     |> assign(:pull_results, Map.put(socket.assigns.pull_results, ref, {:ok, result}))
     |> assign(:progress_id, nil)
     |> assign(:progress_log, [])
     |> fetch_components()
     |> put_flash(:info, "Pulled #{ref}")}
  end

  def handle_info({:pull_complete, ref, {:error, reason}}, socket) do
    unsubscribe_progress(socket)

    {:noreply,
     socket
     |> assign(:pulling, MapSet.delete(socket.assigns.pulling, ref))
     |> assign(:pull_results, Map.put(socket.assigns.pull_results, ref, {:error, reason}))
     |> assign(:progress_id, nil)
     |> assign(:progress_log, [])
     |> put_flash(:error, "Failed to pull #{ref}: #{inspect(reason)}")}
  end

  def handle_info({:push_complete, _ref, {:ok, result}}, socket) do
    unsubscribe_progress(socket)
    oci_ref = comp_field(result, :oci_reference) || result[:oci_reference]

    complete_entry = %{
      phase: :complete,
      message: "Pushed → #{oci_ref}",
      at: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> assign(:pushing, false)
     |> assign(:progress_id, nil)
     |> assign(:progress_log, socket.assigns.progress_log ++ [complete_entry])
     |> put_flash(:info, "Pushed → #{oci_ref}")}
  end

  def handle_info({:push_complete, _ref, {:error, reason}}, socket) do
    unsubscribe_progress(socket)

    error_msg = Editor.format_push_error(reason)

    error_entry = %{
      phase: :error,
      message: error_msg,
      at: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> assign(:pushing, false)
     |> assign(:progress_id, nil)
     |> assign(:progress_log, socket.assigns.progress_log ++ [error_entry])
     |> put_flash(:error, error_msg)}
  end

  def handle_info({:task_timeout, :pull}, socket) do
    if socket.assigns.pulling != false and MapSet.size(socket.assigns.pulling) > 0 do
      Logger.warning("[ComponentsLive] Pull task timed out after 120s")
      {:noreply, socket |> assign(:pulling, MapSet.new()) |> put_flash(:error, "Pull timed out")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:task_timeout, :register}, socket) do
    if socket.assigns.registering do
      Logger.warning("[ComponentsLive] Register task timed out after 120s")

      {:noreply,
       socket
       |> assign(:registering, false)
       |> put_flash(:error, "Registration timed out")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:task_timeout, :push}, socket) do
    if socket.assigns.pushing do
      Logger.warning("[ComponentsLive] Push task timed out after 120s")

      {:noreply,
       socket
       |> assign(:pushing, false)
       |> assign(:progress_id, nil)
       |> assign(:progress_log, [])
       |> put_flash(:error, "Push timed out")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:deep_link_setup, ref}, socket) do
    # Find the component group matching the ref, auto-expand it, and open
    # the consent sheet so the operator can grant access straight away.
    socket = fetch_components(socket)
    groups = socket.assigns.component_groups

    # The ref may be a name-level ref (e.g., "catalyst:local.stripe") or versioned
    # Try to find a matching group by checking name_ref or latest ref
    group =
      Enum.find(groups, fn g ->
        g.name_ref == ref || comp_ref(g.latest) == ref ||
          String.starts_with?(comp_ref(g.latest), ref)
      end)

    if group do
      latest_ref = comp_ref(group.latest)

      detail =
        case call_tool(socket, "component/inspect", %{"reference" => latest_ref}) do
          {:ok, result} -> result
          _ -> nil
        end

      plan =
        case call_tool(socket, "component", %{
               "action" => "setup_plan",
               "reference" => latest_ref
             }) do
          {:ok, result} -> result
          _ -> nil
        end

      {:noreply,
       socket
       |> assign(:expanded_ref, group.name_ref)
       |> assign(:expanded_detail, detail)
       |> assign(:expanded_plan, plan)
       |> assign(:expanded_versions, group.versions)
       |> assign(:consent_sheet_ref, latest_ref)
       |> assign(:loading, false)}
    else
      {:noreply,
       socket
       |> assign(:loading, false)
       |> put_flash(:warning, "Component #{ref} not found")}
    end
  end

  def handle_info({:readiness_loaded, readiness}, socket) do
    {:noreply, assign(socket, :setup_readiness, readiness)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[ComponentsLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # --- Private helpers ---

  defp register_phase_color(:scanning), do: "bg-yellow-400"
  defp register_phase_color(:registered), do: "bg-blue-400"
  defp register_phase_color(:unchanged), do: "bg-gray-500"
  defp register_phase_color(:pruning), do: "bg-yellow-400"
  defp register_phase_color(:checking_deps), do: "bg-cyan-400"
  defp register_phase_color(:pulling), do: "bg-orange-400"
  defp register_phase_color(:pulled), do: "bg-green-400"
  defp register_phase_color(:pull_failed), do: "bg-red-400"
  defp register_phase_color(:complete), do: "bg-green-400"
  defp register_phase_color(:error), do: "bg-red-400"
  defp register_phase_color(_), do: "bg-gray-600"

  defp unsubscribe_progress(socket) do
    if socket.assigns.progress_id do
      Phoenix.PubSub.unsubscribe(
        Emissary.PubSub,
        Prism.Topics.progress(socket.assigns.progress_id, socket.assigns[:context])
      )
    end
  end

  defp collapse(socket) do
    socket
    |> assign(:expanded_ref, nil)
    |> assign(:expanded_detail, nil)
    |> assign(:expanded_plan, nil)
    |> assign(:expanded_versions, [])
    |> assign(:pushing, false)
    |> assign(:progress_log, [])
    |> assign(:progress_id, nil)
  end

  # Re-fetch the expanded component's setup plan after a grant so the
  # needs list and readiness badge reflect the new consent.
  defp refresh_expanded_plan(socket) do
    expanded_ref = socket.assigns.expanded_ref

    if expanded_ref do
      versioned_ref = latest_versioned_ref(socket)

      plan =
        case call_tool(socket, "component", %{
               "action" => "setup_plan",
               "reference" => versioned_ref
             }) do
          {:ok, result} ->
            result

          other ->
            Logger.warning(
              "[ComponentsLive] setup_plan refresh after grant failed: #{inspect(other)}"
            )

            socket.assigns.expanded_plan
        end

      readiness =
        Map.put(socket.assigns.setup_readiness, expanded_ref, plan_field(plan, :ready) == true)

      socket
      |> assign(:expanded_plan, plan)
      |> assign(:setup_readiness, readiness)
    else
      socket
    end
  end

  defp do_registry_search(socket, query) do
    args = %{"action" => "search", "query" => query, "limit" => 30}

    case call_tool(socket, "component", args) do
      {:ok, result} ->
        components = result[:components] || result["components"] || []
        note = result[:note] || result["note"]
        grouped = group_search_results(components)

        socket
        |> assign(:search_results, grouped)
        |> assign(:search_note, note)
        |> assign(:search_searching, false)

      _ ->
        socket
        |> assign(:search_results, [])
        |> assign(:search_searching, false)
    end
  end

  # Group search results by component name (all versions under one entry).
  # Uses remote_versions from the merged search to show all available versions,
  # even though the search response only includes the latest per component.
  defp group_search_results(components) do
    components
    |> Enum.group_by(fn comp ->
      name = comp_field(comp, :name)
      publisher = comp_field(comp, :publisher) || comp_field(comp, :namespace_slug)
      type = comp_field(comp, :component_type)
      {name, publisher, type}
    end)
    |> Enum.map(fn {{name, publisher, type}, local_versions} ->
      sorted =
        Enum.sort_by(
          local_versions,
          fn v -> comp_field(v, :version) || "0.0.0" end,
          &(Compendium.Semver.compare(&1, &2) != :lt)
        )

      latest = hd(sorted)

      # Merge remote_versions into the list (remote versions not already local)
      remote_vs = comp_field(latest, :remote_versions) || []
      local_vs = MapSet.new(sorted, fn v -> comp_field(v, :version) end)

      remote_only =
        remote_vs
        |> Enum.reject(fn v -> MapSet.member?(local_vs, v) end)
        |> Enum.map(fn v ->
          ref = Editor.build_ref_from_parts(type, publisher, name, v)
          %{version: v, component_ref: ref, remote_only: true}
        end)

      all_versions =
        (sorted ++ remote_only)
        |> Enum.sort_by(
          fn v -> comp_field(v, :version) || "0.0.0" end,
          &(Compendium.Semver.compare(&1, &2) != :lt)
        )

      %{
        name: name,
        publisher: Compendium.ComponentPath.normalize_publisher(publisher),
        component_type: type,
        description: comp_field(latest, :description),
        latest: latest,
        versions: all_versions,
        version_count: length(all_versions),
        # Latest version's status (active|deprecated|yanked|taken_down).
        # Older rows + local-only entries may omit it; default to "active".
        # Callers render a status badge when != "active".
        status: comp_field(latest, :status) || "active",
        status_reason: comp_field(latest, :status_reason)
      }
    end)
    |> Enum.sort_by(fn g -> g.name end)
  end

  # Small inline badge next to the publisher cell for deprecated / yanked /
  # taken_down versions. Returns `nil` for active (no badge rendered). Colors
  # chosen to match existing "Installed" / "Update" badges.
  defp component_status_badge_class("deprecated"),
    do: "bg-amber-900 text-amber-300"

  defp component_status_badge_class("yanked"),
    do: "bg-red-900 text-red-300"

  defp component_status_badge_class("taken_down"),
    do: "bg-red-950 text-red-400 border border-red-700"

  defp component_status_badge_class(_), do: nil

  defp component_status_badge_label("deprecated"), do: "Deprecated"
  defp component_status_badge_label("yanked"), do: "Yanked"
  defp component_status_badge_label("taken_down"), do: "Taken Down"
  defp component_status_badge_label(_), do: nil

  defp progress_phase_color(:pulling), do: "bg-orange-400"
  defp progress_phase_color(:pushing), do: "bg-blue-400"
  defp progress_phase_color(:complete), do: "bg-green-400"
  defp progress_phase_color(:error), do: "bg-red-400"
  defp progress_phase_color(_), do: "bg-gray-600"

  defp fetch_components(socket) do
    assigns = socket.assigns
    args = %{"action" => "list", "limit" => 1000}
    args = if assigns.type_filter, do: Map.put(args, "type", assigns.type_filter), else: args

    all_components =
      case call_tool(socket, "component", args) do
        {:ok, %{components: list}} ->
          list

        {:ok, %{"components" => list}} ->
          list

        {:ok, list} when is_list(list) ->
          list

        other ->
          Logger.warning("[ComponentsLive] component list failed: #{inspect(other)}")
          []
      end

    # Group versions under name-level refs
    groups = group_by_component(all_components)

    socket
    |> assign(:all_components, all_components)
    |> assign(:component_groups, groups)
    |> assign(:setup_readiness, %{})
    |> collapse()
    |> apply_filter()
    |> load_readiness_async(groups)
  end

  defp load_readiness_async(socket, groups) do
    lv = self()
    ctx = socket.assigns.context

    Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
      readiness =
        Enum.reduce(groups, %{}, fn group, acc ->
          ref = comp_ref(group.latest)

          result =
            try do
              Emissary.MCP.ToolRegistry.call_external("component", ctx, %{
                "action" => "setup_plan",
                "reference" => ref
              })
            rescue
              e ->
                Logger.warning(
                  "[ComponentsLive] setup_plan crashed for #{ref}: #{Exception.message(e)}"
                )

                {:error, :crashed}
            catch
              :exit, reason ->
                Logger.warning(
                  "[ComponentsLive] setup_plan exited for #{ref}: #{inspect(reason)}"
                )

                {:error, :exit}
            end

          case result do
            {:ok, plan} ->
              ready = (plan[:ready] || plan["ready"]) == true
              Map.put(acc, group.name_ref, ready)

            _ ->
              acc
          end
        end)

      send(lv, {:readiness_loaded, readiness})
    end)

    socket
  end

  defp apply_filter(socket) do
    groups = socket.assigns[:component_groups] || []

    grouped =
      groups
      |> Enum.group_by(fn g -> g.component_type end)
      |> Enum.into(%{})

    socket
    |> assign(:components, groups)
    |> assign(:grouped, grouped)
  end

  defp group_by_component(components) do
    components
    |> Enum.group_by(fn c ->
      ref = comp_ref(c)

      case Sanctum.ComponentRef.to_name_ref(ref) do
        {:ok, nr} -> nr
        _ -> ref
      end
    end)
    |> Enum.map(fn {name_ref, versions} ->
      sorted =
        Enum.sort_by(
          versions,
          fn v -> comp_field(v, :version) || "0.0.0" end,
          &(Compendium.Semver.compare(&1, &2) != :lt)
        )

      latest = hd(sorted)

      %{
        name_ref: name_ref,
        latest: latest,
        versions: sorted,
        version_count: length(sorted),
        component_type: comp_field(latest, :component_type) || "unknown",
        description: comp_field(latest, :description)
      }
    end)
    |> Enum.sort_by(fn g -> g.name_ref end)
  end

  # --- Data helpers ---

  defp search_install_status(comp, installed_refs, installed_digests) do
    ref = build_search_ref(comp)

    cond do
      # Check live installed state (refreshed after each pull)
      MapSet.member?(installed_refs, ref) ->
        local_digest = Map.get(installed_digests, ref)
        remote_digest = comp_field(comp, :digest)

        if local_digest && remote_digest && local_digest != remote_digest do
          :update_available
        else
          :installed
        end

      # Server-provided update hint from merged search
      comp_field(comp, :update_available) == true ->
        :update_available

      true ->
        :not_installed
    end
  end

  defp build_search_ref(comp) do
    ref = comp[:component_ref] || comp["component_ref"]
    if ref, do: ref, else: build_ref_from_fields(comp)
  end

  defp build_ref_from_fields(comp) do
    type = comp_field(comp, :component_type)
    name = comp_field(comp, :name)
    publisher = comp_field(comp, :publisher) || comp_field(comp, :namespace_slug)
    version = comp_field(comp, :version)

    base =
      if publisher && publisher != @local_publisher,
        do: "#{publisher}.#{name}",
        else: name

    ref = if type, do: "#{type}:#{base}", else: base
    if version, do: "#{ref}:#{version}", else: ref
  end

  defp plan_field(nil, _key), do: nil
  defp plan_field(plan, key), do: plan[key] || plan[to_string(key)]

  # --- Display helpers ---

  defp type_label("catalyst"), do: "Catalysts"
  defp type_label("reagent"), do: "Reagents"
  defp type_label("formula"), do: "Formulas"
  defp type_label("tincture"), do: "Tinctures"
  defp type_label(type), do: String.capitalize(type)

  defp type_badge_color("catalyst"), do: "bg-purple-900 text-purple-300"
  defp type_badge_color("reagent"), do: "bg-blue-900 text-blue-300"
  defp type_badge_color("formula"), do: "bg-green-900 text-green-300"
  defp type_badge_color("tincture"), do: "bg-amber-900 text-amber-300"
  defp type_badge_color(_), do: "bg-gray-800 text-gray-400"

  defp comp_ref(c), do: c[:component_ref] || c["component_ref"] || c[:id] || c["id"] || "-"

  # Strip type prefix from a ref: "catalyst:local.claude" -> "local.claude"
  defp strip_type(ref) when is_binary(ref) do
    case String.split(ref, ":", parts: 2) do
      [_type, rest] ->
        # Remove version if present
        case String.split(rest, ":") do
          [name_part | _] -> name_part
          _ -> rest
        end

      _ ->
        ref
    end
  end

  # Extract publisher from a component or ref
  defp extract_publisher(comp) when is_map(comp) do
    Compendium.ComponentPath.normalize_publisher(
      comp_field(comp, :publisher) || comp_field(comp, :namespace_slug)
    )
  end

  # Extract just the name (no namespace) from a ref: "catalyst:moonmoon69.supabase" -> "supabase"
  defp extract_name(ref) when is_binary(ref) do
    stripped = strip_type(ref)

    case String.split(stripped, ".") do
      [_ns, name | _] -> name
      [name] -> name
      _ -> stripped
    end
  end

  defp extract_name(_), do: "-"

  # Get the latest version's versioned ref for API calls (setup_plan, etc.)
  defp latest_versioned_ref(socket) do
    case socket.assigns.expanded_versions do
      [latest | _] -> comp_ref(latest)
      _ -> socket.assigns.expanded_ref
    end
  end

  defp comp_field(c, key) when is_map(c), do: c[key] || c[to_string(key)]
  defp comp_field(_, _), do: nil

  # The version-row badge for a provenance label. "Yours" (user) is the
  # default state and carries no badge noise; an absent label (older wire
  # shape) shows nothing.
  defp provenance_badge("bundled"), do: {"bundled", "bg-gray-800 text-gray-400"}
  defp provenance_badge("bundled_modified"), do: {"modified", "bg-amber-900/50 text-amber-300"}
  defp provenance_badge("remote"), do: {"remote", "bg-sky-900/50 text-sky-300"}
  defp provenance_badge(_user_or_nil), do: nil

  # --- Render ---

  @impl true
  def render(assigns) do
    sorted_groups =
      assigns.grouped
      |> Enum.sort_by(fn {type, _} -> Editor.type_sort_order(type) end)

    all_comps = assigns[:all_components] || []

    inst_refs =
      all_comps
      |> Enum.map(&comp_ref/1)
      |> MapSet.new()

    inst_digests =
      Enum.reduce(all_comps, %{}, fn c, acc ->
        ref = comp_ref(c)
        digest = comp_field(c, :digest)
        if ref != "-", do: Map.put(acc, ref, digest), else: acc
      end)

    assigns =
      assigns
      |> assign(:sorted_groups, sorted_groups)
      |> assign(:installed_refs, inst_refs)
      |> assign(:installed_digests, inst_digests)

    ~H"""
    <div class="space-y-6">
      <!-- Registry Search -->
      <div>
        <div class="mb-3">
          <.page_header title="Search Registry" />
        </div>
        <form phx-submit="search" class="flex items-center gap-2">
          <.input
            name="query"
            value={@search_query}
            placeholder="Search for components... (e.g. claude, http, json)"
            class="flex-1"
          />
          <.button type="submit" variant="primary" disabled={@search_searching}>
            <span :if={!@search_searching}>Search</span>
            <span :if={@search_searching} class="inline-flex items-center gap-1.5">
              <svg
                class="animate-spin h-4 w-4"
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
              >
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="4"
                />
                <path
                  class="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                />
              </svg>
              Searching
            </span>
          </.button>
          <.button :if={@search_results != nil} type="button" variant="ghost" phx-click="clear_search">
            Clear
          </.button>
        </form>
      </div>
      
    <!-- Search Results -->
      <div :if={@search_searching} class="text-center text-gray-500 py-8">
        Searching registry...
      </div>

      <div :if={@search_results != nil && !@search_searching}>
        <div
          :if={@search_note}
          class="mb-3 rounded-lg bg-yellow-900/30 border border-yellow-800/50 px-4 py-2 text-sm text-yellow-300"
        >
          {@search_note}
        </div>

        <div :if={@search_results == []} class="py-6">
          <.empty_state message={"No results for \"#{@search_query}\""} />
        </div>

        <.card :if={@search_results != []}>
          <div class="px-4 py-3 border-b border-gray-800">
            <span class="text-sm text-gray-400">{length(@search_results)} component(s)</span>
          </div>
          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-800">
              <thead>
                <tr>
                  <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500 w-1/4 lg:w-1/5">
                    Name
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500 w-1/5 lg:w-1/6">
                    Publisher
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                    Description
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500 w-24">
                    Status
                  </th>
                  <th class="px-4 py-3 text-right text-xs font-medium uppercase tracking-wider text-gray-500 w-20">
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-800">
                <%= for group <- @search_results do %>
                  <% latest_ref = build_search_ref(group.latest) %>
                  <% status = search_install_status(group.latest, @installed_refs, @installed_digests) %>
                  <tr
                    class={"cursor-pointer hover:bg-gray-800/50 #{if @search_expanded == group.name, do: "bg-gray-800/40"}"}
                    phx-click="toggle_search_expand"
                    phx-value-name={group.name}
                  >
                    <td class="px-4 py-3 text-sm whitespace-nowrap">
                      <span class="inline-flex items-center gap-1.5">
                        <span class="text-blue-400 font-mono text-xs">{group.name}</span>
                        <span
                          :if={group.version_count > 1}
                          class="text-[10px] text-gray-600"
                        >
                          {group.version_count}v
                        </span>
                      </span>
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-400 font-mono text-xs">
                      {group.publisher}
                      <span
                        :if={component_status_badge_class(group.status)}
                        class={"ml-2 inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium " <> component_status_badge_class(group.status)}
                        title={group.status_reason || "Status: #{group.status}"}
                      >
                        {component_status_badge_label(group.status)}
                      </span>
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-300 truncate max-w-0">
                      {group.description || "-"}
                    </td>
                    <td class="px-4 py-3 text-sm">
                      <span
                        :if={status == :installed}
                        class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-900 text-green-300"
                      >
                        Installed
                      </span>
                      <span
                        :if={status == :update_available}
                        class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-yellow-900 text-yellow-300"
                      >
                        Update
                      </span>
                    </td>
                    <td class="px-4 py-3 text-right">
                      <.button
                        :if={status == :not_installed && !MapSet.member?(@pulling, latest_ref)}
                        variant="primary"
                        class="text-xs px-3 py-1"
                        phx-click="pull"
                        phx-value-ref={latest_ref}
                      >
                        Pull
                      </.button>
                      <span
                        :if={MapSet.member?(@pulling, latest_ref)}
                        class="text-xs text-gray-400"
                      >
                        Pulling...
                      </span>
                      <span :if={status == :installed} class="text-xs text-gray-500">
                        Up to date
                      </span>
                    </td>
                  </tr>
                  <!-- Expanded versions -->
                  <tr :if={@search_expanded == group.name} class="bg-gray-900/40">
                    <td colspan="5" class="px-6 py-2">
                      <div class="space-y-1">
                        <%= for ver <- group.versions do %>
                          <% ver_ref = build_search_ref(ver) %>
                          <% ver_status =
                            search_install_status(ver, @installed_refs, @installed_digests) %>
                          <div class="flex items-center justify-between py-1.5">
                            <span class="font-mono text-xs text-gray-300">
                              {comp_field(ver, :version)}
                            </span>
                            <div class="flex items-center gap-2">
                              <span
                                :if={ver_status == :installed}
                                class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-green-900/50 text-green-400"
                              >
                                Installed
                              </span>
                              <.button
                                :if={
                                  ver_status != :installed &&
                                    !MapSet.member?(@pulling, ver_ref)
                                }
                                variant="ghost"
                                class="text-xs px-2 py-0.5"
                                phx-click="pull"
                                phx-value-ref={ver_ref}
                              >
                                Pull
                              </.button>
                              <span
                                :if={MapSet.member?(@pulling, ver_ref)}
                                class="text-xs text-gray-400"
                              >
                                Pulling...
                              </span>
                            </div>
                          </div>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
      
    <!-- Divider -->
      <div class="border-t border-gray-800"></div>
      
    <!-- Installed Components -->
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <button
            phx-click="filter_type"
            phx-value-type=""
            class={"inline-flex items-center px-3 py-1.5 rounded-full text-sm font-medium transition-colors #{if is_nil(@type_filter), do: "bg-gray-700 text-white", else: "bg-gray-800 text-gray-400 hover:text-gray-300"}"}
          >
            All
          </button>
          <button
            phx-click="filter_type"
            phx-value-type="catalyst"
            class={"inline-flex items-center px-3 py-1.5 rounded-full text-sm font-medium transition-colors #{if @type_filter == "catalyst", do: "bg-purple-900 text-purple-300", else: "bg-gray-800 text-gray-400 hover:text-gray-300"}"}
          >
            Catalysts
          </button>
          <button
            phx-click="filter_type"
            phx-value-type="reagent"
            class={"inline-flex items-center px-3 py-1.5 rounded-full text-sm font-medium transition-colors #{if @type_filter == "reagent", do: "bg-blue-900 text-blue-300", else: "bg-gray-800 text-gray-400 hover:text-gray-300"}"}
          >
            Reagents
          </button>
          <button
            phx-click="filter_type"
            phx-value-type="formula"
            class={"inline-flex items-center px-3 py-1.5 rounded-full text-sm font-medium transition-colors #{if @type_filter == "formula", do: "bg-amber-900 text-amber-300", else: "bg-gray-800 text-gray-400 hover:text-gray-300"}"}
          >
            Formulas
          </button>
        </div>
        <.button variant="secondary" phx-click="register" disabled={@registering}>
          {if @registering, do: "Registering...", else: "Register Components"}
        </.button>
      </div>

      <div
        :if={@register_log != [] or @registering}
        id="register-log"
        phx-hook="ScrollBottom"
        class="bg-gray-950 rounded p-3 max-h-48 overflow-y-auto space-y-0.5 mb-4"
      >
        <div :for={entry <- @register_log} class="flex items-start gap-2 text-xs font-mono">
          <span class={[
            "shrink-0 w-2 h-2 rounded-full mt-1",
            register_phase_color(entry.phase)
          ]} />
          <span class="break-all text-gray-300">
            {entry.message}
          </span>
        </div>
        <div :if={@registering} class="flex items-center gap-2 text-xs text-blue-400 pt-1">
          <span class="inline-block w-2 h-2 rounded-full bg-blue-400 animate-pulse" /> Registering...
        </div>
      </div>

      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading && @components == []} class="py-8">
        <.empty_state message="No components found" />
      </div>
      
    <!-- Grouped component tables -->
      <div :if={!@loading && @components != []} class="space-y-6">
        <section :for={{type, groups} <- @sorted_groups}>
          <div class="flex items-center gap-2 mb-3">
            <h3 class="text-sm font-semibold text-white">{type_label(type)}</h3>
            <span class={"inline-flex items-center px-2 py-0.5 rounded text-xs font-medium #{type_badge_color(type)}"}>
              {length(groups)}
            </span>
          </div>
          <.card>
            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-800">
                <thead>
                  <tr>
                    <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500 w-1/4 lg:w-1/5">
                      Name
                    </th>
                    <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500 w-1/5 lg:w-1/6">
                      Publisher
                    </th>
                    <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">
                      Description
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-800">
                  <%= for group <- groups do %>
                    <tr
                      phx-click="toggle_expand"
                      phx-value-ref={group.name_ref}
                      class={"cursor-pointer transition-colors #{if @expanded_ref == group.name_ref, do: "bg-gray-800/80", else: "hover:bg-gray-800/50"}"}
                    >
                      <td class="px-4 py-3 text-sm whitespace-nowrap">
                        <span class="inline-flex items-center gap-1.5">
                          <span class={"inline-block w-2 h-2 rounded-full #{if @setup_readiness[group.name_ref] == true, do: "bg-green-500", else: "bg-red-500"}"} />
                          <span class="text-blue-400 font-mono text-xs">
                            {extract_name(group.name_ref)}
                          </span>
                          <span
                            :if={group.version_count > 1}
                            class="text-[10px] text-gray-600"
                          >
                            {group.version_count}v
                          </span>
                          <span
                            :if={
                              Enum.any?(
                                group.versions,
                                &(comp_field(&1, :superseded) ||
                                    comp_field(&1, :upstream_superseded))
                              )
                            }
                            class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-emerald-900/50 text-emerald-300"
                            title="a newer shipped version exists"
                          >
                            update
                          </span>
                        </span>
                      </td>
                      <td class="px-4 py-3 text-sm text-gray-400 whitespace-nowrap font-mono text-xs">
                        {extract_publisher(group.latest)}
                      </td>
                      <td class="px-4 py-3 text-sm text-gray-300 truncate max-w-0">
                        {group.description || "-"}
                      </td>
                    </tr>
                    <!-- Expanded detail row -->
                    <tr :if={@expanded_ref == group.name_ref} class="bg-gray-900/60">
                      <td colspan="3" class="px-4 py-4">
                        <div :if={@expanded_detail} class="space-y-4">
                          <!-- Description -->
                          <div :if={comp_field(@expanded_detail, :description)}>
                            <p class="text-sm text-gray-300">
                              {comp_field(@expanded_detail, :description)}
                            </p>
                          </div>
                          
    <!-- Tags -->
                          <div :if={
                            is_list(comp_field(@expanded_detail, :tags)) &&
                              comp_field(@expanded_detail, :tags) != []
                          }>
                            <div class="flex flex-wrap gap-1">
                              <span
                                :for={tag <- comp_field(@expanded_detail, :tags)}
                                class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-gray-800 text-gray-300"
                              >
                                {tag}
                              </span>
                            </div>
                          </div>
                          
    <!-- Versions table -->
                          <div>
                            <h4 class="text-xs font-semibold text-gray-400 uppercase mb-2">
                              Installed Versions
                            </h4>
                            <div class="rounded-lg border border-gray-800 overflow-hidden">
                              <table class="min-w-full divide-y divide-gray-800">
                                <thead class="bg-gray-900/50">
                                  <tr>
                                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500">
                                      Version
                                    </th>
                                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500">
                                      Size
                                    </th>
                                    <th class="px-3 py-2 text-left text-xs font-medium text-gray-500">
                                      Digest
                                    </th>
                                    <th class="px-3 py-2 text-right text-xs font-medium text-gray-500">
                                    </th>
                                  </tr>
                                </thead>
                                <tbody class="divide-y divide-gray-800/50">
                                  <%= for {ver, idx} <- Enum.with_index(@expanded_versions) do %>
                                    <% ver_ref = comp_ref(ver) %>
                                    <tr class="hover:bg-gray-800/30">
                                      <td class="px-3 py-2 text-sm">
                                        <span class="font-mono text-white">
                                          {comp_field(ver, :version)}
                                        </span>
                                        <span
                                          :if={idx == 0}
                                          class="ml-1.5 inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-blue-900/50 text-blue-300"
                                        >
                                          latest
                                        </span>
                                        <% badge = provenance_badge(comp_field(ver, :provenance)) %>
                                        <span
                                          :if={badge}
                                          class={"ml-1.5 inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium #{elem(badge, 1)}"}
                                        >
                                          {elem(badge, 0)}
                                        </span>
                                        <span
                                          :if={comp_field(ver, :superseded)}
                                          class="ml-1.5 inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-emerald-900/50 text-emerald-300"
                                          title="a newer shipped version exists"
                                        >
                                          update shipped
                                        </span>
                                        <span
                                          :if={comp_field(ver, :upstream_superseded)}
                                          class="ml-1.5 inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-emerald-900/50 text-emerald-300"
                                          title={"forked from #{comp_field(ver, :forked_from)} — a newer upstream version is available locally"}
                                        >
                                          upstream updated
                                        </span>
                                        <span
                                          :if={comp_field(ver, :shadows_shipped)}
                                          class="ml-1.5 inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-amber-900/50 text-amber-300"
                                          title="your component hides a same-named shipped one — removing it reveals the shipped version"
                                        >
                                          hides shipped
                                        </span>
                                      </td>
                                      <td class="px-3 py-2 text-sm text-gray-400">
                                        {format_bytes(comp_field(ver, :size))}
                                      </td>
                                      <td class="px-3 py-2 text-sm text-gray-500 font-mono text-xs">
                                        <span title={comp_field(ver, :digest) || ""}>
                                          {(comp_field(ver, :digest) || "")
                                          |> to_string()
                                          |> String.slice(0..15)}...
                                        </span>
                                      </td>
                                      <td class="px-3 py-2 text-right">
                                        <div class="flex items-center justify-end gap-1">
                                          <span
                                            :if={@pushing == ver_ref}
                                            class="text-xs text-blue-400 animate-pulse"
                                          >
                                            Pushing...
                                          </span>
                                          <.button
                                            :if={
                                              comp_field(ver, :publisher) == @local_publisher &&
                                                !@pushing
                                            }
                                            variant="ghost"
                                            class="text-xs px-2 py-0.5"
                                            phx-click="push"
                                            phx-value-ref={ver_ref}
                                            data-confirm={"Push #{ver_ref} to registry?"}
                                          >
                                            Push
                                          </.button>
                                          <.button
                                            :if={
                                              comp_field(ver, :provenance) == "bundled_modified" &&
                                                !@pushing
                                            }
                                            variant="ghost"
                                            class="text-xs px-2 py-0.5 text-amber-400 hover:text-amber-300"
                                            phx-click="reset"
                                            phx-value-ref={ver_ref}
                                            data-confirm={"Reset #{ver_ref} to the shipped version? Your edits will be lost."}
                                          >
                                            Reset
                                          </.button>
                                          <.button
                                            :if={
                                              comp_field(ver, :provenance) not in [
                                                "bundled",
                                                "bundled_modified"
                                              ] &&
                                                !@pushing
                                            }
                                            variant="ghost"
                                            class="text-xs px-2 py-0.5 text-red-400 hover:text-red-300"
                                            phx-click="remove"
                                            phx-value-ref={ver_ref}
                                            data-confirm={"Remove #{ver_ref}?"}
                                          >
                                            Remove
                                          </.button>
                                        </div>
                                      </td>
                                    </tr>
                                  <% end %>
                                </tbody>
                              </table>
                            </div>
                            <!-- Progress log for push/pull -->
                            <div
                              :if={@progress_log != []}
                              id="version-progress-log"
                              phx-hook="ScrollBottom"
                              class="mt-2 bg-gray-950 rounded p-3 max-h-32 overflow-y-auto space-y-0.5"
                            >
                              <div
                                :for={entry <- @progress_log}
                                class="flex items-start gap-2 text-xs font-mono"
                              >
                                <span class={[
                                  "shrink-0 w-2 h-2 rounded-full mt-1",
                                  progress_phase_color(entry.phase)
                                ]} />
                                <span class="break-all text-gray-300">
                                  {entry.message}
                                </span>
                              </div>
                            </div>
                          </div>
                          
    <!-- Consent section -->
                          <div class="border-t border-gray-800 pt-4">
                            <div class="flex items-center justify-between mb-3">
                              <div class="flex items-center gap-2">
                                <h4 class="text-xs font-semibold text-gray-400 uppercase">
                                  Consent
                                </h4>
                                <span
                                  :if={@expanded_plan && plan_field(@expanded_plan, :ready) == true}
                                  class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-900 text-green-300"
                                >
                                  Ready
                                </span>
                                <span
                                  :if={@expanded_plan && plan_field(@expanded_plan, :ready) != true}
                                  class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-yellow-900 text-yellow-300"
                                >
                                  Needs grant
                                </span>
                              </div>
                              <.button
                                :if={@expanded_plan}
                                variant="primary"
                                class="text-xs px-3 py-1"
                                phx-click="open_consent"
                                phx-value-ref={@expanded_ref}
                              >
                                Grant access
                              </.button>
                            </div>
                            
    <!-- No plan -->
                            <div :if={!@expanded_plan} class="text-sm text-gray-500 p-4">
                              No setup plan available for this component.
                            </div>
                            
    <!-- Declared needs -->
                            <div :if={@expanded_plan} class="px-4 pb-4">
                              <p
                                :if={(plan_field(@expanded_plan, :needs) || []) == []}
                                class="text-sm text-gray-500"
                              >
                                This component asks for no Connections.
                              </p>
                              <dl
                                :if={(plan_field(@expanded_plan, :needs) || []) != []}
                                class="space-y-3"
                              >
                                <div :for={need <- plan_field(@expanded_plan, :needs) || []}>
                                  <dt class="text-xs text-gray-500 uppercase flex items-center gap-2">
                                    {comp_field(need, :name)}
                                    <span class="font-mono normal-case text-gray-600">
                                      {comp_field(need, :kind)}:{comp_field(need, :qualifier)}
                                    </span>
                                    <span
                                      :if={comp_field(need, :required)}
                                      class="text-red-400 normal-case"
                                    >
                                      required
                                    </span>
                                  </dt>
                                  <dd
                                    :if={comp_field(need, :reason)}
                                    class="text-sm text-gray-300 mt-1"
                                  >
                                    {comp_field(need, :reason)}
                                  </dd>
                                </div>
                              </dl>
                            </div>
                            
    <!-- Dependencies -->
                            <div
                              :if={
                                @expanded_plan &&
                                  (plan_field(@expanded_plan, :dependencies) || []) != []
                              }
                              class="px-4 pb-4"
                            >
                              <dt class="text-xs text-gray-500 uppercase mb-1">Dependencies</dt>
                              <dd class="flex flex-wrap gap-1">
                                <.badge
                                  :for={dep <- plan_field(@expanded_plan, :dependencies) || []}
                                  color="blue"
                                >
                                  {comp_field(dep, :ref)}
                                </.badge>
                              </dd>
                            </div>
                          </div>
                        </div>
                        <div :if={!@expanded_detail} class="text-center text-gray-500 py-4 text-sm">
                          Loading...
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </.card>
        </section>
      </div>
      
    <!-- Consent sheet overlay -->
      <div :if={@consent_sheet_ref} class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="absolute inset-0 bg-black/60"></div>
        <div class="relative w-full max-w-lg max-h-[80vh] overflow-y-auto rounded-lg border border-gray-800 bg-gray-900 p-4 shadow-xl">
          <.live_component
            module={PrismWeb.ConsentSheetComponent}
            id={"consent-#{@consent_sheet_ref}"}
            ref={@consent_sheet_ref}
            context={@context}
            athanor_route={@athanor_route}
            athanor_name={@athanor && @athanor.name}
          />
        </div>
      </div>
    </div>
    """
  end
end
