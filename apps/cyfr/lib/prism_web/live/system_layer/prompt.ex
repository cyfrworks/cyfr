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

    * `:grant` — the consent walk the prompt's body, the consent sheet
      (`PrismWeb.ConsentSheetComponent`), starts from and keeps in step:
      `ref`, the `athanor_id` it was planned in, the `plan` as
      `profile.plan` answers it (`plan_token`, `expected_consent_revision`,
      the needs and the vault entries that can meet them, its rows), the
      `preview` of the decisions — a `Prima.ConsentPreview` (`v`, `rows`,
      `origins`, `commit_digest`) with the `proof` a commit presents, or
      `nil` for a plan whose closure is `unresolved`, which has nothing to
      preview or commit — the `decisions` payload (`%{"ref" => ref,
      "bindings" => [...]}`, with the `selections`, `origins`, `subset` and
      `label` it names), committed through `profile.commit`, and optionally
      `session_expires_at`, when the person's session ends (RFC 3339, as
      `session.whoami` answers it), which the sheet's "this session"
      lifetime is held to, and `suggestion_refused`, the home's sentence
      when it refused to preview the plan's suggestions and the grant
      opened with nothing bound (`PrismWeb.SystemLayer.grant_prompt/4`
      builds it);
    * `:credential_entry` — `name`, the vault entry to create, and
      optionally `field`, the name its one field is stored under
      (`API_KEY` when absent), created through `vault.create` as an `api_key`
      entry with the destination and disclosure the person enters in the
      prompt's form. A prompt a grant's sheet raises for a need ("Connect
      your <provider> account") also names the `athanor_id` its grant was
      planned in, which the entry is made in or not at all, the need's
      `provider`, the `hosts` and `paths` it declares and whether the
      component reads the value itself (`disclose_needed`), which the form
      is prefilled from,
      and `return`, the grant it goes back to: `%{prompt, need}` for a need
      of the app, `%{prompt, from, dep, need}` for a dependency's. Any
      other prompt names none of them, and nothing is prefilled;
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
      asking request was answered never enters a prompt;
    * `:enrollment`, `:kit` and `:holder` — recovery material, each under
      the action `:recovery_material` (`PrismWeb.SystemLayer.Recovery`
      builds them): enrollment names the `directory_url` this home pins,
      which its form shows before anything is asked; a kit names the
      `attempt_id` of the enrollment or added kit whose kit is delivered
      again; another kit names nothing. No seed, kit line or installation
      token is ever a prompt's subject: the browser draws and holds the
      seed, and a kit's lines go to the browser alone.

  Anything else is refused as `:invalid_prompt`: nothing is drawn.
  """

  @recovery_kinds [:enrollment, :kit, :holder]
  @kinds [:grant, :unlock, :sign_in, :credential_entry, :safe_mode, :pairing, :confirmation] ++
           @recovery_kinds
  @keys [:id, :kind, :action, :subject]
  @max_id_bytes 128

  @default_field "API_KEY"
  @field_name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  @prefill_keys [:athanor_id, :provider, :hosts, :paths, :disclose_needed, :return]

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
          | :enrollment
          | :kit
          | :holder

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

  @doc "The kinds of prompt that show recovery material, which only the layer draws."
  @spec recovery_kinds() :: [kind()]
  def recovery_kinds, do: @recovery_kinds

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
  defp action(kind, :recovery_material) when kind in @recovery_kinds, do: :ok

  defp action(_kind, _action), do: {:error, :invalid_prompt}

  defp subject(
         :grant,
         %{
           ref: ref,
           athanor_id: athanor_id,
           plan: %{} = plan,
           preview: preview,
           decisions: decisions
         } = subject
       )
       when is_binary(ref) and ref != "" and is_binary(athanor_id) and athanor_id != "" do
    session_end = Map.get(subject, :session_expires_at)
    refused = Map.get(subject, :suggestion_refused)

    if plan?(plan) and preview?(preview, plan) and decisions?(decisions, ref) and
         instant?(session_end) and sentence?(refused),
       do:
         {:ok,
          %{ref: ref, athanor_id: athanor_id, plan: plan, preview: preview, decisions: decisions}
          |> Prima.MapUtil.put_present(:session_expires_at, session_end)
          |> Prima.MapUtil.put_present(:suggestion_refused, refused)},
       else: {:error, :invalid_prompt}
  end

  defp subject(:credential_entry, %{name: name} = subject)
       when is_binary(name) and name != "" do
    field = Map.get(subject, :field, @default_field)
    prefill = Map.take(subject, @prefill_keys)

    if map_size(Map.drop(subject, [:name, :field | @prefill_keys])) == 0 and is_binary(field) and
         Regex.match?(@field_name, field) and prefill?(prefill),
       do: {:ok, Map.merge(%{name: name, field: field}, prefill)},
       else: {:error, :invalid_prompt}
  end

  defp subject(:unlock, subject), do: optional_text(subject, :name)
  defp subject(:sign_in, subject), do: optional_text(subject, :message)

  defp subject(:safe_mode, subject) do
    if Prism.SafeMode.active?(subject), do: {:ok, subject}, else: {:error, :invalid_prompt}
  end

  defp subject(:pairing, subject) when map_size(subject) == 0, do: {:ok, %{}}

  # The directory the form names is this home's pinned one, an https
  # directory URL; a kit is named by its attempt's id; neither carries a
  # seed.
  defp subject(:enrollment, %{directory_url: url} = subject)
       when map_size(subject) == 1 and is_binary(url) do
    if Prima.Identity.Encoding.directory_url?(url) and String.starts_with?(url, "https://"),
      do: {:ok, %{directory_url: url}},
      else: {:error, :invalid_prompt}
  end

  defp subject(:kit, %{attempt_id: id} = subject)
       when map_size(subject) == 1 and is_binary(id) and id != "" and byte_size(id) <= 128,
       do: {:ok, %{attempt_id: id}}

  defp subject(:holder, subject) when map_size(subject) == 0, do: {:ok, %{}}

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

  # What a credential entry raised for a need is prefilled from, and the
  # grant it returns to: all of them or none.
  defp prefill?(prefill) when map_size(prefill) == 0, do: true

  defp prefill?(%{
         athanor_id: athanor_id,
         provider: provider,
         hosts: hosts,
         paths: paths,
         disclose_needed: disclose,
         return: return
       })
       when is_binary(athanor_id) and athanor_id != "" and is_binary(provider) and provider != "" and
              is_boolean(disclose) do
    words?(hosts) and words?(paths) and return?(return)
  end

  defp prefill?(_partial), do: false

  defp words?(list), do: is_list(list) and Enum.all?(list, &(is_binary(&1) and &1 != ""))

  defp return?(%{prompt: prompt, need: need} = return)
       when is_binary(prompt) and prompt != "" and is_binary(need) and need != "" do
    case Map.drop(return, [:prompt, :need]) do
      empty when map_size(empty) == 0 ->
        true

      %{from: from, dep: dep} = dep_return when map_size(dep_return) == 2 ->
        ref?(from) and ref?(dep)

      _other ->
        false
    end
  end

  defp return?(_return), do: false

  defp ref?(ref), do: is_binary(ref) and ref != ""

  defp sentence?(nil), do: true
  defp sentence?(text), do: is_binary(text) and text != ""

  defp instant?(nil), do: true
  defp instant?(at) when is_binary(at), do: match?({:ok, _at, _offset}, DateTime.from_iso8601(at))
  defp instant?(_at), do: false

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

  # The preview a grant prompt opens with: a `Prima.ConsentPreview`, held
  # to its typed rows, with the proof the commit presents beside it. A
  # plan whose closure is unresolved has none, and offers nothing to
  # commit.
  defp preview?(nil, %{unresolved: %{}}), do: true

  defp preview?(%{v: v, rows: rows, origins: origins, commit_digest: digest, proof: proof}, _plan)
       when is_binary(proof) and proof != "" do
    match?(
      {:ok, %Prima.ConsentPreview{}},
      Prima.ConsentPreview.decode(%{
        "v" => v,
        "rows" => rows,
        "origins" => origins,
        "commit_digest" => digest
      })
    )
  end

  defp preview?(_preview, _plan), do: false

  defp decisions?(%{"ref" => ref, "bindings" => bindings} = decisions, ref)
       when is_list(bindings) do
    origins?(Map.get(decisions, "origins")) and is_map(Map.get(decisions, "subset", %{})) and
      label?(Map.get(decisions, "label"))
  end

  defp decisions?(_decisions, _ref), do: false

  defp origins?(nil), do: true
  defp origins?(origins), do: match?({:ok, _origins}, Prima.Origin.parse_list(origins))

  defp label?(nil), do: true
  defp label?(label), do: is_binary(label) and label != ""
end
