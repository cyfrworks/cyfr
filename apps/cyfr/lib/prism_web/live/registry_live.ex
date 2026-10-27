# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RegistryLive do
  @moduledoc """
  Lists components you've published to cyfr.run and lets you manage them
  (deprecate, yank). Unlike `ComponentsLive` — which shows components
  *installed locally* on this machine — this view is strictly the remote
  namespace state owned by the current user.

  Sources:
    * Personal namespace — from `@personal_namespace_slug` (set by `PrismWeb.Focus`).
    * Publisher memberships — fetched via `registry.whoami` MCP action.

  For each owned namespace we call `component.discover` (which hits
  `/v1/components?namespace=<slug>` on cyfr.run) and merge results into a
  single flat list, keyed by `{namespace, type, name, version}`.

  The person's registry acts here are each a request their identity signs
  (`registry.sync`, `registry.legal_accept`, `registry.appeal`); no
  identity provider is asked. A sync mints push tokens, so it is asked
  through the system layer (`PrismWeb.SystemLayer.call/5`): a session
  alone is answered `confirmation_required`, which the layer shows, and
  the page repeats the sync once it is confirmed.
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  alias Phoenix.LiveView.JS
  alias PrismWeb.SystemLayer
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    # Render instantly with the sidebar highlighted + a spinner in the main
    # panel, then trigger the load as a separate message so the first paint
    # doesn't block on the cyfr.run round-trip. The load handler below
    # flips `:loading` to false and fills `:components`.
    if connected?(socket) do
      actor = Sanctum.Context.actor(socket.assigns[:context])
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.components(actor))
      send(self(), :load_registry)
    end

    {:ok,
     socket
     |> assign(:page_title, "My Registry")
     |> assign(:active_nav, "registry")
     |> assign(:namespaces, [])
     |> assign(:components, [])
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> assign(:deprecate_pending, nil)
     |> assign(:yank_pending, nil)
     |> assign(:policy, nil)
     |> assign_appeal_idle()}
  end

  defp assign_appeal_idle(socket) do
    socket
    |> assign(:appeal_pending, nil)
    |> assign(:appeal_argument, "")
    |> assign(:appeal_error, nil)
  end

  # A sync this page asked for was confirmed: asked again, once.
  @impl PrismWeb.SystemLayer.Hook
  def system_layer_repeat(:sync, _tool, _args, socket), do: {:noreply, sync(socket)}

  @impl true
  def handle_event("open-deprecate", %{"reference" => reference}, socket) do
    {:noreply, assign(socket, :deprecate_pending, reference)}
  end

  def handle_event("close-deprecate", _params, socket) do
    {:noreply, assign(socket, :deprecate_pending, nil)}
  end

  def handle_event("open-yank", %{"reference" => reference}, socket) do
    {:noreply, assign(socket, :yank_pending, reference)}
  end

  def handle_event("close-yank", _params, socket) do
    {:noreply, assign(socket, :yank_pending, nil)}
  end

  # ---- Appeal flow ----
  # An appeal of a takedown is a request the person's identity signs
  # (`registry.appeal`); the registry binds it to the action's rightful
  # appellant by that identity.
  def handle_event("open-appeal", %{"id" => id}, socket) do
    {:noreply, socket |> assign_appeal_idle() |> assign(:appeal_pending, id)}
  end

  def handle_event("close-appeal", _params, socket) do
    {:noreply, assign_appeal_idle(socket)}
  end

  def handle_event("submit-appeal", params, socket) do
    argument = params |> Map.get("argument", "") |> String.trim()
    component_id = socket.assigns.appeal_pending

    cond do
      argument == "" ->
        {:noreply, assign(socket, :appeal_error, "Argument is required.")}

      byte_size(argument) > 4000 ->
        {:noreply, assign(socket, :appeal_error, "Argument exceeds 4000 bytes.")}

      true ->
        args = %{
          "action_type" => "takedown",
          "action_ref" => component_id,
          "argument" => argument
        }

        case call_tool(socket, "registry/appeal", args) do
          {:ok, _answer} ->
            {:noreply,
             socket
             |> put_flash(:info, "Appeal filed for #{component_id}. Moderators will review.")
             |> assign_appeal_idle()}

          {:error, err} ->
            {:noreply,
             socket
             |> assign(:appeal_argument, argument)
             |> assign(:appeal_error, "Submit failed: #{error_message(err)}")}
        end
    end
  end

  # ---- Push tokens and the registry's policies ----
  def handle_event("sync", _params, socket), do: {:noreply, sync(socket)}

  def handle_event("accept-policy", %{"version" => version}, socket) when is_binary(version) do
    case call_tool(socket, "registry/legal_accept", %{"policy_version" => version}) do
      {:ok, _answer} ->
        {:noreply,
         socket
         |> put_flash(:info, "Accepted the registry's policies (version #{version}).")
         |> load_policy()}

      {:error, err} ->
        {:noreply, put_flash(socket, :error, "Accepting failed: #{error_message(err)}")}
    end
  end

  def handle_event("deprecate", %{"reason" => reason} = params, socket) do
    reference = params["reference"] || socket.assigns[:deprecate_pending]
    reason = String.trim(reason)

    cond do
      !is_binary(reference) or reference == "" ->
        {:noreply, put_flash(socket, :error, "No component selected for deprecation.")}

      reason == "" ->
        {:noreply, put_flash(socket, :error, "Deprecate requires a reason.")}

      true ->
        case call_tool(socket, "component/deprecate", %{
               "reference" => reference,
               "reason" => reason
             }) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Deprecated #{reference}.")
             |> assign(:deprecate_pending, nil)
             |> load_registry()}

          {:error, err} ->
            {:noreply, put_flash(socket, :error, "Deprecate failed: #{error_message(err)}")}
        end
    end
  end

  def handle_event("yank", params, socket) do
    reference = params["reference"] || socket.assigns[:yank_pending]
    reason = Map.get(params, "reason", "") |> String.trim()

    if !is_binary(reference) or reference == "" do
      {:noreply, put_flash(socket, :error, "No component selected for yank.")}
    else
      args = %{"reference" => reference}
      args = if reason == "", do: args, else: Map.put(args, "reason", reason)

      case call_tool(socket, "component/yank", args) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Yanked #{reference}.")
           |> assign(:yank_pending, nil)
           |> load_registry()}

        {:error, err} ->
          {:noreply, put_flash(socket, :error, "Yank failed: #{error_message(err)}")}
      end
    end
  end

  def handle_event("reload", _params, socket) do
    # Two-step so the spinner is actually painted before the RPC starts.
    # Flipping loading→true in the same render cycle as load_registry/1
    # collapses to a single diff with loading→false; splitting via :message
    # gives the client a distinct "loading" frame to render the spinner.
    send(self(), :load_registry)
    {:noreply, assign(socket, :loading, true)}
  end

  @impl true
  def handle_info(:load_registry, socket) do
    {:noreply, load_registry(socket)}
  end

  def handle_info(%Cyfr.Bus.Components{}, socket) do
    {:noreply, load_registry(socket)}
  end

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  defp sync(socket) do
    case SystemLayer.call(socket, :sync, "registry/sync", %{}) do
      {:ok, _synced, socket} ->
        socket |> put_flash(:info, "Your push tokens are synced.") |> load_registry()

      {:asked, socket} ->
        put_flash(socket, :info, "Confirm the sync to mint your push tokens.")

      {:error, reason, socket} ->
        put_flash(socket, :error, "Sync failed: #{error_message(reason)}")
    end
  end

  # ============================================================================
  # Data loading
  # ============================================================================

  # The registry's current policy version and its policies, for the
  # acceptance the registry may ask for before a claim or a mint.
  defp load_policy(socket) do
    case call_tool(socket, "registry/legal_version", %{}) do
      {:ok, %{"policy_version" => version} = answer} when is_binary(version) ->
        assign(socket, :policy, %{version: version, policies: policy_titles(answer)})

      _unavailable ->
        assign(socket, :policy, nil)
    end
  end

  defp policy_titles(%{"policies" => policies}) when is_list(policies),
    do: for(%{"title" => title} <- policies, is_binary(title), do: title)

  defp policy_titles(_answer), do: []

  defp load_registry(socket) do
    socket = load_policy(socket)
    namespaces = owned_namespaces(socket)

    case fetch_components(socket, namespaces) do
      {:ok, components} ->
        socket
        |> assign(:namespaces, namespaces)
        |> assign(:components, components)
        |> assign(:loading, false)
        |> assign(:error, nil)

      {:error, err} ->
        socket
        |> assign(:namespaces, namespaces)
        |> assign(:components, [])
        |> assign(:loading, false)
        |> assign(:error, error_message(err))
    end
  end

  # Personal-namespace slug is already computed by `PrismWeb.Focus`; publisher
  # memberships come from `registry.whoami`. Both are strings, and a slug
  # that is both is listed once.
  defp owned_namespaces(socket) do
    personal = socket.assigns[:personal_namespace_slug]

    memberships =
      case call_tool(socket, "registry/whoami", %{}) do
        {:ok, %{memberships: ms}} when is_list(ms) ->
          Enum.flat_map(ms, fn m ->
            case m.slug do
              s when is_binary(s) and s != "" -> [s]
              _ -> []
            end
          end)

        _ ->
          []
      end

    [personal | memberships]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp fetch_components(_socket, []), do: {:ok, []}

  defp fetch_components(socket, namespaces) do
    results =
      Enum.map(namespaces, fn ns ->
        case call_tool(socket, "component/discover", %{"namespace" => ns}) do
          {:ok, %{components: comps}} when is_list(comps) -> {ns, {:ok, comps}}
          {:ok, _other} -> {ns, {:ok, []}}
          {:error, err} -> {ns, {:error, err}}
        end
      end)

    case Enum.find(results, fn {_, r} -> match?({:error, _}, r) end) do
      {_, {:error, err}} ->
        {:error, err}

      nil ->
        components =
          results
          |> Enum.flat_map(fn {ns, {:ok, comps}} ->
            Enum.map(comps, fn c -> Map.put(c, :_namespace, ns) end)
          end)
          |> Enum.sort_by(&sort_key/1)

        {:ok, components}
    end
  end

  defp sort_key(c) do
    {
      c._namespace,
      c[:component_type] || "",
      c[:name] || "",
      c[:version] || ""
    }
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h2 class="text-lg font-semibold text-white">My Registry</h2>
          <p class="text-sm text-gray-400 mt-1">
            Components you've published to cyfr.run. Deprecate keeps them installable with a warning; yank removes them from search and unpinned resolution.
          </p>
        </div>
        <div class="flex gap-2">
          <button
            phx-click="sync"
            phx-disable-with="Syncing…"
            class="px-3 py-1.5 text-xs rounded bg-blue-900 text-blue-100 border border-blue-700 hover:bg-blue-800 disabled:opacity-50"
          >
            Sync push tokens
          </button>
          <button
            phx-click="reload"
            phx-disable-with="Loading…"
            class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700 disabled:opacity-50"
          >
            Refresh
          </button>
        </div>
      </div>

      <.card :if={@policy}>
        <div class="flex items-start justify-between gap-4">
          <div>
            <h3 class="text-sm font-semibold text-white">Registry policies</h3>
            <p class="text-xs text-gray-400 mt-1">
              cyfr.run's policies, version <span class="font-mono">{@policy.version}</span>: {Enum.join(
                @policy.policies,
                ", "
              )}. The registry asks you to accept its current version before a claim or a token sync.
            </p>
          </div>
          <button
            phx-click="accept-policy"
            phx-value-version={@policy.version}
            phx-disable-with="Accepting…"
            class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700 disabled:opacity-50 whitespace-nowrap"
          >
            Accept version {@policy.version}
          </button>
        </div>
      </.card>

      <div :if={@loading} class="flex flex-col items-center justify-center py-16 gap-3">
        <.spinner class="h-6 w-6 text-gray-400" />
        <p class="text-sm text-gray-500">Loading your registry…</p>
      </div>

      <div :if={!@loading}>
        <div :if={@namespaces == []}>
          <.empty_state message="You haven't claimed a namespace on cyfr.run yet." />
        </div>

        <div
          :if={@error}
          class="rounded-lg bg-red-900/40 border border-red-800 px-4 py-3 text-sm text-red-300"
        >
          {@error}
        </div>

        <div :if={@components == [] && @namespaces != [] && !@error}>
          <.empty_state message="No components published to your namespace(s) yet." />
        </div>

        <.card :if={@components != []}>
          <table class="min-w-full">
            <thead>
              <tr class="text-left text-xs text-gray-500 uppercase border-b border-gray-800">
                <th class="px-3 py-2">Namespace</th>
                <th class="px-3 py-2">Type</th>
                <th class="px-3 py-2">Name</th>
                <th class="px-3 py-2">Version</th>
                <th class="px-3 py-2">Status</th>
                <th class="px-3 py-2 text-right">Manage</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-800">
              <tr :for={c <- @components} class="text-sm">
                <td class="px-3 py-2 font-mono text-gray-300">{c._namespace}</td>
                <td class="px-3 py-2 text-gray-400">{c[:component_type]}</td>
                <td class="px-3 py-2 text-gray-200">{c[:name]}</td>
                <td class="px-3 py-2 font-mono text-gray-400">{c[:version]}</td>
                <td class="px-3 py-2">
                  <span class={badge_class(c)}>
                    {String.upcase(status(c))}
                  </span>
                  <p :if={reason = c[:status_reason]} class="text-xs text-gray-500 mt-0.5">
                    {reason}
                  </p>
                </td>
                <td class="px-3 py-2">
                  <div
                    :if={status(c) not in ["yanked", "taken_down"]}
                    class="flex gap-2 justify-end"
                  >
                    <button
                      :if={status(c) != "deprecated"}
                      type="button"
                      phx-click="open-deprecate"
                      phx-value-reference={reference_of(c)}
                      class="px-2 py-1 text-xs rounded bg-yellow-900 text-yellow-200 border border-yellow-700 whitespace-nowrap disabled:opacity-50"
                    >
                      Deprecate
                    </button>
                    <button
                      type="button"
                      phx-click="open-yank"
                      phx-value-reference={reference_of(c)}
                      class="px-2 py-1 text-xs rounded bg-red-900 text-red-200 border border-red-700 whitespace-nowrap disabled:opacity-50"
                    >
                      Yank
                    </button>
                  </div>
                  <button
                    :if={status(c) == "taken_down"}
                    type="button"
                    phx-click="open-appeal"
                    phx-value-id={c[:id]}
                    class="text-xs text-blue-400 hover:text-blue-300 whitespace-nowrap"
                  >
                    Appeal this takedown →
                  </button>
                  <span :if={status(c) == "yanked"} class="text-xs text-gray-500">
                    —
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </.card>
      </div>

      <!-- Yank modal -->
      <.modal
        id="yank-modal"
        show={@yank_pending != nil}
        on_cancel={JS.push("close-yank")}
      >
        <div class="space-y-4">
          <div>
            <h3 class="text-base font-semibold text-white">Yank component</h3>
            <p class="text-sm text-gray-400 mt-1">
              <span class="font-mono text-gray-300">{@yank_pending}</span>
            </p>
            <p class="text-xs text-gray-500 mt-2">
              Yanking removes this version from search and unpinned resolution.
              Anyone who pinned it explicitly can still install it for reproducibility.
              Reversible by re-publishing a fresh version.
            </p>
          </div>
          <form phx-submit="yank" class="space-y-3">
            <input type="hidden" name="reference" value={@yank_pending} />
            <div>
              <label class="text-xs text-gray-500 uppercase">Reason (optional)</label>
              <textarea
                name="reason"
                rows="3"
                placeholder="e.g. accidental publish, broken build"
                class="w-full mt-1 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white focus:border-red-600 focus:ring-1 focus:ring-red-600"
                autofocus
              ></textarea>
            </div>
            <div class="flex justify-end gap-2">
              <button
                type="button"
                phx-click="close-yank"
                class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700"
              >
                Cancel
              </button>
              <button
                type="submit"
                phx-disable-with="Yanking…"
                class="px-3 py-1.5 text-xs rounded bg-red-900 text-red-100 border border-red-700 hover:bg-red-800 disabled:opacity-50"
              >
                Confirm yank
              </button>
            </div>
          </form>
        </div>
      </.modal>

      <!-- Appeal modal -->
      <.modal
        id="appeal-modal"
        show={@appeal_pending != nil}
        on_cancel={JS.push("close-appeal")}
      >
        <div class="space-y-4">
          <div>
            <h3 class="text-base font-semibold text-white">Appeal this takedown</h3>
            <p class="text-sm text-gray-400 mt-1">
              <span class="font-mono text-gray-300">{@appeal_pending}</span>
            </p>
            <p class="text-xs text-gray-500 mt-2">
              Your identity signs the appeal; moderators review every appeal manually.
            </p>
          </div>

          <div
            :if={@appeal_error}
            class="rounded-lg border border-red-900/40 bg-red-950/20 p-3 text-xs text-red-300"
          >
            {@appeal_error}
          </div>

          <form phx-submit="submit-appeal" class="space-y-3">
            <div>
              <label class="text-xs text-gray-500 uppercase">Argument</label>
              <textarea
                name="argument"
                required
                rows="5"
                maxlength="4000"
                placeholder="Why should this takedown be reversed? (max 4000 characters)"
                class="w-full mt-1 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white focus:border-blue-600 focus:ring-1 focus:ring-blue-600"
              >{@appeal_argument}</textarea>
            </div>
            <div class="flex justify-end gap-2">
              <button
                type="button"
                phx-click="close-appeal"
                class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700"
              >
                Cancel
              </button>
              <button
                type="submit"
                phx-disable-with="Filing…"
                class="px-3 py-1.5 text-xs rounded bg-blue-900 text-blue-100 border border-blue-700 hover:bg-blue-800 disabled:opacity-50"
              >
                File appeal
              </button>
            </div>
          </form>
        </div>
      </.modal>

      <!-- Deprecate modal -->
      <.modal
        id="deprecate-modal"
        show={@deprecate_pending != nil}
        on_cancel={JS.push("close-deprecate")}
      >
        <div class="space-y-4">
          <div>
            <h3 class="text-base font-semibold text-white">Deprecate component</h3>
            <p class="text-sm text-gray-400 mt-1">
              <span class="font-mono text-gray-300">{@deprecate_pending}</span>
            </p>
            <p class="text-xs text-gray-500 mt-2">
              The component stays installable but search results and
              dependents will flag it. Include a reason so consumers know how
              to migrate. Reversible by re-publishing a fresh version.
            </p>
          </div>
          <form phx-submit="deprecate" class="space-y-3">
            <input type="hidden" name="reference" value={@deprecate_pending} />
            <div>
              <label class="text-xs text-gray-500 uppercase">Deprecation reason</label>
              <textarea
                name="reason"
                required
                rows="3"
                placeholder="e.g. superseded by v2, security fix in 1.1.0"
                class="w-full mt-1 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white focus:border-yellow-600 focus:ring-1 focus:ring-yellow-600"
                autofocus
              ></textarea>
            </div>
            <div class="flex justify-end gap-2">
              <button
                type="button"
                phx-click="close-deprecate"
                class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700"
              >
                Cancel
              </button>
              <button
                type="submit"
                phx-disable-with="Deprecating…"
                class="px-3 py-1.5 text-xs rounded bg-yellow-900 text-yellow-100 border border-yellow-700 hover:bg-yellow-800 disabled:opacity-50"
              >
                Confirm deprecate
              </button>
            </div>
          </form>
        </div>
      </.modal>

      <.live_component module={SystemLayer} id={SystemLayer.layer_id()} context={@context} />
    </div>
    """
  end

  # Shared spinner SVG.
  attr :class, :string, default: "h-4 w-4"

  defp spinner(assigns) do
    ~H"""
    <svg class={"animate-spin #{@class}"} fill="none" viewBox="0 0 24 24">
      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
      <path
        class="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
      />
    </svg>
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp status(c), do: c[:status] || "active"

  defp reference_of(c) do
    # cyfr.run's /v1/components response uses `component_type` (full word:
    # catalyst / reagent / formula / tincture). That's also the canonical
    # type prefix accepted by `Prima.ComponentRef.parse/1` — use it
    # directly with no remapping.
    t = c[:component_type] || "catalyst"
    ns = c._namespace
    n = c[:name] || ""
    v = c[:version] || ""
    Prima.ComponentRef.build(t, ns, n, v)
  end

  defp badge_class(c) do
    base = "inline-flex items-center px-2 py-0.5 rounded text-xs font-semibold uppercase"

    color =
      case status(c) do
        "active" -> "bg-green-900/50 text-green-300 border border-green-800"
        "deprecated" -> "bg-yellow-900 text-yellow-300 border border-yellow-700"
        "yanked" -> "bg-orange-900 text-orange-300 border border-orange-700"
        "taken_down" -> "bg-red-900 text-red-300 border border-red-700"
        _ -> "bg-gray-800 text-gray-300 border border-gray-700"
      end

    "#{base} #{color}"
  end
end
