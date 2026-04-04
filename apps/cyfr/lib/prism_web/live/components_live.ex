defmodule PrismWeb.ComponentsLive do
  use PrismWeb, :live_view
  require Logger

  @policy_fields [
    {"allowed_domains", "Allowed Domains", :array},
    {"allowed_methods", "Allowed Methods", :array},
    {"allowed_paths", "Allowed Paths", :array},
    {"allowed_actions", "Allowed Actions", :array},
    {"allowed_private_ips", "Allowed Private IPs", :array},
    {"allowed_tools", "Allowed Tools", :array},
    {"rate_limit", "Rate Limit", :json},
    {"timeout", "Timeout", :string},
    {"max_memory_bytes", "Max Memory", :bytes},
    {"max_request_size", "Max Request Size", :bytes},
    {"max_response_size", "Max Response Size", :bytes},
    {"max_concurrent_tasks", "Max Concurrent Tasks", :string},
    {"batch_timeout", "Batch Timeout", :string}
  ]

  defp policy_fields_for_type(_type, configurable_fields) when is_list(configurable_fields) do
    Enum.filter(@policy_fields, fn {f, _, _} -> f in configurable_fields end)
  end

  defp policy_fields_for_type(type, _no_configurable_fields) when is_binary(type) do
    case Sanctum.Policy.FieldSchema.default_configurable_fields(type) do
      {:ok, fields} -> Enum.filter(@policy_fields, fn {f, _, _} -> f in fields end)
      {:error, _} -> @policy_fields
    end
  end

  defp policy_fields_for_type(_type, _no_configurable_fields), do: @policy_fields

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic("prism:components", ctx))
    end

    socket =
      socket
      |> assign(:page_title, "Components")
      |> assign(:active_nav, "components")
      |> assign(:components, [])
      |> assign(:grouped, %{})
      |> assign(:type_filter, nil)
      |> assign(:loading, true)
      |> assign(:expanded_ref, nil)
      |> assign(:expanded_detail, nil)
      |> assign(:expanded_plan, nil)
      |> assign(:expanded_type, nil)
      |> assign(:editing, false)
      |> assign(:secret_inputs, %{})
      |> assign(:policy_inputs, %{})
      |> assign(:policy_prefilled, MapSet.new())
      |> assign(:policy_placeholders, %{})
      |> assign(:saving, false)
      |> assign(:publishing, false)
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
      |> assign(:setup_from, nil)

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
      Sanctum.PubSub.topic("progress:#{progress_id}", socket.assigns[:context])
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

               Emissary.MCP.ToolRegistry.call(name, ctx, merged_args)
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
      Sanctum.PubSub.topic("register:#{register_id}", socket.assigns[:context])
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
         |> assign(:expanded_type, plan_field(plan, :type))
         |> assign(:expanded_versions, group.versions)
         |> assign(:editing, false)
         |> assign(:secret_inputs, %{})
         |> assign(:policy_inputs, %{})
         |> assign(:publishing, false)
         |> assign(:progress_log, [])
         |> assign(:progress_id, nil)}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_event("edit_setup", _params, socket) do
    # Re-fetch fresh plan to pick up any external changes (CLI, other tabs)
    ref = latest_versioned_ref(socket)

    plan =
      case call_tool(socket, "component", %{"action" => "setup_plan", "reference" => ref}) do
        {:ok, result} ->
          result

        other ->
          Logger.warning("[ComponentsLive] setup_plan refresh failed: #{inspect(other)}")
          socket.assigns.expanded_plan
      end

    # For already-set secrets, track grant status; for unset, empty string for text input
    secret_inputs =
      (plan_field(plan, :secrets) || [])
      |> Enum.reduce(%{}, fn s, acc ->
        name = comp_field(s, :name)

        if comp_field(s, :already_set) == true do
          grant = if comp_field(s, :already_granted) == true, do: "true", else: "false"
          Map.put(acc, name, grant)
        else
          Map.put(acc, name, "")
        end
      end)

    # Build policy view and dynamic placeholders
    policy_view =
      merge_policy_view(
        plan_field(plan, :policy_current),
        plan_field(plan, :policy_recommended),
        socket.assigns.expanded_type,
        plan_field(plan, :configurable_fields)
      )

    # Only pre-fill inputs when there's a stored policy (user previously configured).
    # Otherwise leave empty — recommended/effective values show as placeholders.
    policy_stored? = plan_field(plan, :policy_stored) == true

    policy_inputs =
      if policy_stored? do
        Enum.reduce(policy_view, %{}, fn {field, _label, type, value, _source}, acc ->
          if value do
            Map.put(acc, field, format_policy_for_edit(value, type))
          else
            acc
          end
        end)
      else
        %{}
      end

    policy_placeholders = build_policy_placeholders(policy_view)

    {:noreply,
     socket
     |> assign(:expanded_plan, plan)
     |> assign(:editing, true)
     |> assign(:secret_inputs, secret_inputs)
     |> assign(:policy_inputs, policy_inputs)
     |> assign(:policy_prefilled, MapSet.new(Map.keys(policy_inputs)))
     |> assign(:policy_placeholders, policy_placeholders)}
  end

  def handle_event("fill_defaults", _params, socket) do
    plan = socket.assigns.expanded_plan
    recommended = plan_field(plan, :policy_recommended) || %{}
    current = plan_field(plan, :policy_current) || %{}
    type = socket.assigns.expanded_type
    configurable = plan_field(plan, :configurable_fields)
    fields = policy_fields_for_type(type, configurable)

    {policy_inputs, new_prefilled} =
      Enum.reduce(fields, {socket.assigns.policy_inputs, socket.assigns.policy_prefilled}, fn
        {field, _label, field_type}, {inputs, prefilled} ->
          current_value = inputs[field]
          rec_value = policy_value(recommended, field) || policy_value(current, field)

          if (current_value == nil || current_value == "") && rec_value != nil do
            {Map.put(inputs, field, format_policy_for_edit(rec_value, field_type)),
             MapSet.put(prefilled, field)}
          else
            {inputs, prefilled}
          end
      end)

    {:noreply,
     socket
     |> assign(:policy_inputs, policy_inputs)
     |> assign(:policy_prefilled, new_prefilled)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, false)
     |> assign(:secret_inputs, %{})
     |> assign(:policy_inputs, %{})
     |> assign(:policy_prefilled, MapSet.new())
     |> assign(:policy_placeholders, %{})}
  end

  def handle_event("setup_change", params, socket) do
    secret_inputs =
      (params["secret"] || %{})
      |> Enum.into(socket.assigns.secret_inputs)

    policy_inputs =
      (params["policy"] || %{})
      |> Enum.into(socket.assigns.policy_inputs)

    {:noreply,
     socket
     |> assign(:secret_inputs, secret_inputs)
     |> assign(:policy_inputs, policy_inputs)}
  end

  def handle_event("save_setup", _params, socket) do
    # expanded_ref is already name-level
    name_ref = socket.assigns.expanded_ref
    ref = latest_versioned_ref(socket)

    socket = assign(socket, :saving, true)

    # Save secrets (grants use name-level ref to cover all versions)
    plan = socket.assigns.expanded_plan

    secret_errors =
      socket.assigns.secret_inputs
      |> Enum.reduce([], fn {name, value}, errors ->
        secret_status =
          Enum.find(plan_field(plan, :secrets) || [], fn s ->
            comp_field(s, :name) == name
          end)

        already_set? = secret_status && comp_field(secret_status, :already_set) == true

        if already_set? do
          # Checkbox mode: grant or skip
          if value == "true" do
            case call_tool(socket, "secret", %{
                   "action" => "grant",
                   "name" => name,
                   "component_ref" => name_ref
                 }) do
              {:ok, _} -> errors
              {:error, reason} -> ["Secret #{name}: #{inspect(reason)}" | errors]
            end
          else
            errors
          end
        else
          # Text input mode: set value and grant
          if String.trim(value) != "" do
            case call_tool(socket, "secret", %{
                   "action" => "set",
                   "name" => name,
                   "value" => value
                 }) do
              {:ok, _} ->
                case call_tool(socket, "secret", %{
                       "action" => "grant",
                       "name" => name,
                       "component_ref" => name_ref
                     }) do
                  {:ok, _} -> errors
                  {:error, reason} -> ["Secret #{name} grant: #{inspect(reason)}" | errors]
                end

              {:error, reason} ->
                ["Secret #{name}: #{inspect(reason)}" | errors]
            end
          else
            errors
          end
        end
      end)

    # Save policy fields (use name-level ref to cover all versions):
    # - non-empty: save the value
    # - empty + was pre-filled: user cleared it, save as empty to override stored value
    # - empty + was NOT pre-filled: skip (untouched field)
    prefilled = socket.assigns.policy_prefilled

    policy_errors =
      socket.assigns.policy_inputs
      |> Enum.reduce([], fn {field, value}, errors ->
        cond do
          String.trim(value) != "" ->
            parsed = parse_policy_for_save(value, field)

            case call_tool(socket, "policy", %{
                   "action" => "update_field",
                   "component_ref" => name_ref,
                   "field" => field,
                   "value" => parsed
                 }) do
              {:ok, _} -> errors
              {:error, reason} -> ["Policy #{field}: #{inspect(reason)}" | errors]
            end

          MapSet.member?(prefilled, field) ->
            parsed = parse_policy_for_save_empty(field)

            case call_tool(socket, "policy", %{
                   "action" => "update_field",
                   "component_ref" => name_ref,
                   "field" => field,
                   "value" => parsed
                 }) do
              {:ok, _} -> errors
              {:error, reason} -> ["Policy #{field}: #{inspect(reason)}" | errors]
            end

          true ->
            errors
        end
      end)

    all_errors = secret_errors ++ policy_errors

    # Refresh the plan
    plan =
      case call_tool(socket, "component", %{"action" => "setup_plan", "reference" => ref}) do
        {:ok, result} ->
          result

        other ->
          Logger.warning(
            "[ComponentsLive] setup_plan refresh after save failed: #{inspect(other)}"
          )

          socket.assigns.expanded_plan
      end

    readiness =
      Map.put(socket.assigns.setup_readiness, name_ref, plan_field(plan, :ready) == true)

    socket =
      socket
      |> assign(:saving, false)
      |> assign(:editing, false)
      |> assign(:expanded_plan, plan)
      |> assign(:setup_readiness, readiness)
      |> assign(:secret_inputs, %{})
      |> assign(:policy_inputs, %{})
      |> assign(:policy_prefilled, MapSet.new())
      |> assign(:policy_placeholders, %{})

    socket =
      if all_errors == [] do
        # Broadcast setup completion so AgentLive can auto-resume
        ctx = socket.assigns[:context]

        if ctx do
          Phoenix.PubSub.broadcast(
            Emissary.PubSub,
            Sanctum.PubSub.topic("prism:setup_complete", ctx),
            {:setup_complete, name_ref}
          )

          # If we came from another app, navigate back after setup
          if socket.assigns.setup_from == "agent" do
            Phoenix.PubSub.broadcast(
              Emissary.PubSub,
              Sanctum.PubSub.topic("prism:shell_navigate", ctx),
              {:navigate_to, "agent", %{}}
            )
          end
        end

        socket
        |> assign(:setup_from, nil)
        |> put_flash(:info, "Setup saved for #{name_ref} (all versions)")
      else
        put_flash(socket, :error, Enum.join(all_errors, "; "))
      end

    {:noreply, socket}
  end

  def handle_event("publish", %{"ref" => ref}, socket) do
    progress_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    Phoenix.PubSub.subscribe(
      Emissary.PubSub,
      Sanctum.PubSub.topic("progress:#{progress_id}", socket.assigns[:context])
    )

    socket =
      socket
      |> assign(:publishing, true)
      |> assign(:progress_id, progress_id)
      |> assign(:progress_log, [])

    lv = self()
    ctx = socket.assigns.context

    case Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
           result =
             try do
               Emissary.MCP.ToolRegistry.call("component", ctx, %{
                 "action" => "publish",
                 "reference" => ref,
                 "progress_id" => progress_id
               })
             rescue
               e -> {:error, Exception.message(e)}
             end

           send(lv, {:publish_complete, ref, result})
         end) do
      {:ok, _pid} ->
        Process.send_after(self(), {:task_timeout, :publish}, 120_000)
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to start publish task: #{inspect(reason)}")

        {:noreply,
         socket |> assign(:publishing, false) |> put_flash(:error, "Failed to start publish")}
    end
  end

  def handle_event("remove", %{"ref" => ref}, socket) do
    case call_tool(socket, "component", %{"action" => "remove", "reference" => ref}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> collapse()
         |> fetch_components()
         |> put_flash(:info, "Removed #{ref}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to remove: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      socket = socket |> fetch_components() |> assign(:loading, false)

      socket =
        case params do
          %{"ref" => ref, "setup" => "true"} ->
            socket
            |> assign(:setup_from, params["from"])
            |> tap(fn _ -> send(self(), {:deep_link_setup, ref}) end)

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
  def handle_info({:policy_changed, metadata, _measurements}, socket) do
    _changed_ref = metadata[:component_ref]
    expanded_ref = socket.assigns.expanded_ref

    socket =
      if expanded_ref && !socket.assigns.editing do
        # Re-fetch plan if we're viewing the affected component (or any, since
        # type defaults affect all components of that type)
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
                "[ComponentsLive] setup_plan refresh on policy change failed: #{inspect(other)}"
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

    {:noreply, socket}
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
        Sanctum.PubSub.topic("register:#{socket.assigns.register_id}", socket.assigns[:context])
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
        Sanctum.PubSub.topic("register:#{socket.assigns.register_id}", socket.assigns[:context])
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

  def handle_info({:publish_complete, _ref, {:ok, result}}, socket) do
    unsubscribe_progress(socket)
    oci_ref = comp_field(result, :oci_reference) || result[:oci_reference]

    complete_entry = %{
      phase: :complete,
      message: "Published → #{oci_ref}",
      at: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> assign(:publishing, false)
     |> assign(:progress_id, nil)
     |> assign(:progress_log, socket.assigns.progress_log ++ [complete_entry])
     |> put_flash(:info, "Published → #{oci_ref}")}
  end

  def handle_info({:publish_complete, _ref, {:error, reason}}, socket) do
    unsubscribe_progress(socket)

    error_msg = format_publish_error(reason)

    error_entry = %{
      phase: :error,
      message: error_msg,
      at: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> assign(:publishing, false)
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

  def handle_info({:task_timeout, :publish}, socket) do
    if socket.assigns.publishing do
      Logger.warning("[ComponentsLive] Publish task timed out after 120s")

      {:noreply,
       socket
       |> assign(:publishing, false)
       |> assign(:progress_id, nil)
       |> assign(:progress_log, [])
       |> put_flash(:error, "Publish timed out")}
    else
      {:noreply, socket}
    end
  end


  def handle_info({:deep_link_setup, ref}, socket) do
    # Find the component group matching the ref and auto-expand + enter edit mode
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

      policy_placeholders =
        if plan do
          policy_view =
            merge_policy_view(
              plan_field(plan, :policy_current),
              plan_field(plan, :policy_recommended),
              plan_field(plan, :type),
              plan_field(plan, :configurable_fields)
            )

          build_policy_placeholders(policy_view)
        else
          %{}
        end

      {:noreply,
       socket
       |> assign(:expanded_ref, group.name_ref)
       |> assign(:expanded_detail, detail)
       |> assign(:expanded_plan, plan)
       |> assign(:expanded_type, plan_field(plan, :type))
       |> assign(:expanded_versions, group.versions)
       |> assign(:editing, true)
       |> assign(:secret_inputs, %{})
       |> assign(:policy_inputs, %{})
       |> assign(:policy_placeholders, policy_placeholders)
       |> assign(:loading, false)}
    else
      {:noreply,
       socket
       |> assign(:loading, false)
       |> put_flash(:warning, "Component #{ref} not found")}
    end
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
        Sanctum.PubSub.topic("progress:#{socket.assigns.progress_id}", socket.assigns[:context])
      )
    end
  end

  defp collapse(socket) do
    socket
    |> assign(:expanded_ref, nil)
    |> assign(:expanded_detail, nil)
    |> assign(:expanded_plan, nil)
    |> assign(:expanded_type, nil)
    |> assign(:expanded_versions, [])
    |> assign(:editing, false)
    |> assign(:secret_inputs, %{})
    |> assign(:policy_inputs, %{})
    |> assign(:policy_placeholders, %{})
    |> assign(:publishing, false)
    |> assign(:progress_log, [])
    |> assign(:progress_id, nil)
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
      publisher = comp_field(comp, :publisher) || comp_field(comp, :publisher_name)
      type = comp_field(comp, :component_type)
      {name, publisher, type}
    end)
    |> Enum.map(fn {{name, publisher, type}, local_versions} ->
      sorted =
        Enum.sort_by(local_versions, fn v -> comp_field(v, :version) || "0.0.0" end, fn a, b ->
          case Version.compare(a, b) do
            :gt -> true
            _ -> false
          end
        end)

      latest = hd(sorted)

      # Merge remote_versions into the list (remote versions not already local)
      remote_vs = comp_field(latest, :remote_versions) || []
      local_vs = MapSet.new(sorted, fn v -> comp_field(v, :version) end)

      remote_only =
        remote_vs
        |> Enum.reject(fn v -> MapSet.member?(local_vs, v) end)
        |> Enum.map(fn v ->
          ref = build_ref_from_parts(type, publisher, name, v)
          %{version: v, component_ref: ref, remote_only: true}
        end)

      all_versions =
        (sorted ++ remote_only)
        |> Enum.sort_by(fn v -> comp_field(v, :version) || "0.0.0" end, fn a, b ->
          case Version.compare(a, b) do
            :gt -> true
            _ -> false
          end
        end)

      %{
        name: name,
        publisher: publisher || "local",
        component_type: type,
        description: comp_field(latest, :description),
        latest: latest,
        versions: all_versions,
        version_count: length(all_versions)
      }
    end)
    |> Enum.sort_by(fn g -> g.name end)
  end

  defp build_ref_from_parts(type, publisher, name, version) do
    base = if publisher && publisher != "", do: "#{publisher}.#{name}", else: name
    ref = if type && type != "", do: "#{type}:#{base}", else: base
    if version, do: "#{ref}:#{version}", else: ref
  end

  defp format_publish_error(reason) when is_binary(reason), do: "Publish failed: #{reason}"

  defp format_publish_error({:error, msg}) when is_binary(msg),
    do: "Publish failed: #{msg}"

  defp format_publish_error(reason), do: "Publish failed: #{inspect(reason)}"

  defp progress_phase_color(:pulling), do: "bg-orange-400"
  defp progress_phase_color(:pushing), do: "bg-blue-400"
  defp progress_phase_color(:publishing), do: "bg-blue-400"
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

    # One setup_plan call per component (not per version)
    readiness =
      Enum.reduce(groups, %{}, fn group, acc ->
        ref = comp_ref(group.latest)

        case call_tool(socket, "component", %{"action" => "setup_plan", "reference" => ref}) do
          {:ok, plan} -> Map.put(acc, group.name_ref, plan_field(plan, :ready) == true)
          _ -> acc
        end
      end)

    socket
    |> assign(:all_components, all_components)
    |> assign(:component_groups, groups)
    |> assign(:setup_readiness, readiness)
    |> collapse()
    |> apply_filter()
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
        Enum.sort_by(versions, fn v -> comp_field(v, :version) || "0.0.0" end, fn a, b ->
          case Version.compare(a, b) do
            :gt -> true
            _ -> false
          end
        end)

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
    publisher = comp_field(comp, :publisher) || comp_field(comp, :publisher_name)
    version = comp_field(comp, :version)

    base =
      if publisher && publisher != "local",
        do: "#{publisher}.#{name}",
        else: name

    ref = if type, do: "#{type}:#{base}", else: base
    if version, do: "#{ref}:#{version}", else: ref
  end

  defp plan_field(nil, _key), do: nil
  defp plan_field(plan, key), do: plan[key] || plan[to_string(key)]

  defp policy_value(policy, field) when is_map(policy) do
    policy[field] || policy[String.to_existing_atom(field)]
  rescue
    ArgumentError -> policy[field]
  end

  defp policy_value(_, _), do: nil

  defp merge_policy_view(current, recommended, type, configurable_fields) do
    current = current || %{}
    recommended = recommended || %{}
    fields = policy_fields_for_type(type, configurable_fields)

    Enum.map(fields, fn {field, label, field_type} ->
      cur = policy_value(current, field)
      rec = policy_value(recommended, field)
      value = cur || rec

      source =
        cond do
          cur != nil -> :current
          rec != nil -> :recommended
          true -> nil
        end

      {field, label, field_type, value, source}
    end)
  end

  defp build_policy_placeholders(policy_view) do
    Enum.reduce(policy_view, %{}, fn {field, _label, type, value, source}, acc ->
      hint =
        case {source, value} do
          {:recommended, v} when v != nil ->
            "#{format_policy_for_edit(v, type)} (recommended)"

          {:current, v} when v != nil ->
            "#{format_policy_for_edit(v, type)} (default)"

          _ ->
            policy_placeholder(field)
        end

      Map.put(acc, field, hint)
    end)
  end

  defp has_recommended_defaults?(nil), do: false

  defp has_recommended_defaults?(plan) do
    rec = plan_field(plan, :policy_recommended)
    cur = plan_field(plan, :policy_current)
    (is_map(rec) && rec != %{}) || (is_map(cur) && cur != %{})
  end

  defp format_policy_display(nil, _type), do: "not configured"
  defp format_policy_display([], :array), do: "not configured"
  defp format_policy_display(value, :array) when is_list(value), do: Enum.join(value, ", ")

  defp format_policy_display(value, :json) when is_map(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end

  defp format_policy_display(value, :bytes) when is_integer(value), do: format_bytes(value)
  defp format_policy_display(value, _type), do: to_string(value)

  defp format_policy_for_edit(value, :array) when is_list(value), do: Enum.join(value, ", ")

  defp format_policy_for_edit(value, :json) when is_map(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end

  defp format_policy_for_edit(value, _type), do: to_string(value)

  defp parse_policy_for_save(value, field)
       when field in [
              "allowed_domains",
              "allowed_methods",
              "allowed_private_ips",
              "allowed_tools",
              "allowed_paths",
              "allowed_actions"
            ] do
    # Try JSON array first, fall back to comma-separated
    case Jason.decode(value) do
      {:ok, list} when is_list(list) ->
        case Jason.encode(list) do
          {:ok, json} -> json
          {:error, _} -> "[]"
        end

      _ ->
        list =
          value
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        case Jason.encode(list) do
          {:ok, json} -> json
          {:error, _} -> "[]"
        end
    end
  end

  defp parse_policy_for_save(value, "rate_limit") do
    case Jason.decode(value) do
      {:ok, _map} -> value
      _ -> value
    end
  end

  defp parse_policy_for_save(value, _field), do: value

  @array_policy_fields ~w(allowed_domains allowed_methods allowed_private_ips allowed_tools allowed_paths allowed_actions)
  defp parse_policy_for_save_empty(field) when field in @array_policy_fields, do: "[]"
  defp parse_policy_for_save_empty(_field), do: ""

  # --- Display helpers ---

  defp type_sort_order("catalyst"), do: 0
  defp type_sort_order("reagent"), do: 1
  defp type_sort_order("formula"), do: 2
  defp type_sort_order("tincture"), do: 3
  defp type_sort_order(_), do: 4

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

  defp strip_type(ref), do: ref

  # Extract publisher from a component or ref
  defp extract_publisher(comp) when is_map(comp) do
    comp_field(comp, :publisher) || comp_field(comp, :publisher_name) || "local"
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

  defp badge_color_for("Allowed Domains"), do: "blue"
  defp badge_color_for("Allowed Methods"), do: "green"
  defp badge_color_for("Allowed Paths"), do: "purple"
  defp badge_color_for("Allowed Actions"), do: "green"
  defp badge_color_for("Allowed Tools"), do: "yellow"
  defp badge_color_for(_), do: "blue"

  defp format_bytes(nil), do: "-"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(val), do: to_string(val)

  defp secret_status_class(secret) do
    set? = comp_field(secret, :already_set) == true
    granted? = comp_field(secret, :already_granted) == true

    cond do
      set? && granted? -> {"Set & Granted", "bg-green-900 text-green-300"}
      set? -> {"Set (not granted)", "bg-yellow-900 text-yellow-300"}
      true -> {"Not configured", "bg-red-900 text-red-300"}
    end
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    sorted_groups =
      assigns.grouped
      |> Enum.sort_by(fn {type, _} -> type_sort_order(type) end)

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

    # Build merged policy view for expanded component (filtered by type)
    policy_view =
      if assigns.expanded_plan do
        merge_policy_view(
          plan_field(assigns.expanded_plan, :policy_current),
          plan_field(assigns.expanded_plan, :policy_recommended),
          assigns.expanded_type,
          plan_field(assigns.expanded_plan, :configurable_fields)
        )
      else
        []
      end

    assigns =
      assigns
      |> assign(:sorted_groups, sorted_groups)
      |> assign(:installed_refs, inst_refs)
      |> assign(:installed_digests, inst_digests)
      |> assign(:policy_view, policy_view)

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
                                            :if={@publishing}
                                            class="text-xs text-blue-400 animate-pulse"
                                          >
                                            Publishing...
                                          </span>
                                          <.button
                                            :if={
                                              comp_field(ver, :publisher) == "local" && !@publishing
                                            }
                                            variant="ghost"
                                            class="text-xs px-2 py-0.5"
                                            phx-click="publish"
                                            phx-value-ref={ver_ref}
                                            data-confirm={"Publish #{ver_ref} to registry?"}
                                          >
                                            Publish
                                          </.button>
                                          <.button
                                            :if={!@publishing}
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
                            <!-- Progress log for publish/pull -->
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
                          
    <!-- Setup section -->
                          <div class="border-t border-gray-800 pt-4">
                            <div class="flex items-center justify-between mb-3">
                              <div class="flex items-center gap-2">
                                <h4 class="text-xs font-semibold text-gray-400 uppercase">
                                  Setup
                                </h4>
                                <span class="text-[10px] text-gray-600 normal-case">
                                  applies to all versions
                                </span>
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
                                  Setup Required
                                </span>
                              </div>
                            </div>
                            
    <!-- No manifest -->
                            <div :if={!@expanded_plan} class="text-sm text-gray-500 p-4">
                              No setup manifest found for this component.
                            </div>

    <!-- Tinctures have no execution policy -->
                            <div :if={@expanded_plan && @expanded_type == "tincture"} class="text-sm text-gray-500 p-4">
                              Tinctures have no execution policy. Visibility is managed via the <code class="text-gray-400">tincture_visibility</code> tool.
                            </div>

    <!-- Edit mode -->
                            <form
                              :if={@expanded_plan && @editing && @expanded_type != "tincture"}
                              phx-change="setup_change"
                              phx-submit="save_setup"
                            >
                              <div class="grid grid-cols-1 md:grid-cols-2 gap-6 p-4">
                                <dl class="space-y-4">
                                  <%= for secret <- plan_field(@expanded_plan, :secrets) || [] do %>
                                    <% secret_name = comp_field(secret, :name) %>
                                    <% {status_text, status_class} = secret_status_class(secret) %>
                                    <div>
                                      <dt class="text-xs text-gray-500 uppercase flex items-center gap-2">
                                        {secret_name}
                                        <span
                                          :if={comp_field(secret, :required)}
                                          class="text-red-400 normal-case"
                                        >
                                          required
                                        </span>
                                        <span class={"inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium normal-case #{status_class}"}>
                                          {status_text}
                                        </span>
                                      </dt>
                                      <dd class="mt-1">
                                        <%= if comp_field(secret, :already_set) == true do %>
                                          <label class="flex items-center gap-2 cursor-pointer">
                                            <input
                                              type="hidden"
                                              name={"secret[#{secret_name}]"}
                                              value="false"
                                            />
                                            <input
                                              type="checkbox"
                                              name={"secret[#{secret_name}]"}
                                              value="true"
                                              checked={@secret_inputs[secret_name] == "true"}
                                              class="h-4 w-4 rounded border-gray-600 bg-gray-900 text-blue-500 focus:ring-blue-500 focus:ring-offset-0"
                                            />
                                            <span class="text-sm text-gray-300">Grant access</span>
                                          </label>
                                        <% else %>
                                          <input
                                            type="password"
                                            name={"secret[#{secret_name}]"}
                                            value={@secret_inputs[secret_name] || ""}
                                            placeholder={
                                              comp_field(secret, :description) || "Enter value..."
                                            }
                                            phx-debounce="blur"
                                            class="w-full rounded bg-gray-900 border border-gray-700 px-3 py-1.5 text-sm text-white placeholder-gray-600 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                                          />
                                        <% end %>
                                      </dd>
                                    </div>
                                  <% end %>
                                  <% all_fields =
                                    merge_policy_view(
                                      plan_field(@expanded_plan, :policy_current),
                                      plan_field(@expanded_plan, :policy_recommended),
                                      @expanded_type,
                                      plan_field(@expanded_plan, :configurable_fields)
                                    ) %>
                                  <% {left, right} =
                                    Enum.split(all_fields, div(length(all_fields) + 1, 2)) %>
                                  <%= for {field, label, _type, _value, _source} <- left do %>
                                    <div>
                                      <dt class="text-xs text-gray-500 uppercase">{label}</dt>
                                      <dd class="mt-1">
                                        <input
                                          type="text"
                                          name={"policy[#{field}]"}
                                          value={@policy_inputs[field] || ""}
                                          placeholder={@policy_placeholders[field] || policy_placeholder(field)}
                                          phx-debounce="blur"
                                          class="w-full rounded bg-gray-900 border border-gray-700 px-3 py-1.5 text-sm text-white placeholder-gray-600 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                                        />
                                      </dd>
                                    </div>
                                  <% end %>
                                </dl>
                                <dl class="space-y-4">
                                  <%= for {field, label, _type, _value, _source} <- right do %>
                                    <div>
                                      <dt class="text-xs text-gray-500 uppercase">{label}</dt>
                                      <dd class="mt-1">
                                        <input
                                          type="text"
                                          name={"policy[#{field}]"}
                                          value={@policy_inputs[field] || ""}
                                          placeholder={@policy_placeholders[field] || policy_placeholder(field)}
                                          phx-debounce="blur"
                                          class="w-full rounded bg-gray-900 border border-gray-700 px-3 py-1.5 text-sm text-white placeholder-gray-600 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                                        />
                                      </dd>
                                    </div>
                                  <% end %>
                                </dl>
                              </div>
                            </form>
                            
    <!-- View mode -->
                            <div :if={@expanded_plan && !@editing && @expanded_type != "tincture"}>
                              <div class="grid grid-cols-1 md:grid-cols-2 gap-6 p-4">
                                <dl class="space-y-4">
                                  <%= for secret <- plan_field(@expanded_plan, :secrets) || [] do %>
                                    <% {status_text, status_class} = secret_status_class(secret) %>
                                    <div>
                                      <dt class="text-xs text-gray-500 uppercase flex items-center gap-2">
                                        {comp_field(secret, :name)}
                                        <span
                                          :if={comp_field(secret, :required)}
                                          class="text-red-400 normal-case"
                                        >
                                          required
                                        </span>
                                      </dt>
                                      <dd class="text-sm text-white mt-1 flex items-center gap-2">
                                        <span class={"inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium #{status_class}"}>
                                          {status_text}
                                        </span>
                                      </dd>
                                    </div>
                                  <% end %>
                                  <%= for provider_status <- plan_field(@expanded_plan, :oauth) || [] do %>
                                    <div>
                                      <dt class="text-xs text-gray-500 uppercase flex items-center gap-2">
                                        OAuth: {comp_field(provider_status, :provider)}
                                      </dt>
                                      <dd class="text-sm text-white mt-1 flex items-center gap-2">
                                        <%= if comp_field(provider_status, :component_authorized) == true do %>
                                          <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-green-900 text-green-300">
                                            Authorized
                                          </span>
                                        <% else %>
                                          <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-yellow-900 text-yellow-300">
                                            Authorization pending
                                          </span>
                                        <% end %>
                                      </dd>
                                    </div>
                                  <% end %>
                                  <% {left_view, right_view} =
                                    Enum.split(@policy_view, div(length(@policy_view) + 1, 2)) %>
                                  <%= for {_field, label, type, value, source} <- left_view do %>
                                    <div>
                                      <dt class="text-xs text-gray-500 uppercase">{label}</dt>
                                      <dd
                                        class={"text-sm mt-1 #{if source == :recommended, do: "text-gray-400 italic", else: "text-white"}"}
                                        title={
                                          if source == :recommended,
                                            do: "Recommended by manifest",
                                            else: ""
                                        }
                                      >
                                        <%= if is_list(value) && value != [] do %>
                                          <div class="flex flex-wrap gap-1">
                                            <.badge
                                              :for={item <- value}
                                              color={badge_color_for(label)}
                                            >
                                              {item}
                                            </.badge>
                                          </div>
                                        <% else %>
                                          {format_policy_display(value, type)}
                                        <% end %>
                                      </dd>
                                    </div>
                                  <% end %>
                                </dl>
                                <dl class="space-y-4">
                                  <%= for {_field, label, type, value, source} <- right_view do %>
                                    <div>
                                      <dt class="text-xs text-gray-500 uppercase">{label}</dt>
                                      <dd
                                        class={"text-sm mt-1 #{if source == :recommended, do: "text-gray-400 italic", else: "text-white"}"}
                                        title={
                                          if source == :recommended,
                                            do: "Recommended by manifest",
                                            else: ""
                                        }
                                      >
                                        <%= if is_list(value) && value != [] do %>
                                          <div class="flex flex-wrap gap-1">
                                            <.badge
                                              :for={item <- value}
                                              color={badge_color_for(label)}
                                            >
                                              {item}
                                            </.badge>
                                          </div>
                                        <% else %>
                                          {format_policy_display(value, type)}
                                        <% end %>
                                      </dd>
                                    </div>
                                  <% end %>
                                </dl>
                              </div>
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
                          
    <!-- Action buttons -->
                          <div class="border-t border-gray-800 pt-4 flex items-center justify-end gap-2">
                            <%= if @editing do %>
                              <.button
                                :if={has_recommended_defaults?(@expanded_plan)}
                                variant="ghost"
                                phx-click="fill_defaults"
                              >
                                Fill Recommended
                              </.button>
                              <.button variant="secondary" phx-click="cancel_edit">Cancel</.button>
                              <.button variant="primary" phx-click="save_setup">
                                {if @saving, do: "Saving...", else: "Save"}
                              </.button>
                            <% else %>
                              <.button :if={@expanded_plan && @expanded_type != "tincture"} variant="secondary" phx-click="edit_setup">
                                Edit
                              </.button>
                            <% end %>
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
    </div>
    """
  end

  defp policy_placeholder("allowed_domains"), do: "api.example.com, api.other.com"
  defp policy_placeholder("allowed_methods"), do: "GET, POST, PUT"
  defp policy_placeholder("allowed_paths"), do: "data/, components/"
  defp policy_placeholder("allowed_actions"), do: "read, write, list, delete, exists"
  defp policy_placeholder("allowed_private_ips"), do: "10.0.0.0/8, 172.16.0.0/12"
  defp policy_placeholder("allowed_tools"), do: "tool1, tool2"
  defp policy_placeholder("rate_limit"), do: ~s({"requests": 100, "window": "1m"})
  defp policy_placeholder("timeout"), do: "3m"
  defp policy_placeholder("max_memory_bytes"), do: "67108864"
  defp policy_placeholder("max_request_size"), do: "1048576"
  defp policy_placeholder("max_response_size"), do: "5242880"
  defp policy_placeholder("max_concurrent_tasks"), do: "10"
  defp policy_placeholder("batch_timeout"), do: "5m"
  defp policy_placeholder(_), do: ""
end
