# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer.Recovery do
  @moduledoc """
  The recovery prompts, which only the system layer draws: enrollment, a
  recovery code shown again (kind `:kit`), and another recovery code
  (kind `:holder`). Each is under the action `:recovery_material`, so each
  change it dispatches is confirmed fresh where Sanctum decides it.

  The material never rests on the server. Enrollment's 32-byte secret, and
  an added code's, are drawn in the browser with its cryptographic random
  source (`assets/js/system_layer/recovery.js`) and held there for the
  pending request alone; the recovery code that signs an added one is
  typed into the prompt and held the same way. The browser submits them
  (`recovery_submit`): a drawn secret under `recovery_secret`, the typed
  code under `recovery_code`. The layer dispatches them and assigns none,
  and once the change is confirmed the browser submits the same material
  again (`recovery:resubmit`). A recovery code an answer carries reaches
  the browser in a push to the layer's own hook (`recovery:code`), never
  an assign, and is drawn into the prompt there; when the person says
  they saved it, or the prompt ends however it ends, the browser forgets
  the material and empties the prompt (`recovery:clear`).

  A prompt names no secret (`PrismWeb.SystemLayer.Prompt`): enrollment
  names the directory this home pins, which its form shows with what
  enrolling commits to before anything is asked; a recovery code shown
  again names the attempt whose code it is; another code names nothing.

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

  @doc "The prompt `id` that shows again the recovery code of the attempt `attempt_id`."
  @spec recovery_code(String.t(), String.t()) :: {:ok, Prompt.t()} | {:error, :invalid_prompt}
  def recovery_code(id, attempt_id), do: build(id, :kit, %{attempt_id: attempt_id})

  @doc "The prompt `id` that adds another recovery code."
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
  the browser, which holds the material; `{:recovery_code, attempt_id}`,
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
    with {:ok, signer} <- material(params, "recovery_code", typed: true),
         {:ok, added} <- material(Map.get(params, "holder", %{}), "recovery_secret"),
         {:ok, request_id} <- material(params, "request_id") do
      {:ok, "person/recovery_code_add",
       %{
         "recovery_code" => signer,
         "holder" => %{"recovery_secret" => added},
         "request_id" => request_id
       }, :recovery_resubmit}
    end
  end

  def request(%{kind: :kit, subject: %{attempt_id: id}}, _params),
    do: {:ok, "person/recovery_code", %{"attempt_id" => id}, {:recovery_code, id}}

  defp material(params, key, opts \\ [])

  defp material(params, key, opts) when is_map(params) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" ->
        {:ok, String.trim(value)}

      _missing ->
        if Keyword.get(opts, :typed, false),
          do: {:error, "Type a recovery code you hold now."},
          else:
            {:error, "This browser could not draw the recovery code's secret. Nothing was sent."}
    end
  end

  defp material(_params, _key, opts), do: material(%{}, "", opts)

  @doc """
  The recovery code an answer carries, for the browser alone, or nil when
  it carries none (a code the person said they saved is gone).
  """
  @spec code(map()) :: %{code: String.t()} | nil
  def code(%{code: code}) when is_binary(code), do: %{code: code}
  def code(_answer), do: nil

  @doc "The prompt's title."
  @spec title(Prompt.t()) :: String.t()
  def title(%{kind: :enrollment}), do: "Enroll your identity"
  def title(%{kind: :kit}), do: "Your recovery code"
  def title(%{kind: :holder}), do: "Add another recovery code"

  @doc "The prompt's one-line description."
  @spec description(Prompt.t()) :: String.t()
  def description(%{kind: :enrollment}),
    do:
      "Enrolling gives you an identifier any CYFR knows you by, and prints the kit that " <>
        "recovers it. Read what it commits you to first."

  def description(%{kind: :kit}),
    do:
      "Show your recovery code again. Each time needs a fresh confirmation, and once you say " <>
        "you saved it, CYFR forgets it."

  def description(%{kind: :holder}), do: "A recovery code you hold approves the new one."

  attr :prompt, :map, required: true
  attr :recovery, :map, default: nil
  attr :may, :boolean, required: true
  attr :myself, :any, required: true
  attr :id, :string, required: true
  attr :primary_class, :any, required: true

  @doc """
  A recovery prompt's body: what it commits to, its form, which the
  browser keeps and submits (`data-recovery`), the place the browser
  draws a recovery code into (`data-recovery-code`), and once a code is
  drawn the saved block. The form and the code's place are the browser's
  (`phx-update="ignore"`), so no render of the server's ever carries or
  erases what they hold. Its input has no `name`: only the script reads
  it, so a submission of the browser's own carries nothing.
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
              Your recovery code
            </label>
            <input
              id={"#{@id}-recovery-signer"}
              data-field="recovery_code"
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
        <div data-recovery-code={@prompt.id} hidden></div>
      </div>

      <div :if={@phase == :kit} class="space-y-2" data-test="recovery-saved">
        <p class="text-sm">
          If this CYFR is ever lost, this is the one thing that brings you back. Save it in your password manager, or print this page. Once you say you saved it, CYFR forgets it.
        </p>
        <div class="flex flex-wrap gap-2">
          <button
            type="button"
            phx-click="recovery_ack"
            phx-target={@myself}
            phx-value-id={@prompt.id}
            data-test="recovery-ack"
            class={@primary_class}
          >
            I saved it
          </button>
        </div>
      </div>
    </section>
    """
  end

  defp submit_label(%{kind: :enrollment}, true), do: "Enroll and print my kit"
  defp submit_label(%{kind: :kit}, true), do: "Show my recovery code"
  defp submit_label(%{kind: :holder}, true), do: "Continue"
  defp submit_label(_prompt, false), do: "Request confirmation"

  attr :prompt, :map, required: true

  @doc """
  What a recovery prompt commits the person to, before anything is
  asked. Enrollment's are the stored preview's statements
  (`Sanctum.Recovery.enrollment_effect/1`) in the form's own words: the
  pinned directory and what its unavailability means, what losing every
  recovery holder means, and that a recovery restores the identity alone.
  """
  def statements(%{prompt: %{kind: :enrollment}} = assigns) do
    ~H"""
    <ul class="list-disc space-y-1 pl-5 text-sm text-gray-200" data-test="recovery-statements">
      <li data-test="recovery-directory">
        Your identity is registered at the directory <span class="font-mono break-all">{@prompt.subject.directory_url}</span>, which this CYFR pins. No other directory can be chosen here.
      </li>
      <li>
        While that directory cannot be reached, key rotation, recovery and identity checks by any other CYFR wait. If it is gone for good, they end: an identity never moves to another directory.
      </li>
      <li>
        Your printed kit recovers your identity. Anyone who holds a copy can replace your keys, so keep it apart from your devices and add a second kit before you rely on one.
      </li>
      <li>
        If every kit is lost, nothing can add one: your identity keeps working here with no way to recover it.
      </li>
      <li>
        A recovery restores your identity alone, never your private data or the CYFR addresses your devices saved: you add those addresses again from surviving devices or invitations.
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
        Each recovery code alone can replace your keys. A copied code is someone else's way in, so keep every one apart from your devices.
      </li>
      <li>
        Adding a recovery code changes your identity's head: every other CYFR ends the sessions and device certificates it bound to your current keys once it sees the change.
      </li>
    </ul>
    """
  end

  def statements(assigns) do
    ~H"""
    <p class="text-sm text-gray-200" data-test="recovery-statements">
      Anyone who sees your recovery code can replace your keys until you have it no more.
    </p>
    """
  end
end
