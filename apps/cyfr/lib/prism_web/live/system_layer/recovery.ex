# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer.Recovery do
  @moduledoc """
  The recovery prompts, which only the system layer draws: enrollment, a
  printed kit delivered again, and another printed kit. Each is under the
  action `:recovery_material`, so each change it dispatches is confirmed
  fresh where Sanctum decides it.

  The material never rests on the server. Enrollment's 32-byte seed, and
  an added kit's, are drawn in the browser with its cryptographic random
  source (`assets/js/system_layer/recovery.js`) and held there for the
  pending request alone; the signing kit's secret an added kit needs is
  typed into the prompt and held the same way. The browser submits them
  under `recovery_secret` (`recovery_submit`), the layer dispatches them
  and assigns none, and once the change is confirmed the browser submits
  the same material again (`recovery:resubmit`). A kit's three lines
  reach the browser in a push to the layer's own hook (`recovery:kit`),
  never an assign, and are drawn into the prompt there; when the person
  says they saved the kit, or the prompt ends however it ends, the
  browser forgets the material and empties the prompt (`recovery:clear`).

  A prompt names no secret (`PrismWeb.SystemLayer.Prompt`): enrollment
  names the directory this home pins, which its form shows with what
  enrolling commits to before anything is asked; a kit names the attempt
  whose kit it delivers; another kit names nothing.

  A frame never reaches one of these: no shell verb opens a recovery
  prompt, and a frame's credential is refused by every `person` action
  (`consent: :interactive`).
  """

  use Phoenix.Component

  alias PrismWeb.SystemLayer.Prompt

  @typedoc "Where a recovery prompt stands, as the layer holds it: no material, ever."
  @type state :: %{
          prompt_id: String.t(),
          phase: :form | :kit,
          attempt_id: String.t() | nil
        }

  @doc "The enrollment prompt `id`, naming the directory this home pins."
  @spec enrollment(String.t(), String.t()) :: {:ok, Prompt.t()} | {:error, :invalid_prompt}
  def enrollment(id, directory_url),
    do: build(id, :enrollment, %{directory_url: directory_url})

  @doc "The prompt `id` that delivers again the kit of the attempt `attempt_id`."
  @spec kit(String.t(), String.t()) :: {:ok, Prompt.t()} | {:error, :invalid_prompt}
  def kit(id, attempt_id), do: build(id, :kit, %{attempt_id: attempt_id})

  @doc "The prompt `id` that adds another printed kit."
  @spec holder(String.t()) :: {:ok, Prompt.t()} | {:error, :invalid_prompt}
  def holder(id), do: build(id, :holder, %{})

  defp build(id, kind, subject),
    do: Prompt.validate(%{id: id, kind: kind, action: :recovery_material, subject: subject})

  @doc "The state a recovery prompt starts in when it is shown."
  @spec start(String.t()) :: state()
  def start(prompt_id), do: %{prompt_id: prompt_id, phase: :form, attempt_id: nil}

  @doc """
  What `prompt` dispatches for the material the browser submitted
  (`params`, the event's): `{:ok, tool, args, repeat}`, `repeat` saying
  how the change is made again once confirmed — `:recovery_resubmit`, by
  the browser, which holds the material; `{:recovery_kit, attempt_id}`,
  by the layer, which holds nothing secret for it — or `{:error,
  sentence}` for material that is missing. The values are handed on, never
  kept.
  """
  @spec request(Prompt.t(), map()) ::
          {:ok, String.t(), map(), term()} | {:error, String.t()}
  def request(%{kind: :enrollment}, params) do
    with {:ok, seed} <- material(params, "recovery_secret"),
         {:ok, request_id} <- material(params, "request_id") do
      {:ok, "person/enroll", %{"recovery_secret" => seed, "request_id" => request_id},
       :recovery_resubmit}
    end
  end

  def request(%{kind: :holder}, params) do
    with {:ok, signer} <- material(params, "recovery_secret", typed: true),
         {:ok, added} <- material(Map.get(params, "holder", %{}), "recovery_secret"),
         {:ok, request_id} <- material(params, "request_id") do
      {:ok, "person/enroll_holder",
       %{
         "recovery_secret" => signer,
         "holder" => %{"kind" => "kit", "recovery_secret" => added},
         "request_id" => request_id
       }, :recovery_resubmit}
    end
  end

  def request(%{kind: :kit, subject: %{attempt_id: id}}, _params),
    do: {:ok, "person/kit", %{"attempt_id" => id}, {:recovery_kit, id}}

  defp material(params, key, opts \\ [])

  defp material(params, key, opts) when is_map(params) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" ->
        {:ok, String.trim(value)}

      _missing ->
        if Keyword.get(opts, :typed, false),
          do: {:error, "Type the recovery secret of a kit you hold now."},
          else: {:error, "This browser could not draw the kit's seed. Nothing was sent."}
    end
  end

  defp material(_params, _key, opts), do: material(%{}, "", opts)

  @doc """
  The three lines of a kit an answer carries, for the browser alone, or
  nil when it carries none (an acknowledged kit's seed is gone).
  """
  @spec kit_lines(map()) :: map() | nil
  def kit_lines(%{kit: %{identifier: identifier, directory_url: url, recovery_secret: secret}}),
    do: %{identifier: identifier, directory_url: url, recovery_secret: secret}

  def kit_lines(_answer), do: nil

  @doc "The prompt's title."
  @spec title(Prompt.t()) :: String.t()
  def title(%{kind: :enrollment}), do: "Enroll your identity"
  def title(%{kind: :kit}), do: "Your printed kit"
  def title(%{kind: :holder}), do: "Add another printed kit"

  @doc "The prompt's one-line description."
  @spec description(Prompt.t()) :: String.t()
  def description(%{kind: :enrollment}),
    do:
      "Enrolling gives you an identifier other homes know you by, and prints the kit that " <>
        "recovers it. Read what it commits you to first."

  def description(%{kind: :kit}),
    do:
      "Show this kit again to print or copy it. Each time needs a fresh confirmation, and " <>
        "once you say it is saved, its secret is erased here for good."

  def description(%{kind: :holder}),
    do:
      "Another kit is signed by a kit you hold now: type that kit's recovery secret. The new " <>
        "kit is drawn in this browser and printed once confirmed."

  attr :prompt, :map, required: true
  attr :recovery, :map, default: nil
  attr :may, :boolean, required: true
  attr :myself, :any, required: true
  attr :id, :string, required: true
  attr :button_class, :any, required: true
  attr :primary_class, :any, required: true

  @doc """
  A recovery prompt's body: what it commits to, its form, which the
  browser keeps and submits (`data-recovery`), the place the browser
  draws a kit's lines into, and once a kit is drawn the acknowledgment.
  The form and the kit's place are the browser's (`phx-update="ignore"`),
  so no render of the server's ever carries or erases what they hold. Its
  input has no `name`: only the script reads it, so a submission of the
  browser's own carries nothing.
  """
  def body(assigns) do
    assigns =
      assign(assigns,
        phase: (assigns.recovery && assigns.recovery.phase) || :form,
        form_id: "#{assigns.id}-recovery"
      )

    ~H"""
    <section class="space-y-3" data-test="recovery" data-kind={@prompt.kind} data-phase={@phase}>
      <.statements prompt={@prompt} />

      <div id={"#{@id}-recovery-#{@prompt.id}"} phx-update="ignore">
        <form
          id={@form_id}
          data-recovery={@prompt.kind}
          data-prompt={@prompt.id}
          autocomplete="off"
          class="space-y-2"
        >
          <div :if={@prompt.kind == :holder} class="space-y-1">
            <label for={"#{@id}-recovery-signer"} class="block text-sm font-medium">
              The recovery secret of a kit you hold now
            </label>
            <input
              id={"#{@id}-recovery-signer"}
              data-field="recovery_secret"
              type="text"
              autocomplete="off"
              autocapitalize="off"
              autocorrect="off"
              spellcheck="false"
              required
              data-test="recovery-signer"
              class="w-full rounded-md border border-gray-600 bg-transparent px-2 py-1 font-mono text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-400"
            />
          </div>
          <button type="submit" data-test="recovery-submit" class={@primary_class}>
            {submit_label(@prompt, @may)}
          </button>
        </form>
        <div data-recovery-kit={@prompt.id} data-test="recovery-kit" hidden></div>
      </div>

      <div :if={@phase == :kit} class="space-y-2" data-test="recovery-saved">
        <p class="text-sm">
          Print these three lines or write them down, and keep them apart from your devices. Then say you saved them: the secret is erased here, and never shown again.
        </p>
        <div class="flex flex-wrap gap-2">
          <button type="button" data-recovery-print data-test="recovery-print" class={@button_class}>
            Print
          </button>
          <button
            type="button"
            phx-click="recovery_ack"
            phx-target={@myself}
            phx-value-id={@prompt.id}
            data-test="recovery-ack"
            class={@primary_class}
          >
            I saved this kit
          </button>
        </div>
      </div>
    </section>
    """
  end

  defp submit_label(%{kind: :enrollment}, true), do: "Enroll and print my kit"
  defp submit_label(%{kind: :kit}, true), do: "Show this kit"
  defp submit_label(%{kind: :holder}, true), do: "Add and print the kit"
  defp submit_label(_prompt, false), do: "Request confirmation"

  attr :prompt, :map, required: true

  @doc """
  What a recovery prompt commits the person to, before anything is
  asked. Enrollment's are the stored preview's statements
  (`Sanctum.Recovery.enrollment_effect/1`) in the form's own words: the
  pinned directory and what its unavailability means, what losing every
  kit means, and that a recovery restores the identity alone.
  """
  def statements(%{prompt: %{kind: :enrollment}} = assigns) do
    ~H"""
    <ul class="list-disc space-y-1 pl-5 text-sm text-gray-200" data-test="recovery-statements">
      <li data-test="recovery-directory">
        Your identity is registered at the directory <span class="font-mono break-all">{@prompt.subject.directory_url}</span>, which this home pins. No other directory can be chosen here.
      </li>
      <li>
        While that directory cannot be reached, rotating your key, recovering and other homes' checks of your identity wait. If it is gone for good, they end: an identity never moves to another directory.
      </li>
      <li>
        Your printed kit recovers your identity. Anyone who holds a copy can replace your keys, so keep it apart from your devices and add a second kit before you rely on one.
      </li>
      <li>
        If every kit is lost, nothing can add one: your identity keeps working here with no way to recover it.
      </li>
      <li>
        A recovery restores your identity alone, never your private data or the homes your devices saved: you add those addresses again from surviving devices or invitations.
      </li>
      <li>
        A printed kit is the one recovery holder here; no device holds recovery material.
      </li>
    </ul>
    """
  end

  def statements(%{prompt: %{kind: :holder}} = assigns) do
    ~H"""
    <ul class="list-disc space-y-1 pl-5 text-sm text-gray-200" data-test="recovery-statements">
      <li>
        Each kit alone can replace your keys. A copied kit is someone else's way in, so keep every one apart from your devices.
      </li>
      <li>
        Adding a kit changes your identity's head: every other home ends the sessions and device certificates it bound to your current keys once it sees the change.
      </li>
    </ul>
    """
  end

  def statements(assigns) do
    ~H"""
    <p class="text-sm text-gray-200" data-test="recovery-statements">
      Anyone who sees this kit can replace your keys until you have it no more.
    </p>
    """
  end
end
