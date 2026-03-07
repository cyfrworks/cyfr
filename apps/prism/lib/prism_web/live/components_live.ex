defmodule PrismWeb.ComponentsLive do
  use PrismWeb, :live_view

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

  defp policy_fields_for_type(_type, _no_configurable_fields), do: @policy_fields

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Emissary.PubSub, "prism:components")
    end

    {:ok,
     socket
     |> assign(:page_title, "Components")
     # Installed components
     |> assign(:components, [])
     |> assign(:grouped, %{})
     |> assign(:type_filter, nil)
     |> assign(:loading, true)
     # Expanded detail
     |> assign(:expanded_ref, nil)
     |> assign(:expanded_detail, nil)
     |> assign(:expanded_plan, nil)
     |> assign(:expanded_type, nil)
     |> assign(:editing, false)
     |> assign(:secret_inputs, %{})
     |> assign(:policy_inputs, %{})
     |> assign(:policy_prefilled, MapSet.new())
     |> assign(:saving, false)
     |> assign(:publishing, false)
     |> assign(:setup_readiness, %{})
     # Registry search
     |> assign(:search_query, "")
     |> assign(:search_results, nil)
     |> assign(:search_searching, false)
     |> assign(:search_note, nil)
     |> assign(:pulling, MapSet.new())
     |> assign(:pull_results, %{})
     |> assign(:registering, false)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> fetch_components()
     |> assign(:loading, false)}
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
      {:noreply,
       socket
       |> assign(:search_query, query)
       |> assign(:search_searching, true)
       |> assign(:search_note, nil)
       |> do_registry_search(query)}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:search_results, nil)
     |> assign(:search_note, nil)
     |> assign(:pull_results, %{})}
  end

  def handle_event("pull", %{"ref" => ref}, socket) do
    {:noreply,
     socket
     |> assign(:pulling, MapSet.put(socket.assigns.pulling, ref))
     |> do_pull(ref)}
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
    socket = assign(socket, :registering, true)

    socket =
      case call_tool(socket, "component", %{"action" => "register"}) do
        {:ok, result} ->
          total = result[:total] || result["total"] || 0
          registered = result[:registered] || result["registered"] || 0

          socket
          |> fetch_components()
          |> put_flash(:info, "Registered #{registered}/#{total} components")

        {:error, reason} ->
          put_flash(socket, :error, "Register failed: #{inspect(reason)}")
      end

    {:noreply, assign(socket, :registering, false)}
  end

  def handle_event("toggle_expand", %{"ref" => ref}, socket) do
    if socket.assigns.expanded_ref == ref do
      {:noreply, collapse(socket)}
    else
      detail =
        case call_tool(socket, "component/inspect", %{"reference" => ref}) do
          {:ok, result} -> result
          _ -> nil
        end

      plan =
        case call_tool(socket, "component", %{"action" => "setup_plan", "reference" => ref}) do
          {:ok, result} -> result
          _ -> nil
        end

      {:noreply,
       socket
       |> assign(:expanded_ref, ref)
       |> assign(:expanded_detail, detail)
       |> assign(:expanded_plan, plan)
       |> assign(:expanded_type, plan_field(plan, :type))
       |> assign(:editing, false)
       |> assign(:secret_inputs, %{})
       |> assign(:policy_inputs, %{})}
    end
  end

  def handle_event("edit_setup", _params, socket) do
    # Re-fetch fresh plan to pick up any external changes (CLI, other tabs)
    ref = socket.assigns.expanded_ref

    plan =
      case call_tool(socket, "component", %{"action" => "setup_plan", "reference" => ref}) do
        {:ok, result} -> result
        _ -> socket.assigns.expanded_plan
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

    # Pre-fill policy inputs from current or recommended values
    policy_view = merge_policy_view(
      plan_field(plan, :policy_current),
      plan_field(plan, :policy_recommended),
      socket.assigns.expanded_type,
      plan_field(plan, :configurable_fields)
    )

    policy_inputs =
      Enum.reduce(policy_view, %{}, fn {field, _label, type, value, _source}, acc ->
        if value do
          Map.put(acc, field, format_policy_for_edit(value, type))
        else
          acc
        end
      end)

    {:noreply,
     socket
     |> assign(:expanded_plan, plan)
     |> assign(:editing, true)
     |> assign(:secret_inputs, secret_inputs)
     |> assign(:policy_inputs, policy_inputs)
     |> assign(:policy_prefilled, MapSet.new(Map.keys(policy_inputs)))}
  end

  def handle_event("fill_defaults", _params, socket) do
    plan = socket.assigns.expanded_plan
    recommended = plan_field(plan, :policy_recommended) || %{}
    type = socket.assigns.expanded_type
    configurable = plan_field(plan, :configurable_fields)
    fields = policy_fields_for_type(type, configurable)

    {policy_inputs, new_prefilled} =
      Enum.reduce(fields, {socket.assigns.policy_inputs, socket.assigns.policy_prefilled}, fn
        {field, _label, field_type}, {inputs, prefilled} ->
          current_value = inputs[field]
          rec_value = policy_value(recommended, field)

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
     |> assign(:policy_prefilled, MapSet.new())}
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
    ref = socket.assigns.expanded_ref
    socket = assign(socket, :saving, true)

    # Save secrets
    plan = socket.assigns.expanded_plan
    secret_errors =
      socket.assigns.secret_inputs
      |> Enum.reduce([], fn {name, value}, errors ->
        secret_status = Enum.find(plan_field(plan, :secrets) || [], fn s ->
          comp_field(s, :name) == name
        end)
        already_set? = secret_status && comp_field(secret_status, :already_set) == true

        if already_set? do
          # Checkbox mode: grant or skip
          if value == "true" do
            case call_tool(socket, "secret", %{
              "action" => "grant",
              "name" => name,
              "component_ref" => ref
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
            case call_tool(socket, "secret", %{"action" => "set", "name" => name, "value" => value}) do
              {:ok, _} ->
                call_tool(socket, "secret", %{
                  "action" => "grant",
                  "name" => name,
                  "component_ref" => ref
                })
                errors
              {:error, reason} ->
                ["Secret #{name}: #{inspect(reason)}" | errors]
            end
          else
            errors
          end
        end
      end)

    # Save policy fields:
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
              "component_ref" => ref,
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
              "component_ref" => ref,
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
        {:ok, result} -> result
        _ -> socket.assigns.expanded_plan
      end

    readiness =
      Map.put(socket.assigns.setup_readiness, ref, plan_field(plan, :ready) == true)

    socket =
      socket
      |> assign(:saving, false)
      |> assign(:editing, false)
      |> assign(:expanded_plan, plan)
      |> assign(:setup_readiness, readiness)
      |> assign(:secret_inputs, %{})
      |> assign(:policy_inputs, %{})
      |> assign(:policy_prefilled, MapSet.new())

    socket =
      if all_errors == [] do
        put_flash(socket, :info, "Setup saved for #{ref}")
      else
        put_flash(socket, :error, Enum.join(all_errors, "; "))
      end

    {:noreply, socket}
  end

  def handle_event("publish", %{"ref" => ref}, socket) do
    socket = assign(socket, :publishing, true)

    case call_tool(socket, "component", %{"action" => "publish", "reference" => ref}) do
      {:ok, result} ->
        oci_ref = comp_field(result, :oci_reference) || ref

        {:noreply,
         socket
         |> assign(:publishing, false)
         |> put_flash(:info, "Published #{ref} → #{oci_ref}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:publishing, false)
         |> put_flash(:error, "Failed to publish: #{inspect(reason)}")}
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

  # --- PubSub handlers ---

  @impl true
  def handle_info({:policy_changed, metadata, _measurements}, socket) do
    changed_ref = metadata[:component_ref]
    expanded_ref = socket.assigns.expanded_ref

    socket =
      if expanded_ref && !socket.assigns.editing do
        # Re-fetch plan if we're viewing the affected component (or any, since
        # type defaults affect all components of that type)
        plan =
          case call_tool(socket, "component", %{"action" => "setup_plan", "reference" => expanded_ref}) do
            {:ok, result} -> result
            _ -> socket.assigns.expanded_plan
          end

        readiness = Map.put(socket.assigns.setup_readiness, expanded_ref, plan_field(plan, :ready) == true)

        socket
        |> assign(:expanded_plan, plan)
        |> assign(:setup_readiness, readiness)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private helpers ---

  defp collapse(socket) do
    socket
    |> assign(:expanded_ref, nil)
    |> assign(:expanded_detail, nil)
    |> assign(:expanded_plan, nil)
    |> assign(:expanded_type, nil)
    |> assign(:editing, false)
    |> assign(:secret_inputs, %{})
    |> assign(:policy_inputs, %{})
    |> assign(:publishing, false)
  end

  defp do_registry_search(socket, query) do
    args = %{"action" => "search", "query" => query, "limit" => 30}

    case call_tool(socket, "component", args) do
      {:ok, result} ->
        components = result[:components] || result["components"] || []
        note = result[:note] || result["note"]
        components = dedup_search_results(components)

        socket
        |> assign(:search_results, components)
        |> assign(:search_note, note)
        |> assign(:search_searching, false)

      _ ->
        socket
        |> assign(:search_results, [])
        |> assign(:search_searching, false)
    end
  end

  defp dedup_search_results(components) do
    components
    |> Enum.group_by(fn comp ->
      {comp_field(comp, :name), comp_field(comp, :version),
       comp_field(comp, :publisher) || comp_field(comp, :publisher_name)}
    end)
    |> Enum.map(fn {_key, dupes} ->
      Enum.find(dupes, hd(dupes), fn c -> comp_field(c, :component_ref) != nil end)
    end)
  end

  defp do_pull(socket, ref) do
    case call_tool(socket, "component", %{"action" => "pull", "reference" => ref}) do
      {:ok, result} ->
        socket
        |> assign(:pulling, MapSet.delete(socket.assigns.pulling, ref))
        |> assign(:pull_results, Map.put(socket.assigns.pull_results, ref, {:ok, result}))
        |> fetch_components()
        |> put_flash(:info, "Pulled #{ref}")

      {:error, reason} ->
        socket
        |> assign(:pulling, MapSet.delete(socket.assigns.pulling, ref))
        |> assign(:pull_results, Map.put(socket.assigns.pull_results, ref, {:error, reason}))
        |> put_flash(:error, "Failed to pull #{ref}: #{inspect(reason)}")
    end
  end

  defp fetch_components(socket) do
    assigns = socket.assigns
    args = %{"action" => "list", "limit" => 1000}
    args = if assigns.type_filter, do: Map.put(args, "type", assigns.type_filter), else: args

    all_components =
      case call_tool(socket, "component", args) do
        {:ok, %{components: list}} -> list
        {:ok, %{"components" => list}} -> list
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    readiness =
      all_components
      |> Enum.reduce(%{}, fn comp, acc ->
        ref = comp_ref(comp)

        case call_tool(socket, "component", %{"action" => "setup_plan", "reference" => ref}) do
          {:ok, plan} -> Map.put(acc, ref, plan_field(plan, :ready) == true)
          _ -> acc
        end
      end)

    socket
    |> assign(:all_components, all_components)
    |> assign(:setup_readiness, readiness)
    |> collapse()
    |> apply_filter()
  end

  defp apply_filter(socket) do
    all = socket.assigns[:all_components] || []

    grouped =
      all
      |> Enum.group_by(fn c -> c[:component_type] || c["component_type"] || "unknown" end)
      |> Enum.into(%{})

    socket
    |> assign(:components, all)
    |> assign(:grouped, grouped)
  end

  # --- Data helpers ---

  defp search_install_status(comp, installed_refs, installed_digests) do
    ref = comp_ref(comp)

    cond do
      MapSet.member?(installed_refs, ref) ->
        local_digest = Map.get(installed_digests, ref)
        remote_digest = comp_field(comp, :digest)

        if local_digest && remote_digest && local_digest != remote_digest do
          :update_available
        else
          :installed
        end

      comp[:component_ref] || comp["component_ref"] ->
        :installed

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

    base = if publisher && publisher != "local",
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
      source = cond do
        cur != nil -> :current
        rec != nil -> :recommended
        true -> nil
      end
      {field, label, field_type, value, source}
    end)
  end

  defp has_recommended_defaults?(nil), do: false
  defp has_recommended_defaults?(plan) do
    rec = plan_field(plan, :policy_recommended)
    is_map(rec) && rec != %{}
  end

  defp format_policy_display(nil, _type), do: "not configured"
  defp format_policy_display([], :array), do: "not configured"
  defp format_policy_display(value, :array) when is_list(value), do: Enum.join(value, ", ")
  defp format_policy_display(value, :json) when is_map(value), do: Jason.encode!(value)
  defp format_policy_display(value, :bytes) when is_integer(value), do: format_bytes(value)
  defp format_policy_display(value, _type), do: to_string(value)


  defp format_policy_for_edit(value, :array) when is_list(value), do: Enum.join(value, ", ")
  defp format_policy_for_edit(value, :json) when is_map(value), do: Jason.encode!(value)
  defp format_policy_for_edit(value, _type), do: to_string(value)

  defp parse_policy_for_save(value, field) when field in [
    "allowed_domains", "allowed_methods", "allowed_private_ips", "allowed_tools",
    "allowed_paths", "allowed_actions"
  ] do
    # Try JSON array first, fall back to comma-separated
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> Jason.encode!(list)
      _ ->
        value
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Jason.encode!()
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
  defp type_sort_order(_), do: 3

  defp type_label("catalyst"), do: "Catalysts"
  defp type_label("reagent"), do: "Reagents"
  defp type_label("formula"), do: "Formulas"
  defp type_label(type), do: String.capitalize(type)

  defp type_badge_color("catalyst"), do: "bg-purple-900 text-purple-300"
  defp type_badge_color("reagent"), do: "bg-blue-900 text-blue-300"
  defp type_badge_color("formula"), do: "bg-green-900 text-green-300"
  defp type_badge_color(_), do: "bg-gray-800 text-gray-400"

  defp comp_ref(c), do: c[:component_ref] || c["component_ref"] || c[:id] || c["id"] || "-"
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
        <div class="flex items-center justify-between mb-3">
          <h2 class="text-lg font-semibold text-white">Search Registry</h2>
        </div>
        <form phx-submit="search" class="flex items-center gap-2">
          <input
            type="text"
            name="query"
            value={@search_query}
            placeholder="Search for components... (e.g. claude, http, json)"
            class="flex-1 rounded-lg bg-gray-800 border border-gray-700 px-4 py-2.5 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
          />
          <.button type="submit" variant="primary">Search</.button>
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
        <div :if={@search_note} class="mb-3 rounded-lg bg-yellow-900/30 border border-yellow-800/50 px-4 py-2 text-sm text-yellow-300">
          {@search_note}
        </div>

        <div :if={@search_results == []} class="py-6">
          <.empty_state message={"No results for \"#{@search_query}\""} />
        </div>

        <.card :if={@search_results != []}>
          <div class="px-4 py-3 border-b border-gray-800">
            <span class="text-sm text-gray-400">{length(@search_results)} result(s)</span>
          </div>
          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-800 table-fixed">
              <thead>
                <tr>
                  <th class="w-[30%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Reference</th>
                  <th class="w-[10%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Type</th>
                  <th class="w-[35%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Description</th>
                  <th class="w-[12%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Status</th>
                  <th class="w-[13%] px-4 py-3 text-right text-xs font-medium uppercase tracking-wider text-gray-500"></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-800">
                <%= for comp <- @search_results do %>
                  <% pullable_ref = build_search_ref(comp) %>
                  <% status = search_install_status(comp, @installed_refs, @installed_digests) %>
                  <tr class="hover:bg-gray-800/50">
                    <td class="px-4 py-3 text-sm">
                      <span class="text-blue-400 font-mono text-xs">{pullable_ref}</span>
                    </td>
                    <td class="px-4 py-3 text-sm">
                      <span :if={comp_field(comp, :component_type)} class={"inline-flex items-center px-2 py-0.5 rounded text-xs font-medium #{type_badge_color(comp_field(comp, :component_type))}"}>
                        {comp_field(comp, :component_type)}
                      </span>
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-300 truncate max-w-0">
                      {comp_field(comp, :description) || "-"}
                    </td>
                    <td class="px-4 py-3 text-sm">
                      <span :if={status == :installed} class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-900 text-green-300">
                        Installed
                      </span>
                      <span :if={status == :update_available} class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-yellow-900 text-yellow-300">
                        Update
                      </span>
                    </td>
                    <td class="px-4 py-3 text-right">
                      <.button
                        :if={status == :not_installed && !MapSet.member?(@pulling, pullable_ref)}
                        variant="primary"
                        class="text-xs px-3 py-1"
                        phx-click="pull"
                        phx-value-ref={pullable_ref}
                      >
                        Pull
                      </.button>
                      <.button
                        :if={status == :update_available && !MapSet.member?(@pulling, pullable_ref)}
                        variant="primary"
                        class="text-xs px-3 py-1"
                        phx-click="pull"
                        phx-value-ref={pullable_ref}
                      >
                        Update
                      </.button>
                      <span :if={MapSet.member?(@pulling, pullable_ref)} class="text-xs text-gray-400">
                        Pulling...
                      </span>
                      <span :if={status == :installed} class="text-xs text-gray-500">
                        Up to date
                      </span>
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

      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading && @components == []} class="py-8">
        <.empty_state message="No components found" />
      </div>

      <!-- Grouped component tables -->
      <div :if={!@loading && @components != []} class="space-y-6">
        <section :for={{type, comps} <- @sorted_groups}>
          <div class="flex items-center gap-2 mb-3">
            <h3 class="text-sm font-semibold text-white">{type_label(type)}</h3>
            <span class={"inline-flex items-center px-2 py-0.5 rounded text-xs font-medium #{type_badge_color(type)}"}>
              {length(comps)}
            </span>
          </div>
          <.card>
            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-800 table-fixed">
                <thead>
                  <tr>
                    <th class="w-[35%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Reference</th>
                    <th class="w-[45%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Description</th>
                    <th class="w-[20%] px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Version</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-800">
                  <%= for comp <- comps do %>
                    <% ref = comp_ref(comp) %>
                    <tr
                      phx-click="toggle_expand"
                      phx-value-ref={ref}
                      class={"cursor-pointer transition-colors #{if @expanded_ref == ref, do: "bg-gray-800/80", else: "hover:bg-gray-800/50"}"}
                    >
                      <td class="px-4 py-3 text-sm whitespace-nowrap">
                        <span class="inline-flex items-center gap-1.5">
                          <span class={"inline-block w-2 h-2 rounded-full #{if @setup_readiness[ref] == true, do: "bg-green-500", else: "bg-red-500"}"} />
                          <span class="text-blue-400 font-mono text-xs">{ref}</span>
                        </span>
                      </td>
                      <td class="px-4 py-3 text-sm text-gray-300 truncate max-w-0">
                        {comp_field(comp, :description) || "-"}
                      </td>
                      <td class="px-4 py-3 text-sm text-gray-400 whitespace-nowrap">
                        {comp_field(comp, :version) || "-"}
                      </td>
                    </tr>
                    <!-- Expanded detail row -->
                    <tr :if={@expanded_ref == ref} class="bg-gray-900/60">
                      <td colspan="3" class="px-4 py-4">
                        <div :if={@expanded_detail} class="space-y-4">
                          <!-- Component metadata -->
                          <dl class="grid grid-cols-2 md:grid-cols-4 gap-3">
                            <div>
                              <dt class="text-xs text-gray-500 uppercase">Name</dt>
                              <dd class="text-sm text-white mt-0.5">{comp_field(@expanded_detail, :name) || "-"}</dd>
                            </div>
                            <div>
                              <dt class="text-xs text-gray-500 uppercase">Publisher</dt>
                              <dd class="text-sm text-white mt-0.5">{comp_field(@expanded_detail, :publisher) || "-"}</dd>
                            </div>
                            <div>
                              <dt class="text-xs text-gray-500 uppercase">Size</dt>
                              <dd class="text-sm text-white mt-0.5">{format_bytes(comp_field(@expanded_detail, :size))}</dd>
                            </div>
                            <div>
                              <dt class="text-xs text-gray-500 uppercase">Digest</dt>
                              <dd class="text-sm text-white mt-0.5 font-mono text-xs truncate" title={comp_field(@expanded_detail, :digest) || ""}>
                                {comp_field(@expanded_detail, :digest) |> to_string() |> String.slice(0..15)}...
                              </dd>
                            </div>
                          </dl>

                          <!-- Description -->
                          <div :if={comp_field(@expanded_detail, :description)}>
                            <h4 class="text-xs font-medium text-gray-400 mb-1">Description</h4>
                            <p class="text-sm text-gray-300">{comp_field(@expanded_detail, :description)}</p>
                          </div>

                          <!-- Tags -->
                          <div :if={is_list(comp_field(@expanded_detail, :tags)) && comp_field(@expanded_detail, :tags) != []}>
                            <h4 class="text-xs font-medium text-gray-400 mb-1">Tags</h4>
                            <div class="flex flex-wrap gap-1">
                              <span
                                :for={tag <- comp_field(@expanded_detail, :tags)}
                                class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-gray-800 text-gray-300"
                              >
                                {tag}
                              </span>
                            </div>
                          </div>

                          <!-- Setup section -->
                          <div class="border-t border-gray-800 pt-4">
                            <div class="flex items-center justify-between mb-3">
                              <div class="flex items-center gap-2">
                                <h4 class="text-xs font-semibold text-gray-400 uppercase">Setup</h4>
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
                              <div class="flex items-center gap-2">
                                <.button
                                  :if={@editing && has_recommended_defaults?(@expanded_plan)}
                                  variant="ghost"
                                  class="text-xs px-3 py-1"
                                  phx-click="fill_defaults"
                                >
                                  Fill Defaults
                                </.button>
                                <.button
                                  :if={@editing}
                                  variant="ghost"
                                  class="text-xs px-3 py-1"
                                  phx-click="cancel_edit"
                                >
                                  Cancel
                                </.button>
                                <.button
                                  :if={@editing}
                                  variant="primary"
                                  class="text-xs px-3 py-1"
                                  phx-click="save_setup"
                                >
                                  {if @saving, do: "Saving...", else: "Save"}
                                </.button>
                              </div>
                            </div>

                            <!-- No manifest -->
                            <div :if={!@expanded_plan} class="text-sm text-gray-500 p-4">
                              No setup manifest found for this component.
                            </div>

                            <!-- Edit mode -->
                            <form :if={@expanded_plan && @editing} phx-change="setup_change" phx-submit="save_setup">
                              <div class="grid grid-cols-1 md:grid-cols-2 gap-6 p-4">
                                <dl class="space-y-4">
                                  <!-- Secrets -->
                                  <%= for secret <- plan_field(@expanded_plan, :secrets) || [] do %>
                                    <% secret_name = comp_field(secret, :name) %>
                                    <% {status_text, status_class} = secret_status_class(secret) %>
                                    <div>
                                      <dt class="text-xs text-gray-500 uppercase flex items-center gap-2">
                                        {secret_name}
                                        <span :if={comp_field(secret, :required)} class="text-red-400 normal-case">required</span>
                                        <span class={"inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium normal-case #{status_class}"}>
                                          {status_text}
                                        </span>
                                        <span :if={comp_field(secret, :description)} class="relative group/tip cursor-help normal-case">
                                          <svg xmlns="http://www.w3.org/2000/svg" class="h-3.5 w-3.5 text-gray-500 group-hover/tip:text-gray-300" viewBox="0 0 20 20" fill="currentColor">
                                            <path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clip-rule="evenodd" />
                                          </svg>
                                          <span class="absolute bottom-full left-1/2 -translate-x-1/2 mb-1.5 hidden group-hover/tip:block whitespace-nowrap rounded bg-gray-700 px-2 py-1 text-xs text-gray-200 shadow-lg z-10">
                                            {comp_field(secret, :description)}
                                          </span>
                                        </span>
                                      </dt>
                                      <dd class="mt-1">
                                        <%= if comp_field(secret, :already_set) == true do %>
                                          <label class="flex items-center gap-2 cursor-pointer">
                                            <input type="hidden" name={"secret[#{secret_name}]"} value="false" />
                                            <input
                                              type="checkbox"
                                              name={"secret[#{secret_name}]"}
                                              value="true"
                                              checked={@secret_inputs[secret_name] == "true"}
                                              class="h-4 w-4 rounded border-gray-600 bg-gray-900 text-blue-500 focus:ring-blue-500 focus:ring-offset-0"
                                            />
                                            <span class="text-sm text-gray-300">Grant to this component</span>
                                          </label>
                                        <% else %>
                                          <input
                                            type="password"
                                            name={"secret[#{secret_name}]"}
                                            value={@secret_inputs[secret_name] || ""}
                                            placeholder={comp_field(secret, :description) || "Enter value..."}
                                            phx-debounce="blur"
                                            class="w-full rounded bg-gray-900 border border-gray-700 px-3 py-1.5 text-sm text-white placeholder-gray-600 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                                          />
                                        <% end %>
                                      </dd>
                                    </div>
                                  <% end %>

                                  <!-- Policy left column -->
                                  <% all_fields = merge_policy_view(
                                    plan_field(@expanded_plan, :policy_current),
                                    plan_field(@expanded_plan, :policy_recommended),
                                    @expanded_type,
                                    plan_field(@expanded_plan, :configurable_fields)
                                  ) %>
                                  <% {left, right} = Enum.split(all_fields, div(length(all_fields) + 1, 2)) %>
                                  <%= for {field, label, _type, _value, _source} <- left do %>
                                    <div>
                                      <dt class="text-xs text-gray-500 uppercase">{label}</dt>
                                      <dd class="mt-1">
                                        <input
                                          type="text"
                                          name={"policy[#{field}]"}
                                          value={@policy_inputs[field] || ""}
                                          placeholder={policy_placeholder(field)}
                                          phx-debounce="blur"
                                          class="w-full rounded bg-gray-900 border border-gray-700 px-3 py-1.5 text-sm text-white placeholder-gray-600 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                                        />
                                      </dd>
                                    </div>
                                  <% end %>
                                </dl>
                                <dl class="space-y-4">
                                  <!-- Policy right column -->
                                  <%= for {field, label, _type, _value, _source} <- right do %>
                                    <div>
                                      <dt class="text-xs text-gray-500 uppercase">{label}</dt>
                                      <dd class="mt-1">
                                        <input
                                          type="text"
                                          name={"policy[#{field}]"}
                                          value={@policy_inputs[field] || ""}
                                          placeholder={policy_placeholder(field)}
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
                            <div :if={@expanded_plan && !@editing}>
                              <div class="grid grid-cols-1 md:grid-cols-2 gap-6 p-4">
                                <dl class="space-y-4">
                                  <!-- Secrets -->
                                  <%= for secret <- plan_field(@expanded_plan, :secrets) || [] do %>
                                    <% {status_text, status_class} = secret_status_class(secret) %>
                                    <div>
                                      <dt class="text-xs text-gray-500 uppercase flex items-center gap-2">
                                        {comp_field(secret, :name)}
                                        <span :if={comp_field(secret, :required)} class="text-red-400 normal-case">required</span>
                                        <span :if={comp_field(secret, :description)} class="relative group/tip cursor-help normal-case">
                                          <svg xmlns="http://www.w3.org/2000/svg" class="h-3.5 w-3.5 text-gray-500 group-hover/tip:text-gray-300" viewBox="0 0 20 20" fill="currentColor">
                                            <path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clip-rule="evenodd" />
                                          </svg>
                                          <span class="absolute bottom-full left-1/2 -translate-x-1/2 mb-1.5 hidden group-hover/tip:block whitespace-nowrap rounded bg-gray-700 px-2 py-1 text-xs text-gray-200 shadow-lg z-10">
                                            {comp_field(secret, :description)}
                                          </span>
                                        </span>
                                      </dt>
                                      <dd class="text-sm text-white mt-1 flex items-center gap-2">
                                        <span class={"inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium #{status_class}"}>
                                          {status_text}
                                        </span>
                                      </dd>
                                    </div>
                                  <% end %>

                                  <!-- Policy left column -->
                                  <% {left_view, right_view} = Enum.split(@policy_view, div(length(@policy_view) + 1, 2)) %>
                                  <%= for {_field, label, type, value, source} <- left_view do %>
                                    <div>
                                      <dt class="text-xs text-gray-500 uppercase">{label}</dt>
                                      <dd class={"text-sm mt-1 #{if source == :recommended, do: "text-gray-400 italic", else: "text-white"}"} title={if source == :recommended, do: "Recommended by manifest", else: ""}>
                                        <%= if is_list(value) && value != [] do %>
                                          <div class="flex flex-wrap gap-1">
                                            <.badge :for={item <- value} color={badge_color_for(label)}>{item}</.badge>
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
                                      <dd class={"text-sm mt-1 #{if source == :recommended, do: "text-gray-400 italic", else: "text-white"}"} title={if source == :recommended, do: "Recommended by manifest", else: ""}>
                                        <%= if is_list(value) && value != [] do %>
                                          <div class="flex flex-wrap gap-1">
                                            <.badge :for={item <- value} color={badge_color_for(label)}>{item}</.badge>
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
                            <div :if={@expanded_plan && (plan_field(@expanded_plan, :dependencies) || []) != []} class="px-4 pb-4">
                              <dt class="text-xs text-gray-500 uppercase mb-1">Dependencies</dt>
                              <dd class="flex flex-wrap gap-1">
                                <.badge :for={dep <- plan_field(@expanded_plan, :dependencies) || []} color="blue">
                                  {comp_field(dep, :ref)}
                                </.badge>
                              </dd>
                            </div>
                          </div>

                          <!-- Action buttons -->
                          <div class="border-t border-gray-800 pt-4 flex items-center justify-end gap-2">
                            <.button
                              :if={!@editing && @expanded_plan}
                              variant="secondary"
                              phx-click="edit_setup"
                            >
                              Edit
                            </.button>
                            <.button
                              :if={comp_field(@expanded_detail, :publisher) == "local" && !@publishing}
                              variant="primary"
                              phx-click="publish"
                              phx-value-ref={ref}
                              data-confirm={"Publish #{ref} to registry?"}
                            >
                              Publish
                            </.button>
                            <span :if={@publishing} class="text-sm text-blue-400">Publishing...</span>
                            <.button
                              variant="danger"
                              phx-click="remove"
                              phx-value-ref={ref}
                              data-confirm={"Remove #{ref}?"}
                            >
                              Remove
                            </.button>
                          </div>
                        </div>
                        <div :if={!@expanded_detail} class="text-center text-gray-500 py-4 text-sm">Loading...</div>
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
