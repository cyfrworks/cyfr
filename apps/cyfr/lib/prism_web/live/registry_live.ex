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

  The person's registry acts here are each a request a passkey of their
  account signs (`registry.sync`, `registry.claim_publisher`,
  `registry.verify_publisher`, `registry.appeal`); no identity provider
  is asked. The action answers
  the request to sign, and the page opens the account pages with it in a
  new tab (`system_layer:hop`), so this page stays; the answer returns to
  the sign-in page in that tab, which completes the act and says what it
  did (`PrismWeb.LoginLive`).

  A namespace's push tokens and members are managed under the push token
  this CYFR holds for it (`registry.tokens_*`, `registry.members_*`).
  Issuing a token needs a fresh confirmation, asked through the system
  layer and repeated from `system_layer_repeat/4`, so it is the one change
  sent on the page's process, where the layer holds what it asked; its
  secret is shown once. A revoke and a removal are asked before they are
  sent.

  The registry is read, and every other change sent, off the page's
  process (`start_async/4`): a registry request has no total deadline, a
  read is one per namespace, and the browser gives up on an event it
  waits on for 30 seconds. A change is sent once, its button says so
  until the registry answers, and it runs to its end if the person
  leaves (`PrismWeb.Ops.run_to_end/1`); a read in flight is replaced by
  the next.
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
    # panel; the registry's answer (`load_registry/1`) flips `:loading` to
    # false and fills `:components`.
    if connected?(socket) do
      actor = Sanctum.Context.actor(socket.assigns[:context])
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.components(actor))
    end

    socket =
      socket
      |> assign(:page_title, "My Registry")
      |> assign(:active_nav, "registry")
      |> assign(:namespaces, [])
      |> assign(:components, [])
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:deprecate_pending, nil)
      |> assign(:yank_pending, nil)
      # What a change is sent for (a reference, a token id, a member's
      # handle), until the registry answers.
      |> assign(:acting, nil)
      |> assign(:terms, nil)
      |> assign(:managing, nil)
      |> assign_managed_idle()
      |> assign_appeal_idle()

    {:ok, if(connected?(socket), do: load_registry(socket), else: socket)}
  end

  # The namespace being managed: its tokens and members as last read
  # (`nil` while read, `{:ok, rows}` or `{:error, message}`), the secret of
  # a token just issued, and the revoke or removal waiting to be confirmed.
  defp assign_managed_idle(socket) do
    socket
    |> assign(:tokens, nil)
    |> assign(:members, nil)
    |> assign(:issued, nil)
    |> assign(:revoke_pending, nil)
    |> assign(:remove_pending, nil)
  end

  defp assign_appeal_idle(socket) do
    socket
    |> assign(:appeal_pending, nil)
    |> assign(:appeal_argument, "")
    |> assign(:appeal_error, nil)
  end

  @unreadable "The registry's answer could not be read."

  @acts ~w(deprecate yank revoke-token add-member update-member remove-member)

  # The changes made to the namespace being managed.
  @managed ~w(issue-token revoke-token add-member update-member remove-member)

  @impl true
  def handle_event(event, _params, %{assigns: %{acting: acting}} = socket)
      when event in @acts and is_binary(acting),
      do: {:noreply, socket}

  def handle_event(event, _params, %{assigns: %{managing: nil}} = socket)
      when event in @managed,
      do: {:noreply, socket}

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
  # An appeal of a takedown is a request a passkey of the person's account
  # signs (`registry.appeal`); the registry binds it to the action's
  # rightful appellant by that account.
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

        case sign(socket, "registry/appeal", args) do
          {:ok, socket} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Sign the appeal for #{component_id} with your passkey in the new tab."
             )
             |> assign_appeal_idle()}

          {:error, err} ->
            {:noreply,
             socket
             |> assign(:appeal_argument, argument)
             |> assign(:appeal_error, "Submit failed: #{error_message(err)}")}
        end
    end
  end

  # ---- Push tokens ----
  def handle_event("sync", _params, socket), do: {:noreply, sync(socket)}

  # ---- Publisher namespaces ----
  # A claim answers the DNS record the registry looks for under the
  # domain; the verification finds it and mints the founding member's
  # push token. Both are signed in the new tab, which says what came of
  # them.
  def handle_event("claim-publisher", %{"slug" => slug}, socket),
    do: {:noreply, sign_publisher(socket, "registry/claim_publisher", slug, "claim")}

  def handle_event("verify-publisher", %{"slug" => slug}, socket),
    do: {:noreply, sign_publisher(socket, "registry/verify_publisher", slug, "verification")}

  # ---- A namespace's push tokens and members ----
  def handle_event("manage", %{"slug" => slug}, socket) do
    if slug in socket.assigns.namespaces do
      {:noreply, socket |> assign(:managing, slug) |> assign_managed_idle() |> load_managed()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close-manage", _params, socket),
    do:
      {:noreply,
       socket |> cancel_async(:managed) |> assign(:managing, nil) |> assign_managed_idle()}

  def handle_event("issue-token", params, socket) do
    label = params |> Map.get("label", "") |> String.trim()
    args = %{"slug" => socket.assigns.managing}
    issue(socket, if(label == "", do: args, else: Map.put(args, "label", label)))
  end

  def handle_event("dismiss-issued", _params, socket),
    do: {:noreply, assign(socket, :issued, nil)}

  def handle_event("ask-revoke", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :revoke_pending, id)}

  def handle_event("close-revoke", _params, socket),
    do: {:noreply, assign(socket, :revoke_pending, nil)}

  def handle_event("revoke-token", _params, %{assigns: %{revoke_pending: id}} = socket)
      when is_binary(id) do
    args = %{"slug" => socket.assigns.managing, "token_id" => id}
    {:noreply, act(socket, :revoke, id, "registry/tokens_revoke", args)}
  end

  def handle_event("add-member", %{"handle" => handle, "role" => role}, socket) do
    case String.trim(handle) do
      "" ->
        {:noreply, put_flash(socket, :error, "Name the person to add by their handle.")}

      handle ->
        args = %{
          "slug" => socket.assigns.managing,
          "target_personal_slug" => handle,
          "role" => role
        }

        {:noreply, act(socket, :add_member, handle, "registry/members_add", args)}
    end
  end

  def handle_event("update-member", %{"handle" => handle, "role" => role}, socket) do
    args = %{"slug" => socket.assigns.managing, "target_personal_slug" => handle, "role" => role}
    {:noreply, act(socket, :update_member, handle, "registry/members_update", args)}
  end

  def handle_event("ask-remove", %{"handle" => handle}, socket),
    do: {:noreply, assign(socket, :remove_pending, handle)}

  def handle_event("close-remove", _params, socket),
    do: {:noreply, assign(socket, :remove_pending, nil)}

  def handle_event("remove-member", _params, %{assigns: %{remove_pending: handle}} = socket)
      when is_binary(handle) do
    args = %{"slug" => socket.assigns.managing, "target_personal_slug" => handle}
    {:noreply, act(socket, :remove_member, handle, "registry/members_remove", args)}
  end

  # A revoke or a removal with nothing waiting to be confirmed.
  def handle_event(event, _params, socket) when event in ["revoke-token", "remove-member"],
    do: {:noreply, socket}

  # ---- Reporting a namespace ----
  def handle_event("report-namespace", %{"slug" => slug}, socket) do
    case String.trim(slug) do
      "" ->
        {:noreply, put_flash(socket, :error, "Name the namespace to report.")}

      slug ->
        PrismWeb.ReportComponent.open_namespace("report", slug)
        {:noreply, socket}
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
        args = %{"reference" => reference, "reason" => reason}
        {:noreply, act(socket, :deprecate, reference, "component/deprecate", args)}
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
      {:noreply, act(socket, :yank, reference, "component/yank", args)}
    end
  end

  def handle_event("reload", _params, socket),
    do: {:noreply, socket |> assign(:loading, true) |> load_registry()}

  @impl true
  def handle_info(%Cyfr.Bus.Components{}, socket) do
    {:noreply, load_registry(socket)}
  end

  def handle_info({:report_component, :submitted}, socket),
    do: {:noreply, put_flash(socket, :info, "Report sent to the registry's moderators.")}

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # A token issue this page asked for was confirmed: sent again, once.
  @impl PrismWeb.SystemLayer.Hook
  def system_layer_repeat({:token_issue, _slug}, _tool, args, socket), do: issue(socket, args)

  @impl true
  def handle_async(:act, {:ok, {tag, act, reference, result}}, socket),
    do:
      CyfrWeb.ContextGuard.deliver(
        assign(socket, :acting, nil),
        tag,
        &{:noreply, acted(&1, act, reference, result)}
      )

  def handle_async(:load, {:ok, {tag, loaded}}, socket),
    do: CyfrWeb.ContextGuard.deliver(socket, tag, &{:noreply, loaded(&1, loaded)})

  def handle_async(:managed, {:ok, {tag, slug, managed}}, socket),
    do: CyfrWeb.ContextGuard.deliver(socket, tag, &{:noreply, managed(&1, slug, managed)})

  # Only the node's shutdown stops an act (`run_to_end/1`); a read is
  # stopped only by the next one.
  def handle_async(_name, {:exit, _reason}, socket), do: {:noreply, socket}

  # A change sent to the registry, off the event and run to its end.
  defp act(socket, act, reference, tool, args) do
    ctx = socket.assigns.context
    tag = CyfrWeb.ContextGuard.capture(ctx)

    socket
    |> assign(:acting, reference)
    |> start_async(
      :act,
      fn -> {tag, act, reference, run_to_end(fn -> call_tool(ctx, tool, args) end)} end,
      supervisor: Prism.TaskSupervisor
    )
  end

  defp acted(socket, :deprecate, reference, {:ok, _}) do
    socket
    |> put_flash(:info, "Deprecated #{reference}.")
    |> assign(:deprecate_pending, nil)
    |> load_registry()
  end

  defp acted(socket, :yank, reference, {:ok, _}) do
    socket
    |> put_flash(:info, "Yanked #{reference}.")
    |> assign(:yank_pending, nil)
    |> load_registry()
  end

  defp acted(socket, :revoke, _id, {:ok, _}) do
    socket
    |> put_flash(:info, "Push token revoked.")
    |> assign(:revoke_pending, nil)
    |> load_managed()
  end

  defp acted(socket, :add_member, handle, {:ok, _}),
    do: socket |> put_flash(:info, "Added #{handle}.") |> load_managed()

  defp acted(socket, :update_member, handle, {:ok, _}),
    do: socket |> put_flash(:info, "Changed #{handle}'s role.") |> load_managed()

  defp acted(socket, :remove_member, handle, {:ok, _}) do
    socket
    |> put_flash(:info, "Removed #{handle}.")
    |> assign(:remove_pending, nil)
    |> load_managed()
  end

  defp acted(socket, act, _reference, {:error, err}),
    do: put_flash(socket, :error, "#{failed(act)} failed: #{error_message(err)}")

  defp failed(:deprecate), do: "Deprecate"
  defp failed(:yank), do: "Yank"
  defp failed(:revoke), do: "Revoke"
  defp failed(:add_member), do: "Adding"
  defp failed(:update_member), do: "Changing the role"
  defp failed(:remove_member), do: "Removing"

  # Issuing a push token needs a fresh confirmation (`SystemLayer.call/5`);
  # the answer carries the token's secret, shown once.
  defp issue(socket, %{"slug" => slug} = args) do
    case SystemLayer.call(socket, {:token_issue, slug}, "registry/tokens_issue", args) do
      {:ok, %{"token" => token}, socket} when is_binary(token) ->
        socket =
          if socket.assigns.managing == slug,
            do: socket,
            else: socket |> assign(:managing, slug) |> assign_managed_idle()

        {:noreply,
         socket
         |> assign(:issued, token)
         |> put_flash(:info, "Push token issued. Copy it now — it won't be shown again.")
         |> load_managed()}

      {:ok, _no_token, socket} ->
        {:noreply, put_flash(socket, :error, @unreadable)}

      {:asked, socket} ->
        {:noreply, socket}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Issuing failed: #{error_message(reason)}")}
    end
  end

  defp sync(socket) do
    case sign(socket, "registry/sync", %{}) do
      {:ok, socket} -> put_flash(socket, :info, "Sign the sync with your passkey in the new tab.")
      {:error, reason} -> put_flash(socket, :error, "Sync failed: #{error_message(reason)}")
    end
  end

  defp sign_publisher(socket, tool, slug, what) do
    case String.trim(slug) do
      "" ->
        put_flash(socket, :error, "Name the domain of the publisher namespace.")

      slug ->
        case sign(socket, tool, %{"slug" => slug}) do
          {:ok, socket} ->
            put_flash(
              socket,
              :info,
              "Sign the #{what} of #{slug} with your passkey in the new tab."
            )

          {:error, reason} ->
            put_flash(socket, :error, "The #{what} failed: #{error_message(reason)}")
        end
    end
  end

  # The request a registry act answers, signed at the account pages in a
  # new tab through this page's layer.
  defp sign(socket, tool, args) do
    case call_tool(socket, tool, args) do
      {:ok, %{url: url}} when is_binary(url) ->
        {:ok, push_event(socket, "system_layer:hop", %{layer: SystemLayer.layer_id(), url: url})}

      {:ok, _no_page} ->
        {:error, :unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Data loading
  # ============================================================================

  # The version of the account service's terms in force and when it was
  # published, for the line the page shows. The terms are accepted once,
  # when the account is made; a later version is accepted by going on
  # using the registry, so the page asks for nothing.
  defp terms(ctx) do
    case call_tool(ctx, "registry/legal_version", %{}) do
      {:ok, %{"policy_version" => version} = answer} when is_binary(version) ->
        %{version: version, updated: updated(answer["updated_at"])}

      _unavailable ->
        nil
    end
  end

  defp updated(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%-d %B %Y")
      {:error, _unreadable} -> nil
    end
  end

  defp updated(_none), do: nil

  # The page's read of the registry, off the page's process; a read still
  # in flight is stopped, since only the newest is shown.
  defp load_registry(socket) do
    ctx = socket.assigns.context
    tag = CyfrWeb.ContextGuard.capture(ctx)
    personal = socket.assigns[:personal_namespace_slug]

    socket
    |> cancel_async(:load)
    |> start_async(:load, fn -> {tag, read_registry(ctx, personal)} end,
      supervisor: Prism.TaskSupervisor
    )
  end

  # The managed namespace's push tokens and, for a publisher's, its
  # members, read off the page's process under the push token this CYFR
  # holds for it; a read still in flight is stopped. An answer for a
  # namespace no longer managed is dropped (`managed/3`).
  defp load_managed(%{assigns: %{managing: nil}} = socket), do: socket

  defp load_managed(socket) do
    ctx = socket.assigns.context
    tag = CyfrWeb.ContextGuard.capture(ctx)
    slug = socket.assigns.managing
    publisher? = slug != socket.assigns[:personal_namespace_slug]

    socket
    |> cancel_async(:managed)
    |> start_async(
      :managed,
      fn ->
        tokens = rows(call_tool(ctx, "registry/tokens_list", %{"slug" => slug}), "tokens")

        members =
          if publisher?,
            do: rows(call_tool(ctx, "registry/members_list", %{"slug" => slug}), "members")

        {tag, slug, %{tokens: tokens, members: members}}
      end,
      supervisor: Prism.TaskSupervisor
    )
  end

  defp rows({:ok, %{} = body}, key) do
    case Map.get(body, key) do
      rows when is_list(rows) -> {:ok, Enum.filter(rows, &is_map/1)}
      _malformed -> {:error, @unreadable}
    end
  end

  defp rows({:ok, _malformed}, _key), do: {:error, @unreadable}
  defp rows({:error, reason}, _key), do: {:error, error_message(reason)}

  defp managed(%{assigns: %{managing: slug}} = socket, slug, %{tokens: tokens, members: members}),
    do: socket |> assign(:tokens, tokens) |> assign(:members, members)

  defp managed(socket, _slug, _managed), do: socket

  defp read_registry(ctx, personal) do
    namespaces = owned_namespaces(ctx, personal)
    %{terms: terms(ctx), namespaces: namespaces, components: fetch_components(ctx, namespaces)}
  end

  defp loaded(socket, %{terms: terms, namespaces: namespaces, components: components}) do
    socket =
      socket
      |> assign(:terms, terms)
      |> assign(:namespaces, namespaces)
      |> assign(:loading, false)

    case components do
      {:ok, components} -> socket |> assign(:components, components) |> assign(:error, nil)
      {:error, err} -> socket |> assign(:components, []) |> assign(:error, error_message(err))
    end
  end

  # Personal-namespace slug is already computed by `PrismWeb.Focus`; publisher
  # memberships come from `registry.whoami`. Both are strings, and a slug
  # that is both is listed once.
  defp owned_namespaces(ctx, personal) do
    memberships =
      case call_tool(ctx, "registry/whoami", %{}) do
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

  defp fetch_components(_ctx, []), do: {:ok, []}

  defp fetch_components(ctx, namespaces) do
    results =
      Enum.map(namespaces, fn ns ->
        case call_tool(ctx, "component/discover", %{"namespace" => ns}) do
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
            Components you've published to the registry. Deprecate keeps them installable with a warning; yank removes them from search and unpinned resolution.
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

      <p :if={@terms} id="registry-terms" class="text-xs text-gray-400">
        <a href={PrismWeb.Focus.path(@athanor_route, "/legal")} class="underline hover:text-gray-300">
          The account service's terms: version <span class="font-mono">{@terms.version}</span>{if @terms.updated,
            do: ", updated #{@terms.updated}"}
        </a>
      </p>

      <.card>
        <h3 class="text-sm font-semibold text-white">Publisher namespaces</h3>
        <p class="text-xs text-gray-400 mt-1">
          A publisher namespace is named after a domain you control. Claiming it tells you the DNS record to add; once it is published, verifying it makes the namespace yours and gives this CYFR its first push token.
        </p>
        <div class="grid gap-4 sm:grid-cols-2 mt-3">
          <form id="claim-publisher" phx-submit="claim-publisher" class="space-y-2">
            <label class="text-xs text-gray-500 uppercase" for="claim-publisher-slug">
              Claim a domain
            </label>
            <input
              id="claim-publisher-slug"
              name="slug"
              required
              placeholder="example.com"
              class="w-full mt-1 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white focus:border-blue-600 focus:ring-1 focus:ring-blue-600"
            />
            <button
              type="submit"
              phx-disable-with="Claiming…"
              class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700 disabled:opacity-50 whitespace-nowrap"
            >Claim</button>
          </form>
          <form id="verify-publisher" phx-submit="verify-publisher" class="space-y-2">
            <label class="text-xs text-gray-500 uppercase" for="verify-publisher-slug">
              Verify a claimed domain
            </label>
            <input
              id="verify-publisher-slug"
              name="slug"
              required
              placeholder="example.com"
              class="w-full mt-1 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white focus:border-blue-600 focus:ring-1 focus:ring-blue-600"
            />
            <button
              type="submit"
              phx-disable-with="Verifying…"
              class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700 disabled:opacity-50 whitespace-nowrap"
            >Verify</button>
          </form>
        </div>
      </.card>

      <div :if={@loading} class="flex flex-col items-center justify-center py-16 gap-3">
        <.spinner class="h-6 w-6 text-gray-400" />
        <p class="text-sm text-gray-500">Loading your registry…</p>
      </div>

      <div :if={!@loading}>
        <div :if={@namespaces == []}>
          <.empty_state message="You haven't claimed a namespace on the registry yet." />
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

        <.card :if={@namespaces != []} class="mt-6">
          <h3 class="text-sm font-semibold text-white">Your namespaces</h3>
          <p class="text-xs text-gray-400 mt-1">
            Push tokens let a CYFR publish to a namespace; a publisher namespace's administrators add and remove its members.
          </p>
          <ul class="mt-3 divide-y divide-gray-800">
            <li :for={ns <- @namespaces} class="flex items-center justify-between gap-3 py-2">
              <span class="font-mono text-sm text-gray-300">{ns}</span>
              <button
                type="button"
                phx-click="manage"
                phx-value-slug={ns}
                class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700 disabled:opacity-50 whitespace-nowrap"
              >
                Manage
              </button>
            </li>
          </ul>
        </.card>

        <.card :if={@managing} class="mt-6">
          <div class="flex items-start justify-between gap-4">
            <h3 class="text-sm font-semibold text-white">
              Manage <span class="font-mono">{@managing}</span>
            </h3>
            <button
              type="button"
              phx-click="close-manage"
              class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700 disabled:opacity-50 whitespace-nowrap"
            >Close</button>
          </div>

          <div
            :if={@issued}
            class="mt-3 rounded-lg border border-green-800 bg-green-900/30 p-3 space-y-2"
          >
            <p class="text-xs text-green-200">
              Your new push token. Copy it now — it won't be shown again.
            </p>
            <code class="block break-all font-mono text-xs text-white">{@issued}</code>
            <button
              type="button"
              phx-click="dismiss-issued"
              class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700 disabled:opacity-50 whitespace-nowrap"
            >Done</button>
          </div>

          <h4 class="mt-4 text-xs font-semibold text-gray-300 uppercase">Push tokens</h4>
          <.spinner :if={is_nil(@tokens)} class="h-4 w-4 mt-2 text-gray-400" />
          <p :if={match?({:error, _}, @tokens)} class="mt-2 text-xs text-red-300">
            {elem(@tokens, 1)}
          </p>
          <ul :if={match?({:ok, _}, @tokens)} class="mt-2 divide-y divide-gray-800">
            <li :if={elem(@tokens, 1) == []} class="py-2 text-xs text-gray-500">
              No push tokens.
            </li>
            <li
              :for={token <- token_rows(@tokens)}
              class="flex items-center justify-between gap-3 py-2 text-sm"
            >
              <div>
                <span class="text-gray-200">{token["label"]}</span>
                <p class="text-xs text-gray-500">
                  {token_line(token)}
                </p>
              </div>
              <button
                :if={is_nil(token["revoked_at"])}
                type="button"
                phx-click="ask-revoke"
                phx-value-id={token["id"]}
                class="px-2 py-1 text-xs rounded bg-red-900 text-red-200 border border-red-700 whitespace-nowrap"
              >
                Revoke
              </button>
            </li>
          </ul>
          <form id="issue-token" phx-submit="issue-token" class="mt-3 flex flex-wrap items-end gap-2">
            <div class="flex-1 min-w-[12rem]">
              <label class="text-xs text-gray-500 uppercase" for="issue-token-label">
                Label (optional)
              </label>
              <input
                id="issue-token-label"
                name="label"
                maxlength="64"
                placeholder="e.g. build server"
                class="w-full mt-1 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white focus:border-blue-600 focus:ring-1 focus:ring-blue-600"
              />
            </div>
            <button
              type="submit"
              phx-disable-with="Issuing…"
              class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700 disabled:opacity-50 whitespace-nowrap"
            >
              Issue a push token
            </button>
          </form>

          <div :if={@managing != @personal_namespace_slug}>
            <h4 class="mt-6 text-xs font-semibold text-gray-300 uppercase">Members</h4>
            <.spinner :if={is_nil(@members)} class="h-4 w-4 mt-2 text-gray-400" />
            <p :if={match?({:error, _}, @members)} class="mt-2 text-xs text-red-300">
              {elem(@members, 1)}
            </p>
            <ul :if={match?({:ok, _}, @members)} class="mt-2 divide-y divide-gray-800">
              <li
                :for={member <- member_rows(@members)}
                class="flex flex-wrap items-center justify-between gap-3 py-2 text-sm"
              >
                <span class="font-mono text-gray-200">{member["handle"]}</span>
                <form
                  id={"member-" <> member["handle"]}
                  phx-submit="update-member"
                  class="flex items-center gap-2"
                >
                  <input type="hidden" name="handle" value={member["handle"]} />
                  <select
                    name="role"
                    class="rounded bg-gray-800 border border-gray-700 px-2 py-1 text-xs text-white"
                  >
                    <option
                      :for={role <- ~w(admin member)}
                      value={role}
                      selected={member["role"] == role}
                    >
                      {role_label(role)}
                    </option>
                  </select>
                  <button
                    type="submit"
                    disabled={@acting != nil}
                    class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700 disabled:opacity-50 whitespace-nowrap"
                  >
                    Change role
                  </button>
                  <button
                    type="button"
                    phx-click="ask-remove"
                    phx-value-handle={member["handle"]}
                    class="px-2 py-1 text-xs rounded bg-red-900 text-red-200 border border-red-700 whitespace-nowrap"
                  >
                    Remove
                  </button>
                </form>
              </li>
            </ul>
            <form id="add-member" phx-submit="add-member" class="mt-3 flex flex-wrap items-end gap-2">
              <div class="flex-1 min-w-[12rem]">
                <label class="text-xs text-gray-500 uppercase" for="add-member-handle">
                  Their handle
                </label>
                <input
                  id="add-member-handle"
                  name="handle"
                  required
                  placeholder="their personal namespace"
                  class="w-full mt-1 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white focus:border-blue-600 focus:ring-1 focus:ring-blue-600"
                />
              </div>
              <select
                name="role"
                class="rounded bg-gray-800 border border-gray-700 px-2 py-2 text-xs text-white"
              >
                <option value="member">{role_label("member")}</option>
                <option value="admin">{role_label("admin")}</option>
              </select>
              <button
                type="submit"
                disabled={@acting != nil}
                class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700 disabled:opacity-50 whitespace-nowrap"
              >Add</button>
            </form>
          </div>
        </.card>
      </div>

      <.card>
        <h3 class="text-sm font-semibold text-white">Report a namespace</h3>
        <form
          id="report-namespace"
          phx-submit="report-namespace"
          class="mt-2 flex flex-wrap items-end gap-2"
        >
          <div class="flex-1 min-w-[12rem]">
            <label class="text-xs text-gray-500 uppercase" for="report-namespace-slug">
              Namespace
            </label>
            <input
              id="report-namespace-slug"
              name="slug"
              required
              placeholder="example.com"
              class="w-full mt-1 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white focus:border-blue-600 focus:ring-1 focus:ring-blue-600"
            />
          </div>
          <button
            type="submit"
            class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700 disabled:opacity-50 whitespace-nowrap"
          >Report…</button>
        </form>
      </.card>

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
                disabled={@acting != nil}
                class="px-3 py-1.5 text-xs rounded bg-red-900 text-red-100 border border-red-700 hover:bg-red-800 disabled:opacity-50"
              >
                {if @acting, do: "Yanking…", else: "Confirm yank"}
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
                disabled={@acting != nil}
                class="px-3 py-1.5 text-xs rounded bg-yellow-900 text-yellow-100 border border-yellow-700 hover:bg-yellow-800 disabled:opacity-50"
              >
                {if @acting, do: "Deprecating…", else: "Confirm deprecate"}
              </button>
            </div>
          </form>
        </div>
      </.modal>

      <.modal
        id="revoke-modal"
        show={@revoke_pending != nil}
        on_cancel={JS.push("close-revoke")}
      >
        <div class="space-y-4">
          <h3 class="text-base font-semibold text-white">Revoke this push token?</h3>
          <p class="text-xs text-gray-400">
            Anything publishing with it to <span class="font-mono">{@managing}</span>
            stops being able to. If it is the token this CYFR holds, sync your push tokens again afterwards.
          </p>
          <div class="flex justify-end gap-2">
            <button
              type="button"
              phx-click="close-revoke"
              class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700 disabled:opacity-50 whitespace-nowrap"
            >Cancel</button>
            <button
              type="button"
              phx-click="revoke-token"
              disabled={@acting != nil}
              class="px-3 py-1.5 text-xs rounded bg-red-900 text-red-100 border border-red-700 hover:bg-red-800 disabled:opacity-50"
            >
              {if @acting, do: "Revoking…", else: "Revoke"}
            </button>
          </div>
        </div>
      </.modal>

      <.modal
        id="remove-modal"
        show={@remove_pending != nil}
        on_cancel={JS.push("close-remove")}
      >
        <div class="space-y-4">
          <h3 class="text-base font-semibold text-white">
            Remove <span class="font-mono">{@remove_pending}</span>?
          </h3>
          <p class="text-xs text-gray-400">
            They stop being a member of <span class="font-mono">{@managing}</span>, and every push token they made for it is revoked.
          </p>
          <div class="flex justify-end gap-2">
            <button
              type="button"
              phx-click="close-remove"
              class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700 disabled:opacity-50 whitespace-nowrap"
            >Cancel</button>
            <button
              type="button"
              phx-click="remove-member"
              disabled={@acting != nil}
              class="px-3 py-1.5 text-xs rounded bg-red-900 text-red-100 border border-red-700 hover:bg-red-800 disabled:opacity-50"
            >
              {if @acting, do: "Removing…", else: "Remove"}
            </button>
          </div>
        </div>
      </.modal>

      <.live_component
        module={PrismWeb.ReportComponent}
        id="report"
        context={@context}
        athanor_route={@athanor_route}
      />

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

  defp token_rows({:ok, rows}), do: rows

  defp member_rows({:ok, rows}), do: Enum.filter(rows, &is_binary(&1["handle"]))

  defp token_line(token) do
    [
      {"made by ", token["handle"]},
      {"issued ", token["created_at"]},
      if(token["last_used_at"],
        do: {"last used ", token["last_used_at"]},
        else: {"never used", ""}
      ),
      {"revoked ", token["revoked_at"]}
    ]
    |> Enum.flat_map(fn
      {"never used", ""} -> ["never used"]
      {words, value} when is_binary(value) and value != "" -> [words <> value]
      _absent -> []
    end)
    |> Enum.join(" · ")
  end

  defp role_label("admin"), do: "Administrator"
  defp role_label("member"), do: "Member"

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
