# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer.Prompt do
  @moduledoc """
  The shape of a system layer prompt, held before anything is drawn.

      %{id: binary, kind: kind, action: Sanctum.Pairing.action() | nil, subject: map}

  `action` names the action the prompt confirms, from Sanctum's action
  table (`Sanctum.Pairing.actions/0`): a grant, an unlock, a credential
  entry and the pairing prompt each name one; a sign-in and safe mode
  confirm no action and carry `nil`, as does a confirmation whose record
  this client could not read. Whether the change needs a fresh
  confirmation is decided where the change is, never by the prompt.
  `subject` is what the prompt shows and what its confirmation
  dispatches:

    * `:grant` — the consent walk as `PrismWeb.ConsentSheetComponent` holds
      it: `ref`, the `plan` (`plan_token`, `expected_consent_revision`), the
      `preview` (`summary`, `proof`, `commit_digest`) and the `decisions`
      payload (`%{"ref" => ref, "bindings" => [...]}`), committed through
      `profile.commit`;
    * `:credential_entry` — `name`, the vault entry to create, and
      optionally `field`, the name its one field is stored under
      (`API_KEY` when absent), created through `vault.create` as an `api_key`
      entry;
    * `:unlock` — optionally `name`, the vault entry it concerns;
    * `:sign_in` — optionally `message`, a sentence saying why;
    * `:safe_mode` — a `Prism.SafeMode` value;
    * `:pairing` — nothing: the prompt reads the person's paired clients
      itself and begins a pairing through `pairing.begin`, whose answer's
      link it draws as a QR code (`PrismWeb.SystemLayer.Pairing`);
    * `:confirmation` — one pending confirmation as `confirmation.pending`
      lists it: its public `ref`, the `operation` and `action` it confirms,
      the `preview` and `asker` the home stored, its `expires_at`, the
      `webauthn` request options a passkey proves it with and the
      `methods` the person can prove it by, and `own`, whether this client
      asked for it. A client that asked but cannot read the list carries
      the ref, operation and expiry alone, the rest `nil`. The secret the
      asking request was answered never enters a prompt.

  Anything else is refused as `:invalid_prompt`: nothing is drawn.
  """

  @kinds [:grant, :unlock, :sign_in, :credential_entry, :safe_mode, :pairing, :confirmation]
  @keys [:id, :kind, :action, :subject]
  @max_id_bytes 128

  @default_field "API_KEY"
  @field_name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/

  @methods ~w(passkey oidc email)

  @typedoc "What a prompt asks for."
  @type kind ::
          :grant
          | :unlock
          | :sign_in
          | :credential_entry
          | :safe_mode
          | :pairing
          | :confirmation

  @typedoc "A prompt."
  @type t :: %{
          id: String.t(),
          kind: kind(),
          action: Sanctum.Pairing.action() | nil,
          subject: map()
        }

  @doc "The kinds of prompt the layer draws."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The field a credential entry is stored under when its subject names none."
  @spec default_field() :: String.t()
  def default_field, do: @default_field

  @doc """
  `term` held to a prompt's shape: `{:ok, prompt}` with a credential
  entry's `field` filled in, or `{:error, :invalid_prompt}`.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_prompt}
  def validate(%{id: id, kind: kind, action: action, subject: %{} = subject} = prompt)
      when map_size(prompt) == length(@keys) and is_binary(id) and id != "" and
             byte_size(id) <= @max_id_bytes and kind in @kinds do
    with :ok <- action(kind, action),
         {:ok, subject} <- subject(kind, subject) do
      {:ok, %{id: id, kind: kind, action: action, subject: subject}}
    end
  end

  def validate(_other), do: {:error, :invalid_prompt}

  @doc "The id a refusal is reported under: the prompt's own when it has one."
  @spec id_of(term()) :: String.t() | nil
  def id_of(%{id: id}) when is_binary(id), do: id
  def id_of(_other), do: nil

  @doc "The id of the confirmation prompt for the record `ref` names: one per record."
  @spec confirmation_id(String.t()) :: String.t()
  def confirmation_id(ref) when is_binary(ref), do: "confirmation-" <> ref

  @doc """
  The `:confirmation` prompt for `entry`, one `confirmation.pending` entry
  (atom keys, as the operation answers it), or for a bare `%{ref:,
  operation:, expires_at:}` when the list could not be read; `own` says
  whether this client asked for it. `{:error, :invalid_prompt}` for
  anything else.
  """
  @spec confirmation(map(), boolean()) :: {:ok, t()} | {:error, :invalid_prompt}
  def confirmation(%{ref: ref} = entry, own) when is_binary(ref) and is_boolean(own) do
    subject =
      entry
      |> Map.take([:ref, :operation, :preview, :asker, :expires_at, :webauthn, :methods])
      |> Map.put(:action, Map.get(entry, :action))
      |> Map.put(:own, own)

    validate(%{
      id: confirmation_id(ref),
      kind: :confirmation,
      action: action_named(Map.get(entry, :action)),
      subject: subject
    })
  end

  def confirmation(_entry, _own), do: {:error, :invalid_prompt}

  # The table's action an entry's `action` spells, or none.
  defp action_named(name) when is_binary(name),
    do: Enum.find(Sanctum.Pairing.actions(), &(Atom.to_string(&1) == name))

  defp action_named(_name), do: nil

  defp action(kind, nil) when kind in [:sign_in, :safe_mode, :confirmation], do: :ok

  defp action(kind, action) when kind in [:grant, :unlock, :credential_entry, :confirmation] do
    if action in Sanctum.Pairing.actions(), do: :ok, else: {:error, :invalid_prompt}
  end

  defp action(:pairing, :device_pairing), do: :ok

  defp action(_kind, _action), do: {:error, :invalid_prompt}

  defp subject(:grant, %{ref: ref, plan: %{} = plan, preview: %{} = preview, decisions: decisions})
       when is_binary(ref) and ref != "" do
    if plan?(plan) and preview?(preview) and decisions?(decisions, ref),
      do: {:ok, %{ref: ref, plan: plan, preview: preview, decisions: decisions}},
      else: {:error, :invalid_prompt}
  end

  defp subject(:credential_entry, %{name: name} = subject)
       when is_binary(name) and name != "" do
    field = Map.get(subject, :field, @default_field)

    if map_size(Map.drop(subject, [:name, :field])) == 0 and is_binary(field) and
         Regex.match?(@field_name, field),
       do: {:ok, %{name: name, field: field}},
       else: {:error, :invalid_prompt}
  end

  defp subject(:unlock, subject), do: optional_text(subject, :name)
  defp subject(:sign_in, subject), do: optional_text(subject, :message)

  defp subject(:safe_mode, subject) do
    if Prism.SafeMode.active?(subject), do: {:ok, subject}, else: {:error, :invalid_prompt}
  end

  defp subject(:pairing, subject) when map_size(subject) == 0, do: {:ok, %{}}

  defp subject(
         :confirmation,
         %{ref: ref, operation: operation, expires_at: %DateTime{}, own: own} = subject
       )
       when is_boolean(own) do
    optional = Map.drop(subject, [:ref, :operation, :expires_at, :own])

    if Prima.Confirmation.ref?(ref) and Prima.Manifest.Tincture.operation_name?(operation) and
         Enum.all?(optional, &optional_field?/1),
       do:
         {:ok,
          Map.merge(
            %{action: nil, preview: nil, asker: nil, webauthn: nil, methods: nil},
            subject
          )},
       else: {:error, :invalid_prompt}
  end

  defp subject(_kind, _subject), do: {:error, :invalid_prompt}

  # A confirmation's fields beyond its ref, operation and expiry: absent,
  # or the shape `confirmation.pending` answers.
  defp optional_field?({_key, nil}), do: true
  defp optional_field?({:action, action}), do: is_binary(action)
  defp optional_field?({:preview, %{"operation" => op}}), do: is_binary(op)
  defp optional_field?({:asker, %{"kind" => kind}}), do: is_binary(kind)
  defp optional_field?({:webauthn, %{"challenge" => challenge}}), do: is_binary(challenge)

  defp optional_field?({:methods, methods}),
    do: is_list(methods) and Enum.all?(methods, &(&1 in @methods))

  defp optional_field?(_field), do: false

  defp optional_text(subject, key) do
    case Map.drop(subject, [key]) do
      rest when map_size(rest) == 0 ->
        case Map.get(subject, key) do
          nil -> {:ok, %{}}
          text when is_binary(text) and text != "" -> {:ok, %{key => text}}
          _other -> {:error, :invalid_prompt}
        end

      _rest ->
        {:error, :invalid_prompt}
    end
  end

  defp plan?(%{plan_token: token} = plan) when is_binary(token) and token != "" do
    case Map.get(plan, :expected_consent_revision) do
      nil -> true
      revision -> is_integer(revision) and revision >= 0
    end
  end

  defp plan?(_plan), do: false

  defp preview?(%{summary: summary, proof: proof, commit_digest: digest})
       when is_list(summary) and is_binary(proof) and is_binary(digest),
       do: Enum.all?(summary, &is_binary/1)

  defp preview?(_preview), do: false

  defp decisions?(%{"ref" => ref, "bindings" => bindings}, ref) when is_list(bindings), do: true
  defp decisions?(_decisions, _ref), do: false
end
