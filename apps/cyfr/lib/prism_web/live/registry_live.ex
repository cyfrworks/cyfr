# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RegistryLive do
  @moduledoc """
  Lists components you've published to cyfr.run and lets you manage them
  (deprecate, yank). Unlike `ComponentsLive` — which shows components
  *installed locally* on this machine — this view is strictly the remote
  namespace state owned by the current user.

  Sources:
    * Personal namespace — from `@personal_namespace_slug` (set by `LiveAuth`).
    * Publisher memberships — fetched via `registry.whoami` MCP action.

  For each owned namespace we call `component.discover` (which hits
  `/v1/components?namespace=<slug>` on cyfr.run) and merge results into a
  single flat list, keyed by `{namespace, type, name, version}`.
  """

  use PrismWeb, :live_view

  alias Phoenix.LiveView.JS
  alias Sanctum.Auth.DeviceFlow
  require Logger

  @appeal_poll_interval_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    # Render instantly with the sidebar highlighted + a spinner in the main
    # panel, then trigger the load as a separate message so the first paint
    # doesn't block on the cyfr.run round-trip. The load handler below
    # flips `:loading` to false and fills `:components`.
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic("prism:components", ctx))
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
     |> assign_appeal_idle()}
  end

  defp assign_appeal_idle(socket) do
    socket
    |> assign(:appeal_pending, nil)
    |> assign(:appeal_state, :idle)
    |> assign(:appeal_argument, "")
    |> assign(:appeal_provider, nil)
    |> assign(:appeal_user_code, nil)
    |> assign(:appeal_verification_uri, nil)
    |> assign(:appeal_device_code, nil)
    |> assign(:appeal_error, nil)
  end

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
  # Closed-platform posture: appeals are filed in-client. The user clicks
  # "Appeal this takedown" on a `taken_down` row → modal opens → they pick
  # the identity provider that originally claimed the namespace → fresh
  # DeviceFlow OAuth → cyfr.run verifies the access_token at /v1/appeals
  # and binds it to the action's rightful subject.
  def handle_event("open-appeal", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign_appeal_idle()
     |> assign(:appeal_pending, id)
     |> assign(:appeal_state, :form)}
  end

  def handle_event("close-appeal", _params, socket) do
    {:noreply, assign_appeal_idle(socket)}
  end

  def handle_event("start-appeal", params, socket) do
    argument = params |> Map.get("argument", "") |> String.trim()
    provider = params |> Map.get("provider", "") |> String.downcase()
    component_id = socket.assigns.appeal_pending

    cond do
      component_id in [nil, ""] ->
        {:noreply, put_flash(socket, :error, "No takedown selected.")}

      argument == "" ->
        {:noreply, assign(socket, :appeal_error, "Argument is required.")}

      String.length(argument) > 4_000 ->
        {:noreply, assign(socket, :appeal_error, "Argument exceeds 4000 characters.")}

      provider not in ["github", "google"] ->
        {:noreply, assign(socket, :appeal_error, "Pick a supported provider.")}

      true ->
        provider_atom = String.to_existing_atom(provider)

        case DeviceFlow.init_device_flow(provider_atom) do
          {:ok, info} ->
            if connected?(socket), do: schedule_appeal_poll(info.interval)

            {:noreply,
             socket
             |> assign(:appeal_state, :waiting)
             |> assign(:appeal_argument, argument)
             |> assign(:appeal_provider, provider_atom)
             |> assign(:appeal_user_code, info.user_code)
             |> assign(:appeal_verification_uri, info.verification_uri)
             |> assign(:appeal_device_code, info.device_code)
             |> assign(:appeal_error, nil)}

          {:error, reason} ->
            Logger.warning("[RegistryLive] appeal device-flow init failed: #{inspect(reason)}")

            {:noreply,
             socket
             |> assign(:appeal_state, :form)
             |> assign(:appeal_error, "Couldn't start provider login: #{format_err(reason)}")}
        end
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
            {:noreply, put_flash(socket, :error, "Deprecate failed: #{format_err(err)}")}
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
          {:noreply, put_flash(socket, :error, "Yank failed: #{format_err(err)}")}
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

  def handle_info(:appeal_poll, socket) do
    case socket.assigns.appeal_state do
      :waiting ->
        case DeviceFlow.poll_for_access_token(
               socket.assigns.appeal_provider,
               socket.assigns.appeal_device_code
             ) do
          {:ok, %{status: "complete", access_token: access_token, provider: provider}} ->
            submit_appeal(socket, provider, access_token)

          {:ok, %{status: "pending"}} ->
            schedule_appeal_poll(nil)
            {:noreply, socket}

          {:ok, %{status: "expired"}} ->
            {:noreply,
             socket
             |> assign(:appeal_state, :form)
             |> assign(:appeal_error, "Code expired. Please try again.")}

          {:ok, %{status: "denied"}} ->
            {:noreply,
             socket
             |> assign(:appeal_state, :form)
             |> assign(:appeal_error, "Authorization was denied.")}

          {:error, reason} ->
            Logger.warning("[RegistryLive] appeal poll error: #{inspect(reason)}")
            {:noreply, assign(socket, :appeal_error, format_err(reason))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(:components_changed, socket) do
    {:noreply, load_registry(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[RegistryLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp submit_appeal(socket, provider_atom, access_token) do
    provider = to_string(provider_atom)
    component_id = socket.assigns.appeal_pending
    argument = socket.assigns.appeal_argument

    args = %{
      "provider" => provider,
      "access_token" => access_token,
      "action_type" => "takedown",
      "action_ref" => component_id,
      "argument" => argument
    }

    case call_tool(socket, "registry/appeal", args) do
      {:ok, _body} ->
        {:noreply,
         socket
         |> put_flash(:info, "Appeal filed for #{component_id}. Moderators will review.")
         |> assign_appeal_idle()}

      {:error, err} ->
        Logger.warning("[RegistryLive] appeal submit failed: #{inspect(err)}")

        {:noreply,
         socket
         |> assign(:appeal_state, :form)
         |> assign(:appeal_error, "Submit failed: #{format_err(err)}")}
    end
  end

  defp schedule_appeal_poll(interval) do
    ms = if interval, do: interval * 1_000, else: @appeal_poll_interval_ms
    Process.send_after(self(), :appeal_poll, ms)
  end

  # ============================================================================
  # Data loading
  # ============================================================================

  defp load_registry(socket) do
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
        |> assign(:error, format_err(err))
    end
  end

  # Personal-namespace slug is already computed by `LiveAuth`; publisher
  # memberships come from `registry.whoami`. Both are strings; uniq to guard
  # against the edge case where a user is also a member of their own personal
  # slug (shouldn't happen today, but cheap to defend).
  defp owned_namespaces(socket) do
    personal = socket.assigns[:personal_namespace_slug]

    memberships =
      case call_tool(socket, "registry/whoami", %{}) do
        {:ok, %{"memberships" => ms}} when is_list(ms) ->
          Enum.flat_map(ms, fn m ->
            case m["slug"] do
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
          {:ok, %{"components" => comps}} when is_list(comps) -> {ns, {:ok, comps}}
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
            Enum.map(comps, fn c -> Map.put(c, "_namespace", ns) end)
          end)
          |> Enum.sort_by(&sort_key/1)

        {:ok, components}
    end
  end

  defp sort_key(c) do
    {
      c["_namespace"] || "",
      cf(c, "component_type") || "",
      cf(c, "name") || "",
      cf(c, "version") || ""
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
        <button
          phx-click="reload"
          phx-disable-with="Loading…"
          class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700 disabled:opacity-50"
        >
          Refresh
        </button>
      </div>

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
                <td class="px-3 py-2 font-mono text-gray-300">{c["_namespace"]}</td>
                <td class="px-3 py-2 text-gray-400">{cf(c, "component_type")}</td>
                <td class="px-3 py-2 text-gray-200">{cf(c, "name")}</td>
                <td class="px-3 py-2 font-mono text-gray-400">{cf(c, "version")}</td>
                <td class="px-3 py-2">
                  <span class={badge_class(c)}>
                    {String.upcase(status(c))}
                  </span>
                  <p :if={reason = cf(c, "status_reason")} class="text-xs text-gray-500 mt-0.5">
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
                    phx-value-id={cf(c, "id")}
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
              Filing an appeal re-authenticates you against your identity
              provider so we can confirm you're the namespace's claimant.
              Moderators review every appeal manually.
            </p>
          </div>

          <div
            :if={@appeal_error}
            class="rounded-lg border border-red-900/40 bg-red-950/20 p-3 text-xs text-red-300"
          >
            {@appeal_error}
          </div>

          <div :if={@appeal_state == :form}>
            <form phx-submit="start-appeal" class="space-y-3">
              <div>
                <label class="text-xs text-gray-500 uppercase">Provider</label>
                <div class="flex gap-3 mt-1">
                  <label class="flex items-center gap-2 text-sm text-gray-300">
                    <input type="radio" name="provider" value="github" checked /> GitHub
                  </label>
                  <label class="flex items-center gap-2 text-sm text-gray-300">
                    <input type="radio" name="provider" value="google" /> Google
                  </label>
                </div>
                <p class="text-xs text-gray-500 mt-1">
                  Pick the provider that originally claimed this namespace.
                </p>
              </div>
              <div>
                <label class="text-xs text-gray-500 uppercase">Argument</label>
                <textarea
                  name="argument"
                  required
                  rows="5"
                  maxlength="4000"
                  placeholder="Why should this takedown be reversed? (max 4000 chars)"
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
                  phx-disable-with="Starting…"
                  class="px-3 py-1.5 text-xs rounded bg-blue-900 text-blue-100 border border-blue-700 hover:bg-blue-800 disabled:opacity-50"
                >
                  Continue with provider
                </button>
              </div>
            </form>
          </div>

          <div :if={@appeal_state == :waiting} class="space-y-3">
            <p class="text-sm text-gray-300">
              Open
              <a
                href={@appeal_verification_uri}
                target="_blank"
                rel="noopener noreferrer"
                class="text-blue-400 hover:text-blue-300"
              >
                {@appeal_verification_uri}
              </a>
              and enter:
            </p>
            <div class="rounded-lg bg-gray-800 border border-gray-700 px-4 py-3 text-center">
              <span class="font-mono text-2xl tracking-widest text-white">{@appeal_user_code}</span>
            </div>
            <p class="text-xs text-gray-500 flex items-center gap-2">
              <.spinner class="h-3 w-3" /> Waiting for authorization…
            </p>
            <div class="flex justify-end">
              <button
                type="button"
                phx-click="close-appeal"
                class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700"
              >
                Cancel
              </button>
            </div>
          </div>
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
    </div>
    """
  end

  # Shared spinner SVG — mirrors the pattern in auth_live.ex.
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

  defp cf(c, key) when is_map(c) do
    c[key] || c[String.to_existing_atom(key)]
  rescue
    _ -> nil
  end

  defp status(c), do: cf(c, "status") || "active"

  defp reference_of(c) do
    # cyfr.run's /v1/components response uses `component_type` (full word:
    # catalyst / reagent / formula / tincture). That's also the canonical
    # type prefix accepted by `Sanctum.ComponentRef.parse/1` — use it
    # directly with no remapping.
    t = cf(c, "component_type") || "catalyst"
    ns = c["_namespace"] || cf(c, "namespace_slug") || ""
    n = cf(c, "name") || ""
    v = cf(c, "version") || ""
    "#{t}:#{ns}.#{n}:#{v}"
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

  defp format_err(%Compendium.OCI.Errors{message: msg}) when is_binary(msg), do: msg
  defp format_err(err) when is_binary(err), do: err
  defp format_err(err), do: inspect(err)
end
