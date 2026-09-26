# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer.Prompt do
  @moduledoc """
  The shape of a system layer prompt, held before anything is drawn.

      %{id: binary, kind: kind, action: Sanctum.Pairing.action() | nil, subject: map}

  `action` names the confirmation class the prompt needs
  (`Sanctum.Pairing.required_class/1`): a grant, an unlock and a credential
  entry each name one; a sign-in and safe mode confirm nothing Sanctum
  classes and carry `nil`. `subject` is what the prompt shows and what its
  confirmation dispatches:

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
    * `:safe_mode` — a `Prism.SafeMode` value.

  Anything else is refused as `:invalid_prompt`: nothing is drawn.
  """

  @kinds [:grant, :unlock, :sign_in, :credential_entry, :safe_mode]
  @keys [:id, :kind, :action, :subject]
  @max_id_bytes 128

  @default_field "API_KEY"
  @field_name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/

  @typedoc "What a prompt asks for."
  @type kind :: :grant | :unlock | :sign_in | :credential_entry | :safe_mode

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

  defp action(kind, nil) when kind in [:sign_in, :safe_mode], do: :ok

  defp action(kind, action) when kind in [:grant, :unlock, :credential_entry] do
    if action in Sanctum.Pairing.actions(), do: :ok, else: {:error, :invalid_prompt}
  end

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

  defp subject(_kind, _subject), do: {:error, :invalid_prompt}

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
