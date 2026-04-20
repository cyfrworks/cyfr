defmodule PrismWeb.AdminLive do
  @moduledoc """
  Admin moderation surface for cyfr.run abuse reports.

  Three tabs:
    * Open Reports — queue of status='open' abuse reports, with
      resolve-with-takedown / resolve / dismiss actions.
    * Settings — operator stashes the cyfr.run `ADMIN_TOKEN` here once;
      stored via `CredentialStore.put_admin_token/3` under a distinct
      prefix so it never leaks into the claim-gate scanner.

  All admin actions call `Compendium.Registry.Client.admin_*` which hits
  /v1/admin/* on cyfr.run with the stored token.

  Authorization: gated at mount by `PrismWeb.LiveAdmin.:require_admin`
  (on_mount chain). A non-admin user is redirected to the dashboard.
  """

  use PrismWeb, :live_view

  alias Compendium.Registry.{Client, CredentialStore}
  alias Compendium.Edition
  alias Sanctum.ComponentRef

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:tab, "reports")
     |> assign(:reports, [])
     |> assign(:reports_loaded?, false)
     |> assign(:admin_token_set?, admin_token_set?(socket))
     |> assign(:flash_message, nil)
     |> maybe_load_reports()}
  end

  @impl true
  def handle_event("switch-tab", %{"tab" => tab}, socket) when tab in ["reports", "settings"] do
    socket = assign(socket, :tab, tab)

    socket =
      if tab == "reports", do: maybe_load_reports(socket), else: socket

    {:noreply, socket}
  end

  def handle_event("store-admin-token", %{"token" => token}, socket) when is_binary(token) do
    trimmed = String.trim(token)

    if trimmed == "" do
      {:noreply, assign(socket, :flash_message, {:error, "Token cannot be empty"})}
    else
      case CredentialStore.put_admin_token(user_id(socket), registry(), trimmed) do
        :ok ->
          {:noreply,
           socket
           |> assign(:admin_token_set?, true)
           |> assign(:flash_message, {:info, "Admin token stored — reloading reports"})
           |> maybe_load_reports()}

        {:error, reason} ->
          {:noreply, assign(socket, :flash_message, {:error, "Failed: #{inspect(reason)}"})}
      end
    end
  end

  def handle_event("clear-admin-token", _params, socket) do
    CredentialStore.delete_admin_token(user_id(socket), registry())

    {:noreply,
     socket
     |> assign(:admin_token_set?, false)
     |> assign(:reports, [])
     |> assign(:reports_loaded?, false)
     |> assign(:flash_message, {:info, "Admin token cleared"})}
  end

  def handle_event("resolve-with-takedown", %{"report_id" => rid} = params, socket) do
    ref = Map.get(params, "component_ref", "")
    resolution = Map.get(params, "resolution", "takedown per abuse report")

    with {:ok, token} <- fetch_admin_token(socket),
         {:ok, parsed_ref} <- parse_fully_qualified(ref),
         {:ok, _} <-
           Client.admin_takedown_component(
             parsed_ref.namespace,
             parsed_ref.type,
             parsed_ref.name,
             parsed_ref.version,
             resolution,
             token
           ),
         {:ok, _} <- Client.admin_resolve_report(rid, resolution, token) do
      {:noreply,
       socket
       |> assign(:flash_message, {:info, "Component taken down, report resolved"})
       |> maybe_load_reports(force: true)}
    else
      {:error, err} ->
        {:noreply, assign(socket, :flash_message, {:error, format_err(err)})}
    end
  end

  def handle_event("resolve-report", %{"report_id" => rid, "resolution" => res}, socket) do
    with {:ok, token} <- fetch_admin_token(socket),
         {:ok, _} <- Client.admin_resolve_report(rid, res, token) do
      {:noreply,
       socket
       |> assign(:flash_message, {:info, "Report resolved"})
       |> maybe_load_reports(force: true)}
    else
      {:error, err} ->
        {:noreply, assign(socket, :flash_message, {:error, format_err(err)})}
    end
  end

  def handle_event("dismiss-report", %{"report_id" => rid} = params, socket) do
    res = Map.get(params, "resolution", "")

    with {:ok, token} <- fetch_admin_token(socket),
         {:ok, _} <- Client.admin_dismiss_report(rid, res, token) do
      {:noreply,
       socket
       |> assign(:flash_message, {:info, "Report dismissed"})
       |> maybe_load_reports(force: true)}
    else
      {:error, err} ->
        {:noreply, assign(socket, :flash_message, {:error, format_err(err)})}
    end
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp maybe_load_reports(socket, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if socket.assigns.admin_token_set? and (force or not socket.assigns.reports_loaded?) do
      case fetch_admin_token(socket) do
        {:ok, token} -> load_reports(socket, token)
        _ -> socket
      end
    else
      socket
    end
  end

  defp load_reports(socket, token) do
    case Client.admin_list_open_reports(token) do
      {:ok, %{"reports" => reports}} when is_list(reports) ->
        socket
        |> assign(:reports, reports)
        |> assign(:reports_loaded?, true)

      {:ok, _} ->
        socket |> assign(:reports, []) |> assign(:reports_loaded?, true)

      {:error, err} ->
        socket
        |> assign(:reports, [])
        |> assign(:reports_loaded?, true)
        |> assign(:flash_message, {:error, "Load failed: #{format_err(err)}"})
    end
  end

  defp admin_token_set?(socket) do
    case CredentialStore.get_admin_token(user_id(socket), registry()) do
      {:ok, _} -> true
      :not_found -> false
    end
  end

  defp fetch_admin_token(socket) do
    case CredentialStore.get_admin_token(user_id(socket), registry()) do
      {:ok, token} -> {:ok, token}
      :not_found -> {:error, "admin token not stored"}
    end
  end

  defp user_id(socket), do: socket.assigns.current_user.id

  defp registry, do: Edition.cyfr_run_registry()

  defp parse_fully_qualified(ref) do
    with {:ok, %ComponentRef{version: v} = parsed} when is_binary(v) and v != "" <-
           ComponentRef.parse(ref) do
      {:ok, parsed}
    else
      _ -> {:error, "component_ref must be fully qualified with a version"}
    end
  end

  defp format_err(%Compendium.OCI.Errors{message: msg}), do: msg
  defp format_err(err) when is_binary(err), do: err
  defp format_err(err), do: inspect(err)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-6 text-gray-100">
      <h1 class="text-2xl font-semibold mb-4">Admin Moderation</h1>

      <div :if={@flash_message} class="mb-4 p-3 rounded border border-gray-700">
        <span :if={match?({:info, _}, @flash_message)} class="text-green-300">
          {elem(@flash_message, 1)}
        </span>
        <span :if={match?({:error, _}, @flash_message)} class="text-red-300">
          {elem(@flash_message, 1)}
        </span>
      </div>

      <nav class="flex gap-4 border-b border-gray-700 mb-6">
        <button
          type="button"
          phx-click="switch-tab"
          phx-value-tab="reports"
          class={"px-3 py-2 text-sm " <> if(@tab == "reports", do: "border-b-2 border-indigo-500 text-white", else: "text-gray-400")}
        >
          Open Reports
        </button>
        <button
          type="button"
          phx-click="switch-tab"
          phx-value-tab="settings"
          class={"px-3 py-2 text-sm " <> if(@tab == "settings", do: "border-b-2 border-indigo-500 text-white", else: "text-gray-400")}
        >
          Settings
        </button>
      </nav>

      <div :if={@tab == "reports"}>
        <div :if={not @admin_token_set?} class="p-4 rounded bg-yellow-900/40 border border-yellow-700 text-yellow-200">
          No admin token stored yet. Open the Settings tab and paste the cyfr.run <code>ADMIN_TOKEN</code>.
        </div>

        <div :if={@admin_token_set?}>
          <div :if={@reports == []} class="text-gray-400 text-sm p-4">
            No open reports.
          </div>

          <div :for={rep <- @reports} class="mb-4 p-4 rounded border border-gray-700">
            <div class="flex justify-between text-xs text-gray-400 mb-2">
              <span>
                <span class="font-mono">{rep["id"]}</span> · {rep["category"]} ·
                <span :if={rep["target_namespace"]}>ns=<code>{rep["target_namespace"]}</code></span>
                <span :if={rep["target_component_id"]}>comp=<code>{rep["target_component_id"]}</code></span>
              </span>
              <span>by {rep["reporter_created_via"]}</span>
            </div>
            <p class="text-sm mb-3 whitespace-pre-wrap">{rep["details"]}</p>
            <div class="flex gap-2">
              <button
                type="button"
                phx-click="resolve-report"
                phx-value-report_id={rep["id"]}
                phx-value-resolution="resolved without action"
                class="px-3 py-1 text-xs rounded bg-green-900 text-green-300 border border-green-700"
              >
                Resolve
              </button>
              <button
                type="button"
                phx-click="dismiss-report"
                phx-value-report_id={rep["id"]}
                class="px-3 py-1 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700"
              >
                Dismiss
              </button>
            </div>
          </div>
        </div>
      </div>

      <div :if={@tab == "settings"}>
        <form
          :if={not @admin_token_set?}
          phx-submit="store-admin-token"
          class="space-y-3 max-w-xl"
        >
          <label class="block text-sm text-gray-300">
            cyfr.run <code>ADMIN_TOKEN</code>
          </label>
          <input
            type="password"
            name="token"
            class="w-full px-3 py-2 rounded bg-gray-900 border border-gray-700 text-sm"
            autocomplete="off"
          />
          <button
            type="submit"
            class="px-4 py-2 rounded bg-indigo-700 text-white text-sm"
          >
            Store Token
          </button>
        </form>

        <div :if={@admin_token_set?} class="text-sm space-y-3">
          <p class="text-gray-300">Admin token is stored for your user.</p>
          <button
            type="button"
            phx-click="clear-admin-token"
            class="px-3 py-1 text-xs rounded bg-red-900 text-red-300 border border-red-700"
          >
            Clear Token
          </button>
        </div>
      </div>
    </div>
    """
  end
end
