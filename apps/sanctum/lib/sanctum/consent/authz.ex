# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Authz do
  @moduledoc """
  Who may grant a consent.

  Consent is a third authorization class, belonging to neither the operator
  RBAC plane nor the runtime plane. It cannot be a permission: `:*`
  short-circuits every permission check, so no permission atom can express
  "an admin key may not do this" — and an admin key granting consent
  unattended is exactly what must not happen.

  So the decision is made on *how the caller authenticated*, not on what
  they hold:

  | Caller | May consent |
  |---|---|
  | A Sanctum session (`:oidc`) | yes — Prism web, the CLI, and device-flow-derived sessions all land here |
  | A paired device (`:device`), naming its paired client | yes — the person's own interactive client, on its device channel |
  | An API key with a capability pinned to this exact commit digest | yes, and only for that one commit |
  | A tincture session upgrade (`:session`) | **no** — this is the public tincture surface, not a console |
  | A tincture token, webhook, cron, system, or unauthenticated caller | no |
  | Anything on the guest plane | no, whatever else it carries |

  A paired client is only the device channel's: a `:device` context names
  its client (`client_id`), and a context of any other surface names
  none, so one that claims a paired client without being the channel's,
  or the channel's surface without its client, is no surface that may
  consent. The same rule holds for the interactive and staging arms
  below.

  Whichever arm admits the caller, its standing is read again as the
  grant is decided: a session must still exist, be unexpired and be its
  person's, the person not denied and the focused athanor open
  (`Sanctum.Caller.revalidate_session/1`); a key must still be unrevoked,
  its athanor's and its creator's; a paired device's certificate must be
  unexpired, its paired client active and its person still seated in the
  athanor, which revalidation reads as it does a session's. A grant needs
  the session alone, never a fresh confirmation.

  ## Sensitive changes

  `confirm/3`, `check/3` and `consume/2` are where a sensitive change is
  decided (`Sanctum.Pairing`'s action table): each deciding site passes
  the action it confirms and the request, the operation (`tool.action`)
  and its exact arguments, with the affected resource by name and any
  public facts for the preview. Nothing a client holds satisfies one; the
  proof is a pending confirmation (`Prima.Confirmation`, stored by
  `Arca.PendingConfirmations`), proven by a passkey assertion or a fresh
  re-authentication, and consumed once.

  An action that needs no fresh confirmation (`Sanctum.Pairing.fresh_required?/2`)
  is answered `:ok`: the site's own checks of who may act decide. For a
  sensitive change:

    * the context must have a person behind it who could give a proof in
      an athanor, and must not be on the guest plane; an API key's
      context opens one for the key's creator, so an MCP caller receives
      the signal and confirms in Prism;
    * a person whose keys are at another home has their head read fresh
      from their directory (`Sanctum.IdentityFreshness.fresh!/2`) when the
      change is asked or repeated, outside any transaction, and the record
      opened binds its `key_epoch`, so a rotation or a recovery voids it
      (`Arca.DirectoryHeads.advance/4`); a directory that cannot be read
      pauses the change (`:identity_stale`). Inside a caller's
      transaction, where `consume/2` runs, the head is read from the cache
      alone, as the request's revalidation left it. The proof is still
      this home's own: a passkey registered here or a fresh method this
      home verifies;
    * when the context names a confirmation (`confirmation_id`, the
      secret its signal answered), the caller's standing is read again
      and the record is consumed: it must be confirmed, unexpired and
      unvoided, name exactly this person, athanor, operation, argument
      digest and preview, and have been opened by this context's own
      credential. Consumed inside the caller's transaction (`consume/2`),
      a paired device is held there through the caller's write, so a
      revocation of it that commits after its standing was read refuses
      the change;
    * when the record named is this change's, opened by this credential,
      and still pending, the repeat came before the proof: it waits on
      that record, answered the consent signal again with the same `id`
      and the record's expiry, and nothing is opened;
    * otherwise, or when the record named does not answer, a new record
      is opened, whatever stands for the same change, and the answer is
      the consent signal `{:error, {:confirmation_required, %{id,
      operation, expires_at}}}`.

  The signal's `id` is a secret, 256 random bits drawn for this request
  and answered to it alone: it is never stored, announced, listed or
  logged. The record is stored, announced and listed under its public
  ref (`Prima.Confirmation.ref/1` of the secret), by which any client of
  the person reads and proves it (`Sanctum.Providers.Confirmation`).
  Repeating the change needs the secret, from the credential that opened
  the record, its opener: the context's paired client, frame credential,
  API key or session. So neither another session of the same person nor
  a thief holding the asking session's own token takes a change it did
  not ask for: an identical request of the thief's opens a record of its
  own, and the one the person proves is repeated only by the request
  that holds its secret.

  A record also names its asker, from what the opener already holds: a
  paired client's or an API key's name, a session's sign-in provider and
  creation time, a frame's tincture, or this home for a context no
  stored credential backs. So a person tells their own request from
  another's; the same credential yields the same name, so the secret,
  not the name, is the protection.

  `confirm/3` consumes at once, for a change whose effect is one call.
  `check/3` asks the same question and consumes nothing. `consume/2`
  consumes inside the caller's transaction, the one that opens the row
  the change writes, after `check/3` answered `:ok`; it opens nothing,
  since the caller's transaction rolls back on its refusal, and the
  caller announces the consumption after its commit (`consumed/1`).

  The arguments are bound by a keyed digest (`args_digest/1`), so a
  record names its change without holding anything guessable about a
  secret argument. The lifecycle is announced through
  `Sanctum.Telemetry.confirmation/4`, carrying the ref, the operation and
  the expiry and never the secret, the arguments or the preview.

  Overrides — granting a component more than its author declared — are
  always interactive. A key cannot mint one no matter how tightly caveated,
  because the whole point of an override is that a person looked at it.

  The scoped-key envelope is deliberately the narrowest thing that works:
  one exact commit digest, with an expiry. A general subset lattice over
  needs, tool lists, wildcard domains, paths and limits is a much larger
  design and is not needed to automate a known, previewed grant.
  """

  alias Arca.PendingConfirmations
  alias Sanctum.Context

  require Logger

  # The bytes of a confirmation's secret: 256 random bits.
  @secret_bytes 32
  # The bytes of the asker's name, at most.
  @asker_name_bytes 255

  defmodule Request do
    @moduledoc """
    What is being consented to, from the authorization plane's point of
    view: the exact commit, whether it carries an override, and the key
    capability presented (if any).
    """

    @type capability :: %{
            required(:commit_digest) => String.t(),
            required(:expires_at) => DateTime.t()
          }

    @type t :: %__MODULE__{
            commit_digest: String.t(),
            override?: boolean(),
            key_capability: capability() | nil
          }

    @enforce_keys [:commit_digest]
    defstruct [:commit_digest, override?: false, key_capability: nil]
  end

  @type granted_via :: :interactive | :scoped_key

  @typedoc """
  What a sensitive change is: the operation as `tool.action`, its exact
  arguments, and, for the preview, the affected resource by name and any
  public facts (never a secret argument's value).
  """
  @type change :: %{
          required(:operation) => String.t(),
          required(:arguments) => map(),
          optional(:resource) => String.t(),
          optional(:details) => %{optional(String.t()) => String.t() | [String.t()]}
        }

  @type refusal ::
          :guest_plane
          | :not_authenticated
          | :anonymous
          | {:surface_not_permitted, atom()}
          | :override_requires_interactive
          | :no_capability
          | :capability_digest_mismatch
          | :capability_expired
          | :invalid_request
          | :not_standing
          | :identity_stale
          | :unavailable
          | :missing_tenant
          | {:conflict, String.t()}

  @doc """
  Decide whether this caller may commit this consent.

  `now` is injectable so expiry is testable without sleeping.
  """
  @spec authorize(Context.t(), Request.t(), DateTime.t()) ::
          {:ok, granted_via()} | {:error, refusal()}
  def authorize(ctx, request, now \\ DateTime.utc_now())

  def authorize(%Context{} = ctx, %Request{commit_digest: digest}, _now)
      when not is_binary(digest) or digest == "" do
    _ = ctx
    {:error, :invalid_request}
  end

  def authorize(%Context{} = ctx, %Request{} = request, now) do
    # The plane gate comes first and applies to every arm: a context that
    # has entered a guest closure can never authorize consent, whatever
    # credentials it carries or capability it presents.
    with :ok <- check_plane(ctx),
         :ok <- check_authenticated(ctx),
         {:ok, granted_via} <- by_auth_method(ctx, request, now),
         :ok <- standing(ctx) do
      {:ok, granted_via}
    end
  end

  def authorize(_ctx, _request, _now), do: {:error, :invalid_request}

  @doc """
  Decide the sensitive change `change` (`t:change/0`), which confirms
  `action` (`Sanctum.Pairing.actions/0`), under `ctx`, where its effect is
  one call (the module doc).

  `:ok` when the action needs no fresh confirmation, or when the
  confirmation whose secret `ctx.confirmation_id` holds is consumed for
  exactly this change. Otherwise a new record is opened for this change
  and answered as the consent signal `{:error, {:confirmation_required,
  %{id, operation, expires_at}}}`, its `id` the record's secret.
  `{:error, :invalid_request}` names an action outside the table or a
  malformed change.
  """
  @spec confirm(Context.t(), Sanctum.Pairing.action(), change()) ::
          :ok | {:error, refusal() | {:confirmation_required, map()}}
  def confirm(%Context{} = ctx, action, change), do: decide(ctx, action, change, :confirm)

  @doc """
  What `confirm/3` would answer for `change`, consuming nothing: for a
  site whose effect opens a row, which asks first and consumes in the
  transaction that opens it (`consume/2`). A change that needs a
  confirmation it does not hold opens one, as `confirm/3` does.
  """
  @spec check(Context.t(), Sanctum.Pairing.action(), change()) ::
          :ok | {:error, refusal() | {:confirmation_required, map()}}
  def check(%Context{} = ctx, action, change), do: decide(ctx, action, change, :check)

  @doc """
  Consume the confirmation `change` needs, `{action, change}` as
  `confirm/3` takes them, inside the caller's transaction: the one that
  opens the row the change's effect writes, so the two commit or roll back
  together. The caller asked `check/3` first.

  `:ok` when the action needs no confirmation, or when the record
  `ctx.confirmation_id` names is consumed. It opens nothing: a record that
  no longer answers, after `check/3` said it did, is `{:error, {:conflict,
  _}}`, and the caller's transaction rolls back. The caller announces the
  consumption once its transaction committed (`consumed/1`).

  A paired device's context is held there through the caller's write:
  its person, athanor, seat, paired client and certificates are locked in
  the caller's transaction, in the standing order, before the record is,
  and the device must still stand on them as an issuance's must
  (`Sanctum.Issuance.device_held/1`). A revocation that committed after
  the device's standing was read refuses the change with one of the
  issuance's standing refusals (`Sanctum.Issuance.standing_refusals/0`),
  and one that starts later waits for the caller's commit.
  """
  @spec consume(Context.t(), {Sanctum.Pairing.action(), change()}) ::
          :ok
          | {:error,
             refusal() | Sanctum.Issuance.standing_refusal() | {:confirmation_required, map()}}
  def consume(%Context{} = ctx, {action, change}), do: decide(ctx, action, change, :consume)

  def consume(%Context{}, _change), do: {:error, :invalid_request}

  @doc """
  Announce that the record whose secret `ctx.confirmation_id` holds was
  consumed, once the transaction `consume/2` ran in committed. A context
  that names none, or a record that is not consumed, announces nothing.
  """
  @spec consumed(Context.t()) :: :ok
  def consumed(%Context{confirmation_id: id, athanor_id: a} = ctx)
      when is_binary(id) and id != "" and is_binary(a) and a != "" do
    case PendingConfirmations.get(Context.actor(ctx), Prima.Confirmation.ref(id)) do
      {:ok, %{state: "consumed"} = row} -> announce(:consumed, row)
      _other -> :ok
    end
  end

  def consumed(%Context{}), do: :ok

  @doc """
  The digest a confirmation binds its change's arguments by: HMAC-SHA256,
  under a key derived from Sanctum's cipher for this purpose
  (`derived_key/1`), over the JCS bytes of `arguments`, printed
  `sha256:<hex>`. So a record holds nothing from which a low-entropy
  secret argument could be guessed.

  Before the hash, atoms become strings (`true` and `false` stay
  booleans), a `DateTime` becomes its ISO 8601 spelling and a `nil` value
  is dropped from every map at every depth, so an absent argument and a
  null one are the same request. A float, a list holding `nil`, a string
  that is not UTF-8, any other struct or term, and a map whose keys
  collide once spelled as strings are `{:error, :invalid_request}`.
  """
  @spec args_digest(map()) :: {:ok, String.t()} | {:error, :invalid_request}
  def args_digest(arguments) when is_map(arguments) and not is_struct(arguments) do
    with {:ok, canonical} <- canonical(arguments),
         {:ok, bytes} <- Prima.JCS.encode(canonical) do
      {:ok, Prima.Digest.hmac_sha256(derived_key("args-digest"), bytes)}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  def args_digest(_arguments), do: {:error, :invalid_request}

  @doc """
  The key Sanctum derives from its cipher's primary key for one purpose of
  the confirmations it keeps (`purpose`, such as `"args-digest"`): an
  HMAC-SHA256 of the primary key over a label naming the purpose, so each
  purpose's key is independent of every other's and of the cipher's own.
  Changing the primary key changes every derived key: an open record whose
  digest was taken under the old one no longer matches, and is asked for
  again.
  """
  @spec derived_key(String.t()) :: binary()
  def derived_key(purpose) when is_binary(purpose) and purpose != "" do
    %{primary: label, keys: keys} = Sanctum.Cipher.keyring!()
    :crypto.mac(:hmac, :sha256, Map.fetch!(keys, label), "cyfr-confirmation-key/v1|" <> purpose)
  end

  @doc """
  The staging gate for plan and preview: authenticated, external-plane,
  and a surface that could ever finish the walk (`:oidc` or a paired
  `:device` interactively, `:api_key` through a digest-pinned
  capability). Staging grants nothing — the commit is where the consent
  class bites — but candidate listings are operator data, so anonymous
  and in-chain surfaces never see them.
  """
  @spec authorize_staging(Context.t()) :: :ok | {:error, refusal()}
  def authorize_staging(%Context{} = ctx) do
    with :ok <- check_plane(ctx),
         :ok <- check_authenticated(ctx),
         {:ok, method} <- surface(ctx) do
      if method in [:oidc, :device, :api_key],
        do: :ok,
        else: {:error, {:surface_not_permitted, method}}
    end
  end

  @doc """
  The interactive arm alone, for mutations that have no commit digest to
  bind — vault CRUD, profile revocation. Same plane and authentication
  gates; only an `:oidc` session or a paired `:device` passes, and no key
  capability can substitute (a digest-pinned capability is meaningless
  without a digest-shaped act). A paired device's standing is read on
  its channel, on every request, before the gate is asked
  (`Sanctum.DeviceCerts.verify_request/3`).
  """
  @spec authorize_interactive(Context.t()) :: {:ok, :interactive} | {:error, refusal()}
  def authorize_interactive(%Context{} = ctx) do
    with :ok <- check_plane(ctx),
         :ok <- check_authenticated(ctx),
         {:ok, method} <- surface(ctx) do
      if method in [:oidc, :device],
        do: {:ok, :interactive},
        else: {:error, {:surface_not_permitted, method}}
    end
  end

  @doc """
  The interactive arm for a call already inside a running chain.

  Every in-chain call runs guest-planed, so the plane conjunct of
  `authorize_interactive/1` is dropped here for all of them — not only for
  an approved card. What stands in for it is the chain's own gate: the
  authority's tool grant, minted from the caps a person consented to, was
  applied at the dispatch chokepoint before this runs. An action the
  agent's policy holds at `ask` reaches here through the card the person
  clicked; one held at `auto` reaches here on the strength of that consent
  alone. The surface half stays — only an `:oidc` session's chain gets
  through, so a key- or schedule-started run of the same formula is
  refused here exactly as it is at the door.
  """
  @spec authorize_interactive_in_chain(Context.t()) :: {:ok, :interactive} | {:error, refusal()}
  def authorize_interactive_in_chain(%Context{} = ctx) do
    with :ok <- check_authenticated(ctx) do
      case ctx.auth_method do
        :oidc -> {:ok, :interactive}
        method -> {:error, {:surface_not_permitted, method}}
      end
    end
  end

  @doc """
  Render a refusal as the sentence the caller reads — the ONE spelling of
  this vocabulary's prose. Every surface that answers a consent refusal
  (`Sanctum.Providers.Profile`, the MCP dispatch gate via
  `Sanctum.Unauthorized`) renders through here, so the phrasing cannot
  fork per surface.
  """
  @spec message(refusal() | term()) :: String.t()
  def message({:surface_not_permitted, method}),
    do: "Consent needs an interactive sign-in; this surface (#{method}) cannot consent"

  def message(:guest_plane), do: "A call from inside a running component cannot consent"
  def message(:not_authenticated), do: "Consent requires authentication"
  def message(:anonymous), do: "An anonymous caller cannot consent"

  def message(:no_capability),
    do: "This key carries no consent capability"

  def message(:capability_digest_mismatch),
    do: "The key's consent capability pins a different commit digest"

  def message(:capability_expired), do: "The key's consent capability has expired"

  def message(:override_requires_interactive),
    do: "A consent override needs an interactive sign-in"

  def message(:invalid_request), do: "The consent request is not valid"

  def message(:not_standing),
    do: "Your sign-in or key no longer stands here; sign in again to decide this"

  def message(:unavailable), do: "Your standing could not be checked; try again"

  def message(:identity_stale),
    do: "Your identity's current state could not be read from its directory; try again shortly"

  def message(:missing_tenant),
    do: "A change that needs a fresh confirmation is made in an athanor; open one first"

  def message({:conflict, message}) when is_binary(message), do: message

  # This IS the vocabulary module — an unknown term here is a producer bug,
  # logged and generalized, never inspected onto the wire (the catch-all
  # `inspect/1` undid the closed union above).
  def message(other) do
    Logger.warning("[Sanctum.Consent.Authz] unrenderable consent refusal: #{inspect(other)}")
    "The consent request is not valid"
  end

  # ============================================================================
  # Private
  # ============================================================================

  # A sensitive change's decision: an action of the table and a
  # well-formed change first, then the action's need. The change carries
  # its argument digest from here on.
  defp decide(ctx, action, change, mode) do
    with :ok <- known_action(action),
         {:ok, change} <- change(change) do
      if Sanctum.Pairing.fresh_required?(action, ctx),
        do: sensitive(ctx, action, change, mode),
        else: :ok
    end
  end

  defp known_action(action) do
    if action in Sanctum.Pairing.actions(), do: :ok, else: {:error, :invalid_request}
  end

  defp change(%{operation: operation, arguments: arguments} = change)
       when is_binary(operation) and is_map(arguments) do
    with true <- Prima.Manifest.Tincture.operation_name?(operation),
         [] <- Map.keys(change) -- [:operation, :arguments, :resource, :details],
         {:ok, digest} <- args_digest(arguments) do
      {:ok, Map.put(change, :args_digest, digest)}
    else
      _malformed -> {:error, :invalid_request}
    end
  end

  defp change(_change), do: {:error, :invalid_request}

  # A person who could give a proof, in an athanor, off the guest plane; a
  # person whose keys are here; and the preview the record binds.
  defp sensitive(ctx, action, change, mode) do
    with :ok <- confirmer(ctx),
         {:ok, epoch} <- identity_epoch(ctx.user_id, mode),
         {:ok, preview} <- preview(ctx, change) do
      expected = %{
        user_id: ctx.user_id,
        operation: change.operation,
        args_digest: change.args_digest,
        preview: preview,
        opener: opener(ctx)
      }

      case ctx.confirmation_id do
        id when is_binary(id) and id != "" ->
          named(ctx, {action, change, preview, epoch}, expected, id, mode)

        _none ->
          ask(ctx, {action, change, preview, epoch}, mode)
      end
    end
  end

  defp confirmer(%Context{plane: :guest}), do: {:error, :guest_plane}
  defp confirmer(%Context{authenticated: false}), do: {:error, :not_authenticated}
  defp confirmer(%Context{anonymous: true}), do: {:error, :anonymous}

  defp confirmer(%Context{user_id: user_id, athanor_id: athanor_id, auth_method: method}) do
    cond do
      not Prima.PersonId.person?(user_id) -> {:error, {:surface_not_permitted, method}}
      not (is_binary(athanor_id) and athanor_id != "") -> {:error, :missing_tenant}
      true -> :ok
    end
  end

  # A person whose keys are held at another home: their head's `key_epoch`,
  # read fresh from their directory before their fresh confirmation, never
  # from their own home, which may be the stolen one. Inside a caller's
  # transaction (a `consume/2`, or a caller that holds one open) the
  # directory is never read: the cache answers, within its bound, as the
  # request's own revalidation outside the transaction left it. A local
  # person, and a person with no identity row, binds none.
  defp identity_epoch(user_id, mode) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, %{provenance: "remote", identifier: identifier}} when is_binary(identifier) ->
        identifier
        |> remote_head(mode == :consume or Arca.in_transaction?())
        |> case do
          {:ok, %{key_epoch: epoch}} -> {:ok, epoch}
          {:refused, :identity_stale} -> {:error, :identity_stale}
          {:error, :unavailable} -> {:error, :unavailable}
        end

      {:ok, %{provenance: "remote"}} ->
        {:error, :unavailable}

      {:ok, _local} ->
        {:ok, nil}

      {:error, :not_found} ->
        {:ok, nil}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp remote_head(identifier, true = _in_transaction),
    do: Sanctum.IdentityFreshness.fresh?(identifier)

  defp remote_head(identifier, false), do: Sanctum.IdentityFreshness.fresh!(identifier)

  # The secret-free preview the deciding site's request yields: this home,
  # the athanor by name, the operation, the resource by name and the
  # public facts the site passed. A detail named as a secret refuses.
  defp preview(ctx, change) do
    with {:ok, athanor} <- athanor_name(ctx.athanor_id) do
      case Prima.Confirmation.Preview.new(
             home: Sanctum.Person.home(),
             athanor: athanor,
             operation: change.operation,
             resource: Map.get(change, :resource),
             details: Map.get(change, :details)
           ) do
        {:ok, preview} -> {:ok, preview}
        {:error, _malformed} -> {:error, :invalid_request}
      end
    end
  end

  defp athanor_name(athanor_id) do
    case Sanctum.Tenancy.Athanors.get(athanor_id) do
      {:ok, %{name: name}} when is_binary(name) and name != "" ->
        if Prima.Identity.Encoding.text?(name, Prima.Confirmation.Preview.max_text()),
          do: {:ok, name},
          else: {:ok, athanor_id}

      {:ok, _unnamed} ->
        {:ok, athanor_id}

      {:error, :not_found} ->
        {:ok, athanor_id}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  # The record the context names, for this exact change, after the
  # caller's standing is read again. A record that does not answer is
  # asked for again, except inside a caller's transaction.
  defp named(ctx, asked, expected, id, mode) do
    actor = Context.actor(ctx)

    with :ok <- standing(ctx) do
      case mode do
        :consume ->
          with :ok <- device_held(ctx), do: consume_named(actor, id, expected)

        :check ->
          case PendingConfirmations.check(actor, id, expected) do
            :ok -> :ok
            {:error, reason} -> reask(ctx, asked, id, reason)
          end

        :confirm ->
          case PendingConfirmations.consume(actor, id, expected) do
            {:ok, row} ->
              announce(:consumed, row)
              :ok

            {:error, reason} ->
              reask(ctx, asked, id, reason)
          end
      end
    end
  end

  # A paired device is held through the caller's write, in the caller's
  # transaction (`Sanctum.Issuance.device_held/1`): the person, the
  # athanor, the seat, the paired client and its certificates locked in
  # the standing order, before the record is, and the device's standing
  # asked over them. So a revocation that committed after the standing
  # read above refuses the change, with one of the issuance's standing
  # refusals and the caller's transaction rolled back, and one that starts
  # later waits for the change to commit. Any other context takes no hold
  # here: a session's or a key's standing read above locks its rows in the
  # caller's transaction (`standing/1`).
  defp device_held(ctx) do
    case Sanctum.Issuance.device_held(ctx) do
      :ok -> :ok
      {:error, :database_error} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp consume_named(actor, id, expected) do
    with :ok <- PendingConfirmations.check(actor, id, expected),
         {:ok, _row} <- PendingConfirmations.consume(actor, id, expected) do
      :ok
    else
      {:error, _stale} ->
        {:error, {:conflict, "The confirmation for this change no longer stands; ask again"}}
    end
  end

  # A record found past its expiry is announced as expired; any record
  # that does not answer is asked for again. A store that could not answer
  # is no verdict. A repeat before the proof (`:not_confirmed`, which the
  # store answers only for this exact change's unexpired pending record,
  # opened by this same credential) waits on that record: the asker is
  # answered the secret it presented and the record's expiry again, and
  # nothing is opened, so repeating early never mints a new secret or, at
  # the opener's bound, voids the record the person is proving.
  defp reask(_ctx, _asked, _id, :database_error), do: {:error, :unavailable}

  defp reask(ctx, asked, id, :not_confirmed) do
    case PendingConfirmations.get(Context.actor(ctx), Prima.Confirmation.ref(id)) do
      {:ok, %{state: state} = row} when state in ["pending", "confirmed"] ->
        {:error, {:confirmation_required, signal(id, row)}}

      {:error, :database_error} ->
        {:error, :unavailable}

      _ended ->
        ask(ctx, asked, :check)
    end
  end

  defp reask(ctx, asked, id, :expired) do
    case PendingConfirmations.get(Context.actor(ctx), Prima.Confirmation.ref(id)) do
      {:ok, row} -> announce(:expired, row)
      _other -> :ok
    end

    ask(ctx, asked, :check)
  end

  defp reask(ctx, asked, _id, _reason), do: ask(ctx, asked, :check)

  # Open a new record for this change under a secret drawn for this
  # request, and answer the secret as the consent signal: the record is
  # stored, announced and listed under the secret's ref alone. A caller's
  # transaction opens nothing.
  defp ask(_ctx, _asked, :consume), do: {:error, :invalid_request}

  defp ask(ctx, {action, change, preview, epoch}, _mode) do
    secret = "cnf_" <> Prima.Identity.Encoding.b64(:crypto.strong_rand_bytes(@secret_bytes))

    with {:ok, seconds} <- confirmation_seconds(),
         {:ok, record} <-
           Prima.Confirmation.new(
             id: Prima.Confirmation.ref(secret),
             home: Sanctum.Person.home(),
             rp_id: Sanctum.Passkeys.rp_id(),
             athanor: ctx.athanor_id,
             person: ctx.user_id,
             operation: change.operation,
             args_digest: change.args_digest,
             action: Atom.to_string(action),
             preview: preview,
             challenge: :crypto.strong_rand_bytes(Prima.Confirmation.challenge_bytes()),
             expires_at: System.os_time(:millisecond) + seconds * 1000
           ) do
      case PendingConfirmations.open(Context.actor(ctx), %{
             record: record,
             opener: opener(ctx),
             asker: asker(ctx),
             identity_key_epoch: epoch
           }) do
        {:ok, row} ->
          announce_voided(ctx, Map.get(row, :voided, []))
          announce(:opened, row)
          {:error, {:confirmation_required, signal(secret, row)}}

        # A remote person's head moved between its fresh read and the open:
        # the change pauses, as one whose head could not be confirmed does.
        {:error, :stale_key_epoch} ->
          {:error, :identity_stale}

        {:error, reason} ->
          Logger.warning(
            "[Sanctum.Consent.Authz] a pending confirmation could not be opened: " <>
              inspect(reason)
          )

          {:error, :unavailable}
      end
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, _malformed} -> {:error, :invalid_request}
    end
  end

  # The records an open voided to keep its opener within the store's bound
  # (`Arca.PendingConfirmations.open_per_opener/0`), announced as any void
  # is: read back by ref for the operation and expiry the announcement
  # carries. One that cannot be read is not announced.
  defp announce_voided(ctx, refs) do
    for ref <- refs do
      case PendingConfirmations.get(Context.actor(ctx), ref) do
        {:ok, %{state: "voided"} = row} -> announce(:voided, row)
        _unread -> :ok
      end
    end

    :ok
  end

  # The consent signal: the secret, answered to the asking request alone,
  # with the record's operation and expiry.
  defp signal(secret, row),
    do: %{id: secret, operation: row.operation, expires_at: row.expires_at}

  # The credential a context acts under, which alone repeats a change it
  # asked for: its paired client, its frame credential, its API key or its
  # session (by the token's hash, raw bytes printed in hex, which
  # addresses the row and opens nothing). A context no stored credential backs, one the server built
  # itself, is `unbound`: no credential a caller presents yields it.
  defp opener(%Context{auth_method: :device, client_id: id}) when is_binary(id) and id != "",
    do: "client:" <> id

  defp opener(%Context{frame: %{id: id}}) when is_binary(id) and id != "", do: "frame:" <> id

  defp opener(%Context{auth_method: :api_key, api_key_id: id}) when is_binary(id) and id != "",
    do: "key:" <> id

  defp opener(%Context{session_token_hash: hash}) when is_binary(hash) and hash != "",
    do: "session:" <> Base.encode16(hash, case: :lower)

  defp opener(%Context{}), do: "unbound"

  # A name for the client that asked, from what the opener already holds,
  # in the order `opener/1` reads it: a paired client's name, a frame's
  # tincture, an API key's name, a session's sign-in provider and creation
  # time from its own row, or this home for a context no stored credential
  # backs. A hint for the person reading the record: a name that cannot be
  # read is left out, never a refusal.
  defp asker(%Context{auth_method: :device, client_id: id} = ctx)
       when is_binary(id) and id != "",
       do: named_asker("client", client_name(ctx, id))

  defp asker(%Context{frame: %{id: id} = frame}) when is_binary(id) and id != "",
    do: named_asker("frame", tincture(frame))

  defp asker(%Context{auth_method: :api_key, api_key_id: id} = ctx)
       when is_binary(id) and id != "",
       do: named_asker("key", key_name(ctx, id))

  defp asker(%Context{session_token_hash: hash}) when is_binary(hash) and hash != "" do
    case Arca.SessionStorage.get_session(hash) do
      {:ok, %{provider: provider, inserted_at: %DateTime{} = since}} ->
        "session"
        |> named_asker(provider)
        |> Map.put("since", DateTime.to_iso8601(since))

      _unread ->
        named_asker("session", nil)
    end
  end

  defp asker(%Context{}), do: named_asker("unbound", Sanctum.Person.home())

  # The name is cut to at most 255 bytes at a UTF-8 boundary, never 255
  # graphemes, so however many bytes its characters take the asker stays
  # far inside the store's bound and a hint never becomes a refusal. A name
  # with no valid UTF-8 prefix is left out.
  defp named_asker(kind, name) when is_binary(name) do
    case utf8_prefix(name, @asker_name_bytes) do
      "" -> %{"kind" => kind}
      bounded -> %{"kind" => kind, "name" => bounded}
    end
  end

  defp named_asker(kind, _unnamed), do: %{"kind" => kind}

  @doc false
  # The longest prefix of `text` that is at most `max` bytes and valid
  # UTF-8: a character the cut would split is dropped whole.
  @spec utf8_prefix(binary(), non_neg_integer()) :: binary()
  def utf8_prefix(text, max) when is_binary(text) and is_integer(max) and max >= 0,
    do: valid_prefix(binary_part(text, 0, min(byte_size(text), max)))

  defp valid_prefix(""), do: ""

  defp valid_prefix(bytes) do
    if String.valid?(bytes),
      do: bytes,
      else: valid_prefix(binary_part(bytes, 0, byte_size(bytes) - 1))
  end

  defp client_name(ctx, client_id) do
    case Arca.PairedClients.list(Context.actor(ctx), user_id: ctx.user_id, standing: :all) do
      {:ok, clients} -> Enum.find_value(clients, &(&1.id == client_id && &1.label))
      {:error, _unanswered} -> nil
    end
  end

  defp key_name(ctx, key_id) do
    case Arca.ApiKeyStorage.get_key_by_id(Context.actor(ctx), key_id) do
      {:ok, %{name: name}} -> name
      {:error, _unanswered} -> nil
    end
  end

  defp tincture(%{reference: %{publisher: publisher, name: name}})
       when is_binary(publisher) and is_binary(name),
       do: publisher <> "/" <> name

  defp tincture(_frame), do: nil

  @doc false
  # The lifecycle announcement for a stored record: its ref, operation and
  # expiry, and nothing else (`Sanctum.Telemetry.confirmation/4`).
  @spec announce(Sanctum.Telemetry.confirmation_kind(), map()) :: :ok
  def announce(kind, %{ref: ref, athanor_id: athanor_id, user_id: user_id} = row) do
    Sanctum.Telemetry.confirmation(kind, athanor_id, user_id, %{
      ref: ref,
      operation: row.operation,
      expires_at: row.expires_at
    })
  end

  @doc false
  # How long a pending confirmation stays open (`confirmation_seconds`).
  @spec confirmation_seconds() :: {:ok, pos_integer()} | {:error, :unavailable}
  def confirmation_seconds, do: seconds_setting("confirmation_seconds")

  @doc false
  # A duration setting of this domain, in whole positive seconds: an
  # unreadable store is `:unavailable`, and an uninstalled roster raises.
  @spec seconds_setting(String.t()) :: {:ok, pos_integer()} | {:error, :unavailable}
  def seconds_setting(key) when is_binary(key) do
    case Arca.PlatformSettings.effective(key) do
      {:ok, seconds} when is_integer(seconds) and seconds > 0 ->
        {:ok, seconds}

      {:ok, other} ->
        Logger.error(
          "[Sanctum.Consent.Authz] the stored #{key} #{inspect(other)} is not a " <>
            "positive whole number of seconds; refusing until it is"
        )

        {:error, :unavailable}

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, reason} when reason in [:uninstalled, :unknown_key] ->
        raise "[Sanctum.Consent.Authz] #{key} cannot be read: the setting is #{reason}"
    end
  end

  # The arguments in the digest's domain (`args_digest/1`).
  defp canonical(nil), do: :drop
  defp canonical(value) when is_boolean(value), do: {:ok, value}
  defp canonical(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp canonical(value) when is_integer(value), do: {:ok, value}

  defp canonical(value) when is_binary(value),
    do: if(String.valid?(value), do: {:ok, value}, else: :error)

  defp canonical(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}

  defp canonical(value) when is_map(value) and not is_struct(value) do
    if collide?(value) do
      :error
    else
      Enum.reduce_while(value, {:ok, %{}}, fn {key, member}, {:ok, acc} ->
        case {canonical_key(key), canonical(member)} do
          {{:ok, name}, {:ok, canonical}} -> {:cont, {:ok, Map.put(acc, name, canonical)}}
          {{:ok, _name}, :drop} -> {:cont, {:ok, acc}}
          _invalid -> {:halt, :error}
        end
      end)
    end
  end

  defp canonical(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn member, {:ok, acc} ->
      case canonical(member) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | acc]}}
        _drop_or_invalid -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp canonical(_value), do: :error

  # Two keys spelled alike once they are strings name one argument twice,
  # even when one of them is nil: refused rather than guessed.
  defp collide?(map) do
    names = for {key, _member} <- map, do: canonical_key(key)
    length(Enum.uniq(names)) != length(names)
  end

  defp canonical_key(key) when is_atom(key) and not is_boolean(key) and not is_nil(key),
    do: {:ok, Atom.to_string(key)}

  defp canonical_key(key) when is_binary(key),
    do: if(String.valid?(key), do: {:ok, key}, else: :error)

  defp canonical_key(_key), do: :error

  @doc false
  # The caller's standing, read again as a grant or a sensitive change is
  # decided: whatever credential admitted it must still stand
  # (`Sanctum.Caller.revalidate_session/1`), a paired device's client and
  # its person's seat among them. A context no stored credential backs
  # keeps its establishment contract. A session's and a key's rows are
  # locked in the standing order, inside a caller's transaction in it, so
  # a write that asks here commits only while they stand
  # (`Sanctum.Passkeys`). A paired device's client and seat are read, not
  # locked: a sensitive change's consumption holds the device in the
  # caller's transaction (`consume/2`), and a credential write holds it as
  # an issuance does (`Sanctum.Issuance.device_hold/1`).
  @spec standing(Context.t()) ::
          :ok
          | {:error, :not_authenticated | :not_standing | :identity_stale | :unavailable}
  def standing(%Context{} = ctx) do
    case Sanctum.Caller.revalidate_session(ctx) do
      {:ok, _current} -> :ok
      {:error, reason} -> {:error, standing_refusal(reason)}
    end
  end

  @doc false
  # What a revalidation's refusal is here: a person whose remote identity
  # could not be read fresh is `:identity_stale`, and a refusal this
  # vocabulary does not know is `:unavailable`, never a crash, so a refusal
  # revalidation learns later still refuses.
  @spec standing_refusal(term()) ::
          :not_authenticated | :not_standing | :identity_stale | :unavailable
  def standing_refusal(:unauthenticated), do: :not_authenticated
  def standing_refusal(reason) when reason in [:not_standing, :not_member], do: :not_standing
  def standing_refusal(:identity_stale), do: :identity_stale
  def standing_refusal(:unavailable), do: :unavailable

  def standing_refusal(other) do
    Logger.error(
      "[Sanctum.Consent.Authz] revalidation answered an unknown refusal " <>
        "#{Prima.LoggerContext.shape(other)}; refusing as unavailable"
    )

    :unavailable
  end

  # The surface a context authenticated through. A paired client is the
  # device channel's alone: a `:device` context names its client, and no
  # other context names one, so a context that claims either without the
  # other is refused as the surface it claims.
  defp surface(%Context{auth_method: :device, client_id: client_id}) when is_binary(client_id),
    do: {:ok, :device}

  defp surface(%Context{auth_method: method, client_id: nil}) when method != :device,
    do: {:ok, method}

  defp surface(%Context{auth_method: method}), do: {:error, {:surface_not_permitted, method}}

  defp check_plane(%Context{plane: :guest}), do: {:error, :guest_plane}
  defp check_plane(%Context{}), do: :ok

  defp check_authenticated(%Context{authenticated: false}), do: {:error, :not_authenticated}
  defp check_authenticated(%Context{anonymous: true}), do: {:error, :anonymous}
  defp check_authenticated(%Context{}), do: :ok

  defp by_auth_method(ctx, request, now) do
    with {:ok, method} <- surface(ctx), do: by_surface(method, request, now)
  end

  # A Sanctum session. Note this is deliberately the *loaded session*
  # provenance, so a CLI that device-flowed into a session consents like the
  # console does — same class of act, same authorization. A paired device
  # is the person's own interactive client, and grants what their session
  # grants.
  defp by_surface(method, _request, _now) when method in [:oidc, :device],
    do: {:ok, :interactive}

  defp by_surface(:api_key, request, now) do
    if request.override? do
      {:error, :override_requires_interactive}
    else
      check_capability(request, now)
    end
  end

  # Everything else is a surface that must not be able to consent — most
  # sharply `:session`, which is produced only by the tincture upgrade path
  # and would otherwise let a public tincture surface grant authority.
  defp by_surface(method, _request, _now), do: {:error, {:surface_not_permitted, method}}

  defp check_capability(%Request{key_capability: nil}, _now), do: {:error, :no_capability}

  defp check_capability(%Request{key_capability: capability} = request, now)
       when is_map(capability) do
    cond do
      not exact_digest?(capability, request.commit_digest) ->
        {:error, :capability_digest_mismatch}

      expired?(capability, now) ->
        {:error, :capability_expired}

      true ->
        {:ok, :scoped_key}
    end
  end

  defp check_capability(_request, _now), do: {:error, :no_capability}

  # Pinned to one exact commit, never a prefix or a pattern: the envelope is
  # "this grant, already previewed", not "grants like this one".
  defp exact_digest?(capability, commit_digest) do
    case Map.get(capability, :commit_digest) do
      value when is_binary(value) and value != "" ->
        Plug.Crypto.secure_compare(value, commit_digest)

      _ ->
        false
    end
  end

  # An expiry is part of the envelope, not an option: the moduledoc
  # promises "one exact commit digest, with an expiry", so a capability
  # without one (or with a malformed one) is refused, never eternal.
  defp expired?(capability, now) do
    case Map.get(capability, :expires_at) do
      %DateTime{} = expires_at -> DateTime.compare(now, expires_at) != :lt
      _ -> true
    end
  end
end
