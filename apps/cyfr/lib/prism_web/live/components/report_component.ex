# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ReportComponent do
  @moduledoc """
  The abuse-report modal — one owner for the category taxonomy, the
  validation, the `registry.report` call and the markup.

  It lived twice, byte-identical at birth (`ShellLive`,
  `ComponentDetailLive`) and had already drifted: one copy hardcoded the
  4096 cap the other named, and one ended its error path in `inspect/1`.

  A parent's own "Report" button resolves the target (it owns what is on
  screen) and calls `open/2` for a component or `open_namespace/2` for a
  whole namespace; everything after that is this component's.
  On success the parent receives `{:report_component, :submitted}` and
  flashes — a LiveComponent has no flash of its own.

  A copyright claim (`dmca`) is the one category the registry asks a
  signed statement of. The sheet shows its acknowledgements for that
  category alone and sends `attestations_signed` true once all are
  ticked; `registry.report` refuses a copyright claim without it. These
  are the statement's only words: the registry takes the one boolean.

  The report is sent off the event (`send_report/2`): a registry request
  has no total deadline, and the browser gives up on an event it waits on
  for 30 seconds. While it is sent the dialog stays open and says so, and
  takes neither a second submit nor a close; the answer closes it or
  shows the refusal.
  """

  use PrismWeb, :live_component

  alias Phoenix.LiveView.JS

  @categories [
    {"csam", "Child sexual abuse material"},
    {"ncii", "Non-consensual intimate imagery"},
    {"objectionable", "Violence / hate / sexual content"},
    {"malware", "Malware / unsafe code"},
    {"impersonation", "Impersonation"},
    {"dmca", "Copyright (DMCA)"},
    {"ip_infringement", "Trademark / patent infringement"},
    {"security", "Security vulnerability"},
    {"policy_violation", "Acceptable-use policy violation"},
    {"spam", "Spam"},
    {"other", "Other"}
  ]

  @details_max 4096

  @copyright "dmca"

  # The statement a copyright claim carries, ticked one sentence at a time.
  @acknowledgements [
    {"good_faith",
     "I believe in good faith that the use I report is not authorised by the copyright owner, its agent or the law."},
    {"accuracy",
     "The information in this report is accurate, and under penalty of perjury I am the copyright owner or authorised to act for the owner of an exclusive right that is allegedly infringed."},
    {"identified", "I have identified the copyrighted work and the material that infringes it."}
  ]

  @doc "Open the report modal for `target_ref` (a full component ref string)."
  def open(id, target_ref) when is_binary(target_ref),
    do: open_on(id, {:component, target_ref})

  @doc "Open the report modal for the namespace `slug`."
  def open_namespace(id, slug) when is_binary(slug), do: open_on(id, {:namespace, slug})

  defp open_on(id, target),
    do: Phoenix.LiveView.send_update(__MODULE__, [id: id, open: true, target: target] ++ blank())

  @impl true
  def mount(socket) do
    {:ok, assign(socket, [open: false, target: nil, submitting: false] ++ blank())}
  end

  defp blank, do: [category: "", details: "", acknowledged: MapSet.new(), error: nil]

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event(event, _params, %{assigns: %{submitting: true}} = socket)
      when event in ["close_report", "submit_report"],
      do: {:noreply, socket}

  def handle_event("close_report", _params, socket) do
    {:noreply, assign(socket, open: false, error: nil)}
  end

  # The form as typed, held so a change of category shows or hides the
  # acknowledgements without losing what was written or ticked.
  def handle_event("edit_report", params, socket) do
    {:noreply,
     assign(socket,
       category: Map.get(params, "category", ""),
       details: Map.get(params, "details", ""),
       acknowledged: acknowledged(params)
     )}
  end

  def handle_event("submit_report", params, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      category = params |> Map.get("category", "") |> String.trim()
      details = params |> Map.get("details", "") |> String.trim()

      cond do
        # A submit with no sheet opened on a target reports nothing.
        is_nil(socket.assigns.target) ->
          {:noreply, socket}

        # The allowlist is enforced, not just rendered: `category` is a
        # client value forwarded to the registry.
        category not in Enum.map(@categories, &elem(&1, 0)) ->
          {:noreply, assign(socket, :error, "Pick a category.")}

        details == "" ->
          {:noreply, assign(socket, :error, "Describe the issue.")}

        String.length(details) > @details_max ->
          {:noreply, assign(socket, :error, "Details too long (max #{@details_max} chars).")}

        true ->
          args =
            %{
              "action" => "report",
              "category" => category,
              "details" => details
            }
            |> target(socket.assigns.target)
            |> statement(category, acknowledged(params))

          {:noreply, socket |> assign(submitting: true, error: nil) |> send_report(args)}
      end
    end)
  end

  defp acknowledged(params) do
    ticked = Map.get(params, "acknowledgements", %{})
    for {key, _sentence} <- @acknowledgements, ticked[key] == "true", into: MapSet.new(), do: key
  end

  defp target(args, {:component, ref}), do: Map.put(args, "target_component_ref", ref)
  defp target(args, {:namespace, slug}), do: Map.put(args, "target_namespace", slug)

  defp statement(args, @copyright, acknowledged),
    do:
      Map.put(args, "attestations_signed", MapSet.size(acknowledged) == length(@acknowledgements))

  defp statement(args, _category, _acknowledged), do: args

  @impl true
  def handle_async(:report, {:ok, {tag, result}}, socket),
    do:
      CyfrWeb.ContextGuard.deliver(assign(socket, :submitting, false), tag, &reported(&1, result))

  # Only the node's shutdown stops the task (`send_report/2`).
  def handle_async(:report, {:exit, _reason}, socket), do: {:noreply, socket}

  # The registry call, off the event, run to its end (`run_to_end/1`): a
  # report stopped in flight may have reached the registry, and a person
  # left not knowing would send it again.
  defp send_report(socket, args) do
    ctx = socket.assigns.context
    tag = CyfrWeb.ContextGuard.capture(ctx)

    start_async(
      socket,
      :report,
      fn -> {tag, run_to_end(fn -> call_tool(ctx, "registry", args) end)} end,
      supervisor: Prism.TaskSupervisor
    )
  end

  defp reported(socket, {:ok, _body}) do
    send(self(), {:report_component, :submitted})
    {:noreply, assign(socket, open: false, error: nil)}
  end

  defp reported(socket, {:error, reason}),
    do: {:noreply, assign(socket, :error, PrismWeb.Ops.error_message(reason))}

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        categories: @categories,
        details_max: @details_max,
        acknowledgements: if(assigns.category == @copyright, do: @acknowledgements, else: [])
      )

    ~H"""
    <div>
      <.modal
        id={"#{@id}-modal"}
        show={@open}
        on_cancel={JS.push("close_report", target: @myself)}
      >
        <div :if={@open} class="space-y-4">
          <div>
            <h3 class="text-base font-semibold text-white">
              {if elem(@target, 0) == :namespace,
                do: "Report this namespace",
                else: "Report this component"}
            </h3>
            <p class="text-sm text-gray-400 mt-1">
              <span class="font-mono text-gray-300">{elem(@target, 1)}</span>
            </p>
            <p class="text-xs text-gray-500 mt-2">
              Your report goes to the registry's moderators. Track status under <a
                href={PrismWeb.Focus.path(@athanor_route, "/reports")}
                class="underline hover:text-gray-400"
              >My Reports</a>.
            </p>
          </div>

          <form
            id={"#{@id}-form"}
            phx-change="edit_report"
            phx-submit="submit_report"
            phx-target={@myself}
            class="space-y-3"
          >
            <div>
              <label class="text-xs text-gray-500 uppercase">Category</label>
              <select
                name="category"
                required
                class="w-full mt-1 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white focus:border-red-600 focus:ring-1 focus:ring-red-600"
              >
                <option value="">Select…</option>
                <option
                  :for={{value, label} <- @categories}
                  value={value}
                  selected={value == @category}
                >
                  {label}
                </option>
              </select>
            </div>

            <div>
              <label class="text-xs text-gray-500 uppercase">Details</label>
              <textarea
                name="details"
                required
                rows="4"
                maxlength={@details_max}
                placeholder="What's wrong? Include URLs, commit hashes, screenshots…"
                class="w-full mt-1 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white focus:border-red-600 focus:ring-1 focus:ring-red-600"
                autofocus
              >{@details}</textarea>
            </div>

            <fieldset :if={@acknowledgements != []} class="space-y-2">
              <legend class="text-xs text-gray-500 uppercase">A copyright claim states</legend>
              <label
                :for={{key, sentence} <- @acknowledgements}
                class="flex gap-2 text-xs text-gray-300"
              >
                <input
                  type="checkbox"
                  name={"acknowledgements[#{key}]"}
                  value="true"
                  checked={key in @acknowledged}
                  class="mt-0.5 rounded border-gray-700 bg-gray-800"
                />
                <span>{sentence}</span>
              </label>
            </fieldset>

            <div
              :if={@error}
              class="text-xs text-red-300 bg-red-900/40 border border-red-800 rounded px-3 py-2"
            >
              {@error}
            </div>

            <div class="flex justify-end gap-2">
              <button
                type="button"
                phx-click="close_report"
                phx-target={@myself}
                disabled={@submitting}
                class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={@submitting}
                phx-disable-with="Sending…"
                class="px-3 py-1.5 text-xs rounded bg-red-900 text-red-100 border border-red-700 hover:bg-red-800 disabled:opacity-50"
              >
                {if @submitting, do: "Sending…", else: "Submit report"}
              </button>
            </div>
          </form>
        </div>
      </.modal>
    </div>
    """
  end
end
