# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ComponentDetailLive do
  @moduledoc """
  One component: what it is, a run of it, its grants, its README and its
  dependencies, and for a catalyst its permissions.

  The permissions are the actions the component's manifest says it asks
  about before doing them (`asks`, read from the registry row's manifest,
  `Prima.Manifest.Asks`), worded as the developer's claim, each with the
  person's answers that stand for it (`question.answers`). A person sets
  one before any question has asked (`question.set`), for anyone who
  starts it or for a caller its questions have had, changes it by setting
  it again, and removes it (`question.forget`). An allow given under a
  title the component has since reworded is marked: it no longer covers
  the action, which asks again. An answer for an action the component no
  longer declares is listed apart, to be removed. Allowing an action
  always, for anyone, needs a fresh confirmation: the page asks for it
  through its system layer (`PrismWeb.SystemLayer.call/5`) and sets the
  answer again, once, when it is confirmed.
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  alias Prima.Manifest.Asks
  alias PrismWeb.SystemLayer
  alias PrismWeb.SystemLayer.Question

  require Logger

  # How long a permission set "for an hour" lasts.
  @hour_s 3600

  @impl true
  def mount(%{"ref" => ref}, _session, socket) do
    if connected?(socket) do
      actor = Sanctum.Context.actor(socket.assigns[:context])
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.components(actor))
    end

    {:ok,
     socket
     |> assign(:page_title, "Component: #{ref}")
     |> assign(:ref, ref)
     |> assign(:component, nil)
     |> assign(:readme, nil)
     |> assign(:input, "")
     |> assign(:run, nil)
     |> assign(:run_error, nil)
     |> assign(:permissions, nil)
     |> assign(:permission_error, nil)
     |> assign(:loading, true)}
  end

  # `component.inspect` answers string keys
  # (`Compendium.Component.inspect_component/2`), its README among them.
  @impl true
  def handle_params(%{"ref" => ref}, _uri, socket) do
    component =
      case call_tool(socket, "component/inspect", %{
             "reference" => ref,
             "include_readme" => true
           }) do
        {:ok, comp} ->
          comp

        other ->
          Logger.warning("[ComponentDetailLive] component/inspect failed: #{inspect(other)}")
          nil
      end

    readme = extract_readme(component)

    {:noreply,
     socket
     |> assign(:component, component)
     |> assign(:readme, readme)
     |> assign(:loading, false)
     |> load_permissions()}
  end

  # A catalyst's declared actions and the person's answers that stand for
  # them; nothing for any other component, or one that declares none and
  # keeps none.
  defp load_permissions(%{assigns: %{component: %{"type" => "catalyst"} = component}} = socket) do
    with {:ok, %{namespace: publisher, name: name}} <-
           Prima.ComponentRef.parse(socket.assigns.ref),
         {:ok, manifest} <- Prima.Manifest.decode_strict(component["manifest"]),
         {:ok, %{answers: answers, callers: callers}} <-
           call_tool(socket, "question/answers", %{"publisher" => publisher, "name" => name}) do
      declared = Asks.from_manifest(manifest)

      permissions =
        if declared == [] and answers == [],
          do: nil,
          else: %{
            publisher: publisher,
            name: name,
            declared: declared,
            answers: answers,
            callers: Enum.reject(callers, &(&1 == Prima.Question.Caller.encode(:unknown)))
          }

      assign(socket, :permissions, permissions)
    else
      _unread -> assign(socket, :permissions, nil)
    end
  end

  defp load_permissions(socket), do: assign(socket, :permissions, nil)

  defp extract_readme(nil), do: nil

  defp extract_readme(comp) do
    case comp["readme"] do
      r when is_binary(r) and r != "" -> r
      _ -> nil
    end
  end

  # The run form's input is JSON, an object, as `execution.run` declares
  # it; an empty form runs with none. Input that is not an object is told
  # here and runs nothing. A run that completes shows its result on the
  # page; the run is also on Executions.
  @impl true
  def handle_event("execute", %{"input" => input}, socket) do
    socket = assign(socket, :input, input)

    case run_input(input) do
      {:ok, run_input} ->
        args = Map.merge(%{"reference" => socket.assigns.ref}, run_input)

        case call_tool(socket, "execution/run", args) do
          {:ok, %{execution_id: _id} = run} ->
            {:noreply, socket |> assign(:run, run) |> assign(:run_error, nil)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:run, nil)
             |> assign(:run_error, "The run failed: #{error_message(reason)}")}
        end

      {:error, sentence} ->
        {:noreply, socket |> assign(:run, nil) |> assign(:run_error, sentence)}
    end
  end

  # A permission set from the page: for anyone or a caller its questions
  # have had, allowed or never, always or for an hour.
  def handle_event(
        "set_permission",
        %{"action_name" => action, "effect" => effect, "caller" => caller, "lasts" => lasts},
        socket
      )
      when effect in ["allow", "deny"] and lasts in ["always", "hour"] do
    case socket.assigns.permissions do
      %{publisher: publisher, name: name} ->
        until =
          if lasts == "hour",
            do:
              DateTime.utc_now()
              |> DateTime.add(@hour_s, :second)
              |> DateTime.truncate(:second)
              |> DateTime.to_iso8601()

        set_permission(socket, %{
          "publisher" => publisher,
          "name" => name,
          "action_name" => action,
          "standing" => %{"effect" => effect, "until" => until, "caller" => caller}
        })

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("forget_permission", %{"id" => id}, socket) do
    case call_tool(socket, "question/forget", %{"id" => id}) do
      {:ok, _forgotten} ->
        {:noreply, socket |> assign(:permission_error, nil) |> load_permissions()}

      {:error, reason} ->
        {:noreply, assign(socket, :permission_error, error_message(reason))}
    end
  end

  def handle_event("open_report", _params, socket) do
    PrismWeb.ReportComponent.open("report", socket.assigns.ref)
    {:noreply, socket}
  end

  # Allowing an action always for anyone waits for a fresh confirmation,
  # and is set again from `system_layer_repeat/4` once confirmed.
  defp set_permission(socket, args) do
    case SystemLayer.call(socket, {:question_set, args["action_name"]}, "question/set", args) do
      {:ok, _set, socket} ->
        {:noreply, socket |> assign(:permission_error, nil) |> load_permissions()}

      {:asked, socket} ->
        {:noreply, assign(socket, :permission_error, nil)}

      {:error, reason, socket} ->
        {:noreply, assign(socket, :permission_error, error_message(reason))}
    end
  end

  # A permission this page asked for was confirmed: set again, once.
  @impl PrismWeb.SystemLayer.Hook
  def system_layer_repeat({:question_set, _action}, _tool, args, socket),
    do: set_permission(socket, args)

  @impl true
  def handle_info(%Cyfr.Bus.Components{}, socket) do
    ref = socket.assigns.ref

    component =
      case call_tool(socket, "component/inspect", %{"reference" => ref}) do
        {:ok, comp} -> comp
        _ -> socket.assigns.component
      end

    {:noreply, assign(socket, :component, component)}
  end

  def handle_info({:report_component, :submitted}, socket) do
    {:noreply, put_flash(socket, :info, "Report submitted. Thanks.")}
  end

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  defp run_input(input) do
    case String.trim(input) do
      "" ->
        {:ok, %{}}

      text ->
        case Jason.decode(text) do
          {:ok, %{} = object} ->
            {:ok, %{"input" => object}}

          {:ok, _other} ->
            {:error,
             "The input must be a JSON object, such as {\"url\": \"https://example.com\"}."}

          {:error, _invalid} ->
            {:error, "The input is not valid JSON."}
        end
    end
  end

  defp result_json(result), do: Jason.encode!(result, pretty: true)

  # The grants are a component's, whatever version the page shows.
  defp name_ref(ref) do
    case Prima.ComponentRef.to_name_ref(ref) do
      {:ok, name_ref} -> name_ref
      _unparsed -> ref
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <a
            href={PrismWeb.Focus.path(@athanor_route, "/components")}
            class="text-sm text-gray-500 hover:text-gray-300"
          >
            &larr; Back to Components
          </a>
          <h2 class="text-lg font-semibold text-white mt-1">{@ref}</h2>
        </div>
        <button
          :if={!@loading && @component}
          phx-click="open_report"
          class="shrink-0 px-3 py-1.5 text-xs rounded border border-gray-700 bg-gray-800 text-gray-300 hover:bg-red-900/40 hover:text-red-200 hover:border-red-800"
          title="Report this component to the registry's moderators"
        >
          Report
        </button>
      </div>

      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading && @component} class="space-y-6">
        <!-- Metadata -->
        <.card>
          <dl class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div>
              <dt class="text-xs text-gray-500 uppercase">Name</dt>
              <dd class="text-sm text-white mt-1">
                {@component["name"] || "-"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Version</dt>
              <dd class="text-sm text-white mt-1">
                {@component["version"] || "-"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Category</dt>
              <dd class="text-sm text-white mt-1">
                {@component["category"] || "-"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Language</dt>
              <dd class="text-sm text-white mt-1">
                {@component["language"] || "-"}
              </dd>
            </div>
          </dl>
        </.card>

        <!-- Description -->
        <.card :if={@component["description"]}>
          <h3 class="text-sm font-medium text-gray-400 mb-2">Description</h3>
          <p class="text-sm text-gray-300">
            {@component["description"]}
          </p>
        </.card>

        <!-- Run -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-3">Run</h3>
          <form id="run-form" phx-submit="execute" class="space-y-3">
            <textarea
              name="input"
              rows="4"
              placeholder="Input as JSON (optional), such as {&quot;url&quot;: &quot;https://example.com&quot;}"
              class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 font-mono text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
            >{@input}</textarea>
            <.button type="submit">Run</.button>
          </form>
          <p :if={@run_error} id="run-error" class="mt-3 text-sm text-red-300">{@run_error}</p>
          <div :if={@run} id="run-result" class="mt-4 space-y-2">
            <p class="text-sm text-gray-300">
              {String.capitalize(to_string(@run[:status]))}
              <span :if={@run[:duration_ms]} class="text-gray-500">in {@run[:duration_ms]} ms</span>
              ·
              <.link
                navigate={PrismWeb.Focus.path(@athanor_route, "/executions")}
                class="text-blue-400 hover:underline"
              >run {@run.execution_id}</.link>
            </p>
            <pre class="max-h-96 overflow-auto rounded bg-gray-950 p-3 text-xs text-gray-200 whitespace-pre-wrap">{result_json(@run[:result])}</pre>
          </div>
        </.card>

        <!-- Grants -->
        <.card>
          <.live_component
            module={PrismWeb.GrantsComponent}
            id="grants"
            ref={name_ref(@ref)}
            context={@context}
          />
        </.card>

        <!-- Permissions -->
        <.card :if={@permissions}>
          <.permissions permissions={@permissions} error={@permission_error} />
        </.card>

        <!-- README -->
        <.card :if={@readme}>
          <h3 class="text-sm font-medium text-gray-400 mb-2">README</h3>
          <div class="prose prose-invert prose-sm max-w-none">
            <pre class="text-xs text-gray-300 whitespace-pre-wrap">{@readme}</pre>
          </div>
        </.card>

        <!-- Dependencies -->
        <.card :if={@component["dependencies"]}>
          <h3 class="text-sm font-medium text-gray-400 mb-2">Dependencies</h3>
          <.dependencies nodes={@component["dependencies"]} />
        </.card>
      </div>

      <div :if={!@loading && !@component}>
        <.empty_state message="Component not found" />
      </div>

      <.live_component module={SystemLayer} id={SystemLayer.layer_id()} context={@context} />

      <!-- Report modal — the shared component owns taxonomy, validation and submit -->
      <.live_component
        module={PrismWeb.ReportComponent}
        id="report"
        context={@context}
        athanor_route={@athanor_route}
      />
    </div>
    """
  end

  attr :permissions, :map, required: true
  attr :error, :string, default: nil

  # Each declared action with the person's answers for it and a way to set
  # one; then the answers for actions it no longer declares.
  defp permissions(assigns) do
    names = MapSet.new(assigns.permissions.declared, & &1.name)

    assigns =
      assign(assigns,
        retired: Enum.reject(assigns.permissions.answers, &MapSet.member?(names, &1.action))
      )

    ~H"""
    <section id="permissions" class="space-y-4" data-test="permissions">
      <div>
        <h3 class="text-sm font-medium text-gray-400">Permissions</h3>
        <p class="mt-1 text-sm text-gray-400">
          The developer says {@permissions.name} asks you before each of these. An answer
          that lasts is kept here, where you can change or remove it.
        </p>
      </div>

      <p :if={@error} role="alert" class="text-sm text-red-300" data-test="permission-error">
        {@error}
      </p>

      <div
        :for={action <- @permissions.declared}
        class="space-y-2 rounded border border-gray-800 p-3"
        data-test="permission"
        data-action={action.name}
      >
        <p class="text-sm text-white">{@permissions.name} wants to {action.title}</p>
        <.answers
          answers={for a <- @permissions.answers, a.action == action.name, do: a}
          declared={action}
        />
        <form
          phx-submit="set_permission"
          class="flex flex-wrap items-center gap-2 text-sm"
          data-test="permission-set"
        >
          <input type="hidden" name="action_name" value={action.name} />
          <select name="effect" class="rounded bg-gray-800 px-2 py-1 text-white">
            <option value="allow">Allow</option>
            <option value="deny">Never allow</option>
          </select>
          <select name="caller" class="rounded bg-gray-800 px-2 py-1 text-white">
            <option value="any">when anyone starts it</option>
            <option :for={caller <- @permissions.callers} value={caller}>
              {when_words(caller)}
            </option>
          </select>
          <select name="lasts" class="rounded bg-gray-800 px-2 py-1 text-white">
            <option value="always">always</option>
            <option value="hour">for an hour</option>
          </select>
          <.button type="submit">Set</.button>
        </form>
      </div>

      <div :if={@retired != []} class="space-y-2" data-test="permissions-retired">
        <p class="text-sm text-gray-400">
          {@permissions.name} no longer asks about these, so these answers cover nothing.
        </p>
        <.answers answers={@retired} declared={nil} />
      </div>
    </section>
    """
  end

  attr :answers, :list, required: true
  attr :declared, :any, default: nil

  defp answers(assigns) do
    ~H"""
    <p :if={@answers == []} class="text-xs text-gray-500" data-test="permission-none">
      No answer is kept. It asks you each time.
    </p>
    <ul :if={@answers != []} class="space-y-1">
      <li
        :for={answer <- @answers}
        class="flex flex-wrap items-center gap-2 text-sm text-gray-300"
        data-test="permission-answer"
        data-id={answer.id}
        data-caller={answer.caller}
        data-effect={answer.effect}
      >
        <span>{answer_words(answer)}</span>
        <span
          :if={reworded?(answer, @declared)}
          class="text-xs text-amber-300"
          data-test="permission-reworded"
        >
          The action was reworded since, so it asks again.
        </span>
        <button
          type="button"
          phx-click="forget_permission"
          phx-value-id={answer.id}
          data-test="permission-forget"
          class="text-xs text-blue-300 underline underline-offset-2 hover:text-blue-200"
        >
          Remove
        </button>
      </li>
    </ul>
    """
  end

  # A standing answer as the person reads it.
  defp answer_words(%{effect: effect, caller: caller, until: until}) do
    verb = if effect == "allow", do: "Allowed", else: "Never allowed"
    "#{verb} #{when_words(caller)}, #{lasts_words(until)}"
  end

  # Who an answer is for, as a clause: "when you start it", "when the
  # assistant Aqua starts it".
  defp when_words("person"), do: "when you start it"
  defp when_words(caller), do: "when #{Question.caller_words(caller)} starts it"

  defp lasts_words(nil), do: "always"
  defp lasts_words(%DateTime{} = until), do: "until #{Question.until(until)}"

  defp lasts_words(until) when is_binary(until) do
    case DateTime.from_iso8601(until) do
      {:ok, at, _offset} -> lasts_words(at)
      _unread -> "until #{until}"
    end
  end

  # An allow given under a title the action no longer has: it covers
  # nothing, and the component asks again. A deny stays whatever the title.
  defp reworded?(%{effect: "allow", declaration_digest: digest}, %{} = declared),
    do: digest != Asks.digest(declared)

  defp reworded?(_answer, _declared), do: false

  # The inspection's dependencies are a tree of nodes
  # (`Compendium.DependencyResolver.resolve_tree/3`): each names its ref,
  # whether it is optional, whether it closes a cycle, and its children.
  attr :nodes, :list, required: true

  defp dependencies(assigns) do
    ~H"""
    <ul class="space-y-1">
      <li :for={node <- @nodes} class="text-sm text-gray-300">
        <span class="font-mono">{node.dependency_ref}</span>
        <span :if={node.optional} class="text-xs text-gray-500">optional</span>
        <span :if={node.cycle} class="text-xs text-gray-500">cycle</span>
        <div :if={node.children != []} class="ml-4 mt-1">
          <.dependencies nodes={node.children} />
        </div>
      </li>
    </ul>
    """
  end
end
