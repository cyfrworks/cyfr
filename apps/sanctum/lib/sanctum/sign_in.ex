# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SignIn do
  @moduledoc """
  Sign-in, fresh confirmation and registry signatures by a request this
  CYFR mints and an answer a key of the person's account signs
  (`Prima.SignIn`, `ARCHITECTURE.md` §9.2–§9.3). The CYFR decides
  everything: it mints the request, verifies the answer against the
  account's log, asks its own rules and mints its own session.

  ## The request

  `request/3` mints a request for one purpose, `:sign_in`, `:confirm` or
  `:registry`, with this CYFR's origin (`Sanctum.origin/0`, in its one
  spelling) as its audience and the sign-in page on it, `/login`, as its
  return. It is held here, keyed by its challenge, for its lifetime
  (`Prima.SignIn.lifetime_ms/0`, five minutes), bound to what asked for
  it, as its browser's session cookie or its channel holds it: a browser
  not signed in yet, by its session's forgery token (`{:browser, token}`,
  the value the sign-in tickets are bound to); a person's browser, by
  their session's token hash (`{:session, hash}`), so the answer is taken
  only under the session that asked; or a device's channel (`{:channel,
  id}`, its paired client, with the identifier the channel speaks for). A
  browser is sent to the account pages of this deployment's directory
  (`Sanctum.directory_url/0`) with the request in the fragment: the sign
  page (`url`), or for a new account the new page with the name a
  surface offers. What each purpose holds beside its request:

    * `:sign_in` — the admission a new person comes in under, when the
      surface that asked carries one: the setup token (`{:setup, token}`)
      or an invitation's code hash (`{:invitation, hash}`,
      `Sanctum.Invitations.code_hash/1`). Without one a new person is
      admitted only as the door admits their identifier.
    * `:confirm` — the pending confirmation `ref` of the asking context's
      own person in its athanor, still pending; the request's `subject` is
      the record's digest, which the system layer previewed before the
      hop, and `back` is where the browser returns to.
    * `:registry` — the `Prima.RegistryRequest` the caller is asked to
      sign, without signer and signature, and `back`.

  ## The answer

  `answer/3` takes a passkey's answer, as the fragment the account pages
  returned to `/login` or decoded, or a device's
  (`Prima.SignIn.DeviceAnswer`), with the binding of what delivered it,
  and checks it in this order, the first failure refusing:

    1. the answer's challenge names a request held here, which is taken
       and so spent whichever way the rest goes (`:answer_refused`
       otherwise: unknown, spent, or past its lifetime);
    2. the request is bound to what delivered the answer, unexpired and
       for this audience (`:answer_refused`): a replayed answer meets a
       spent request, and an answer from another browser or channel, or
       one past the request's expiry, signs no one in;
    3. the answering account's log, read within freshness's policy
       (`Sanctum.IdentityFreshness`): the cached head within its bound, or
       for an account this CYFR never read, its whole log at this
       deployment's directory (`:identity_stale`, `:identity_gone`,
       `:unavailable`);
    4. the signature over the request's digest by a key the log lists
       (`Prima.SignIn.verify/4`, `:answer_refused`);
    5. what the purpose does:
       * `:sign_in` asks about the identifier's person here. A person this
         CYFR holds is asked about by the door (`Sanctum.Door.sign_in/1`);
         one an invitation came with redeems it first
         (`Sanctum.Invitations.redeem_for/2`), and an invitation that can
         no longer be used grants nothing: a person the door admits anyway
         is signed in, anyone else is refused `:invitation_invalid`. A new
         person is admitted under the request's admission or the door
         (`Sanctum.Newcomer.admit/2`). A session is then minted bound to
         the key that signed and the head it was verified under, under the
         issuance fence (`Sanctum.Session.create/2`, `:stale_head` when the
         head moved meanwhile).
       * `:confirm` requires the answer's identifier to be the
         confirmation's person's (`Sanctum.Tenancy.Users.identifier/1`, a
         `usr_` id never compared with a `per_` one), then confirms the
         record by that key at that head, under the fence
         (`Arca.PendingConfirmations.confirm/3`), and announces it
         (`Sanctum.Consent.Authz.announce/2`); the asking client repeats
         the change, which consumes it.
       * `:registry` requires the answer's identifier to be the caller's,
         and answers the signed request's bytes
         (`Prima.SignIn.registry_bytes/2`) for the registry client to
         send.

  Every refusal of steps 1, 2 and 4 is `:answer_refused`, with no detail:
  the precise reason is logged by its shape. A request held on another
  member, or after this one restarted, is unknown here.

  ## Registry answers

  `record_claim/2` and `record_namespace/2`: the namespace lands on the
  `users` row the moment the registry's answer to a claim or a token mint
  names it, before, and regardless of, the push tokens. That row is what
  every request reads (`Sanctum.Namespace`).
  """

  require Logger

  alias Prima.Identity.Encoding
  alias Prima.SignIn.{DeviceAnswer, PasskeyAnswer}
  alias Sanctum.Context
  alias Sanctum.Tenancy.Users

  @return_path "/login"

  @typedoc """
  What a request is bound to: a browser not signed in yet, by its
  session's forgery token; a person's browser, by their session's token
  hash; or a device's channel, by its paired client's id.
  """
  @type binding :: {:browser, String.t()} | {:session, binary()} | {:channel, String.t()}

  @typedoc """
  The admission a new person comes in under at a sign-in: the setup token,
  an invitation's code hash, or none (the door's verdict on the
  identifier).
  """
  @type admission :: {:setup, String.t()} | {:invitation, String.t()} | nil

  @typedoc """
  The account page a browser is sent to: the sign page, or the new page
  with the name it offers (nil for none).
  """
  @type page :: :sign | {:new, String.t() | nil}

  @typedoc """
  A minted request, and for a browser the account page it is sent to with
  the request in the fragment.
  """
  @type minted :: %{request: Prima.SignIn.t(), url: String.t() | nil}

  @typedoc "What an accepted answer did, by its purpose."
  @type outcome ::
          %{purpose: :sign_in, user: Users.user(), session_token: String.t()}
          | %{purpose: :confirm, ref: String.t(), back: String.t() | nil}
          | %{purpose: :registry, user_id: String.t(), signed: binary(), back: String.t() | nil}

  # ---- the request -------------------------------------------------------------

  @doc """
  Mint and hold a request for `purpose`, bound to `binding` (the module
  doc). `opts`:

    * `:admission` — `:sign_in`'s `t:admission/0`;
    * `:page` — the account page a browser is sent to (`t:page/0`,
      `:sign` by default);
    * `:ctx` — the asking context, for `:confirm` and `:registry`: a person
      signed in, in an athanor;
    * `:ref` — `:confirm`'s pending confirmation;
    * `:registry_request` — `:registry`'s `Prima.RegistryRequest`;
    * `:back` — where a browser returns after a `:confirm` or `:registry`
      answer: a path on this CYFR;
    * `:identifier` — the account a channel speaks for, for a
      `{:channel, id}` binding.

  Refusals: `:no_directory` (a browser's request with no directory to
  send it to), `{:not_found, "confirmation", ref}`, `:not_pending`,
  `:unauthenticated`, `{:invalid_argument, sentence}`, `:unavailable`.
  """
  @spec request(Prima.SignIn.purpose(), binding(), keyword()) ::
          {:ok, minted()} | {:error, term()}
  def request(purpose, binding, opts \\ []) when is_list(opts) do
    with :ok <- binding(binding, opts),
         {:ok, home} <- home(),
         {:ok, held} <- held(purpose, opts),
         {:ok, request} <- minted(purpose, home, held),
         {:ok, url} <- url(binding, request, Keyword.get(opts, :page, :sign)),
         :ok <- hold(request, binding, held) do
      {:ok, %{request: request, url: url}}
    end
  end

  defp binding({kind, token}, _opts)
       when kind in [:browser, :session] and is_binary(token) and token != "",
       do: :ok

  defp binding({:channel, id}, opts) when is_binary(id) and id != "" do
    if Encoding.identifier?(opts[:identifier]),
      do: :ok,
      else: {:error, {:invalid_argument, "A channel's request names the account it speaks for"}}
  end

  defp binding(_binding, _opts),
    do: {:error, {:invalid_argument, "A request is bound to a browser or a device's channel"}}

  # This CYFR's origin in its one spelling: a request's audience. An origin
  # served under a path names no audience a request can carry.
  defp home do
    case Encoding.canonical_home(Sanctum.origin()) do
      {:ok, home} ->
        {:ok, home}

      :error ->
        Logger.error(
          "[Sanctum.SignIn] this CYFR's origin is no scheme and host a request can name as its " <>
            "audience; no request is minted"
        )

        {:error, :unavailable}
    end
  end

  # What each purpose holds beside its request.
  defp held(:sign_in, opts) do
    case Keyword.get(opts, :admission) do
      nil ->
        {:ok, %{admission: nil, identifier: opts[:identifier]}}

      {:setup, token} = admission when is_binary(token) ->
        {:ok, %{admission: admission, identifier: opts[:identifier]}}

      {:invitation, hash} = admission when is_binary(hash) ->
        {:ok, %{admission: admission, identifier: opts[:identifier]}}

      _other ->
        {:error, {:invalid_argument, "A sign-in comes in under the setup token or an invitation"}}
    end
  end

  defp held(:confirm, opts) do
    with {:ok, ctx} <- person(opts[:ctx]),
         {:ok, row} <- pending(ctx, opts[:ref]) do
      {:ok,
       %{
         subject: row.digest,
         ref: row.ref,
         athanor_id: ctx.athanor_id,
         user_id: ctx.user_id,
         identifier: opts[:identifier],
         back: back(opts[:back])
       }}
    end
  end

  defp held(:registry, opts) do
    with {:ok, ctx} <- person(opts[:ctx]) do
      case Keyword.get(opts, :registry_request) do
        %Prima.RegistryRequest{signer: nil, sig: nil} = registry ->
          {:ok,
           %{
             registry_request: registry,
             user_id: ctx.user_id,
             identifier: opts[:identifier],
             back: back(opts[:back])
           }}

        _other ->
          {:error,
           {:invalid_argument, "A registry request to sign names no signer and carries no sig"}}
      end
    end
  end

  defp held(_purpose, _opts),
    do: {:error, {:invalid_argument, "A request is for sign_in, confirm or registry"}}

  # A person signed in, in an athanor, off the guest plane.
  defp person(%Context{plane: plane, user_id: user_id, athanor_id: athanor_id} = ctx)
       when plane != :guest and is_binary(user_id) and is_binary(athanor_id) and athanor_id != "" do
    if ctx.authenticated and not ctx.anonymous and Prima.PersonId.person?(user_id),
      do: {:ok, ctx},
      else: {:error, :unauthenticated}
  end

  defp person(_ctx), do: {:error, :unauthenticated}

  # The context's own pending confirmation, by its public ref.
  defp pending(%Context{user_id: user_id} = ctx, ref) when is_binary(ref) do
    case Arca.PendingConfirmations.get(Context.actor(ctx), ref) do
      {:ok, %{user_id: ^user_id, state: "pending"} = row} -> {:ok, row}
      {:ok, %{user_id: ^user_id}} -> {:error, :not_pending}
      {:ok, _another} -> {:error, {:not_found, "confirmation", ref}}
      {:error, :not_found} -> {:error, {:not_found, "confirmation", ref}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp pending(_ctx, _ref),
    do: {:error, {:invalid_argument, "A confirmation is named by its ref"}}

  # A path on this CYFR, never another origin's.
  defp back("/" <> rest = path) do
    if String.starts_with?(rest, ["/", "\\"]) or String.contains?(path, ["#", "\\"]),
      do: nil,
      else: path
  end

  defp back(_path), do: nil

  defp minted(purpose, home, held) do
    Prima.SignIn.new(
      purpose: purpose,
      audience: home,
      challenge: :crypto.strong_rand_bytes(Prima.SignIn.challenge_bytes()),
      expires_at: System.system_time(:millisecond) + Prima.SignIn.lifetime_ms(),
      return: home <> @return_path,
      subject: held[:subject],
      registry_request: held[:registry_request]
    )
    |> case do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        Logger.error(
          "[Sanctum.SignIn] a request could not be minted: " <> Prima.LoggerContext.shape(reason)
        )

        {:error, :unavailable}
    end
  end

  # A browser goes to the account pages of this deployment's directory;
  # a channel's request travels over the channel.
  defp url({:channel, _id}, _request, _page), do: {:ok, nil}

  defp url({_browser, _token}, request, page) do
    with {:ok, directory} <- directory() do
      fragment = Prima.SignIn.fragment(request)

      case page do
        :sign ->
          {:ok, directory <> "/account/sign#" <> fragment}

        {:new, name} ->
          {:ok,
           directory <>
             "/account/new#name=" <> URI.encode_www_form(name || "") <> "&request=" <> fragment}
      end
    end
  end

  # The directory's origin: its account pages are served at its root.
  defp directory do
    case Sanctum.directory_url() do
      url when is_binary(url) ->
        if Encoding.directory_url?(url),
          do: {:ok, url |> Encoding.directory_origin() |> elem(0)},
          else: {:error, :no_directory}

      _none ->
        {:error, :no_directory}
    end
  end

  defp hold(request, binding, held) do
    entry = Map.merge(held, %{request: request, binding: binding})

    case Arca.Cache.put(key(request.challenge), entry, Prima.SignIn.lifetime_ms()) do
      :ok -> :ok
      {:error, _unavailable} -> {:error, :unavailable}
    end
  end

  defp key(challenge), do: {:sign_in_request, challenge}

  # ---- the answer --------------------------------------------------------------

  @doc """
  Check an answer against the request held for its challenge, delivered
  by `binding`, and do what its purpose does (the module doc). `answer`
  is a passkey's answer as its fragment, or a decoded
  `Prima.SignIn.PasskeyAnswer` or `Prima.SignIn.DeviceAnswer`. `opts`:
  `:now`, the clock in milliseconds, the system's by default.

  Refusals: `:answer_refused`, `:identity_stale`, `:identity_gone`,
  `:stale_head`, `{:door, reason}`, `:invitation_invalid`,
  `:setup_closed`, `:not_set_up`, `:not_standing`, the newcomer's own
  refusals (`Sanctum.Newcomer.admit/2`), `:unavailable`.
  """
  @spec answer(String.t() | PasskeyAnswer.t() | DeviceAnswer.t(), binding(), keyword()) ::
          {:ok, outcome()} | {:error, term()}
  def answer(answer, binding, opts \\ [])

  def answer(fragment, binding, opts) when is_binary(fragment) do
    with {:ok, map} <- Prima.SignIn.parse_fragment(fragment),
         {:ok, answer} <- PasskeyAnswer.decode(map) do
      answer(answer, binding, opts)
    else
      {:error, reason} -> refused(reason)
    end
  end

  def answer(%struct{} = answer, binding, opts)
      when struct in [PasskeyAnswer, DeviceAnswer] and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:millisecond) end)

    with {:ok, held} <- spent(answer.challenge),
         :ok <- bound(held.binding, binding),
         :ok <- current(held.request, now),
         {:ok, identifier} <- answering(answer, held),
         {:ok, head, state} <- account(identifier),
         {:ok, key} <- verified(answer, held.request, state, now) do
      done(held, answer, identifier, key, head)
    end
  end

  def answer(_answer, _binding, _opts), do: refused(:invalid_answer)

  # Taken, so spent on this answer whatever the rest says.
  defp spent(challenge) do
    case Arca.Cache.take(key(challenge)) do
      {:ok, %{request: %Prima.SignIn{}} = held} -> {:ok, held}
      _miss -> refused(:unknown_challenge)
    end
  end

  defp bound({kind, held}, {kind, delivered}) when is_binary(delivered) do
    if Plug.Crypto.secure_compare(held, delivered), do: :ok, else: refused(:wrong_binding)
  end

  defp bound(_held, _delivered), do: refused(:wrong_binding)

  # Unexpired and for this CYFR, before any log is read for it.
  defp current(%Prima.SignIn{expires_at: expires_at, audience: audience}, now) do
    cond do
      now >= expires_at -> refused(:expired)
      home() != {:ok, audience} -> refused(:wrong_audience)
      true -> :ok
    end
  end

  # The account that answers: a passkey's names it; a device answers for
  # the account its channel speaks for.
  defp answering(%PasskeyAnswer{identifier: identifier}, _held), do: {:ok, identifier}

  defp answering(%DeviceAnswer{}, %{binding: {:channel, _id}, identifier: identifier})
       when is_binary(identifier),
       do: {:ok, identifier}

  defp answering(_answer, _held), do: refused(:wrong_answer)

  # The account's log within freshness's policy: the cached head, or for an
  # account never read here, its whole log at this deployment's directory.
  defp account(identifier) do
    fresh =
      case Arca.DirectoryHeads.get(Prima.Actor.system(), identifier) do
        {:error, :not_found} ->
          Sanctum.IdentityFreshness.fresh!(identifier, directory: Sanctum.directory_url())

        {:ok, _cached} ->
          Sanctum.IdentityFreshness.fresh?(identifier)

        {:error, _unanswered} ->
          {:error, :unavailable}
      end

    case fresh do
      {:ok, head} ->
        case Sanctum.IdentityFreshness.state(head) do
          {:ok, state} -> {:ok, head, state}
          {:error, :corrupt} -> {:error, :unavailable}
        end

      {:refused, reason} ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp verified(answer, request, state, now) do
    with {:ok, home} <- home() do
      case Prima.SignIn.verify(answer, request, state, home: home, now: now) do
        {:ok, key} -> {:ok, key}
        {:error, reason} -> refused(reason)
      end
    end
  end

  defp refused(reason) do
    Logger.info("[Sanctum.SignIn] an answer was refused: " <> Prima.LoggerContext.shape(reason))
    {:error, :answer_refused}
  end

  # ---- what each purpose does --------------------------------------------------

  defp done(%{request: %{purpose: :sign_in}} = held, _answer, identifier, key, head) do
    with {:ok, user} <- signed_in(identifier, held.admission, head),
         {:ok, token} <- session(user, key, head) do
      {:ok, %{purpose: :sign_in, user: user, session_token: token}}
    end
  end

  defp done(%{request: %{purpose: :confirm}} = held, _answer, identifier, key, head) do
    with :ok <- theirs(held.user_id, identifier) do
      proof =
        %{proof: proof(key), kid: key.kid, head: head.head_hash}
        |> Map.merge(confirming_client(held.binding, key))

      case Arca.PendingConfirmations.confirm(
             Prima.Actor.in_athanor(held.athanor_id),
             held.ref,
             proof
           ) do
        {:ok, row} ->
          Sanctum.Consent.Authz.announce(:confirmed, row)
          {:ok, %{purpose: :confirm, ref: row.ref, back: held.back}}

        {:error, reason}
        when reason in [:not_pending, :expired, :not_found, :revoked, :stale_head] ->
          {:error, reason}

        {:error, reason} ->
          Logger.warning(
            "[Sanctum.SignIn] a confirmation could not be recorded: " <>
              Prima.LoggerContext.shape(reason)
          )

          {:error, :unavailable}
      end
    end
  end

  defp done(%{request: %{purpose: :registry} = request} = held, answer, identifier, _key, _head) do
    with :ok <- theirs(held.user_id, identifier) do
      case Prima.SignIn.registry_bytes(request, answer) do
        {:ok, signed} ->
          {:ok, %{purpose: :registry, user_id: held.user_id, signed: signed, back: held.back}}

        {:error, reason} ->
          refused(reason)
      end
    end
  end

  # The person a confirmation or a registry request is for, as their
  # account: a `usr_` id mapped to its identifier, never compared with one.
  defp theirs(user_id, identifier) do
    case Users.identifier(user_id) do
      {:ok, ^identifier} -> :ok
      {:ok, _another} -> refused(:wrong_person)
      {:error, :not_found} -> refused(:wrong_person)
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp proof(%Prima.Identity.Key{kind: :passkey}), do: "passkey"
  defp proof(%Prima.Identity.Key{kind: :device}), do: "device"

  # A device confirms over its own channel, which names its paired client.
  defp confirming_client({:channel, client_id}, %Prima.Identity.Key{kind: :device}),
    do: %{client_id: client_id}

  defp confirming_client(_binding, _key), do: %{}

  # The person the identifier names here, or a new one.
  defp signed_in(identifier, admission, head) do
    case Users.get_by_identifier(identifier) do
      {:ok, user} -> admitted(user, admission)
      {:error, :not_found} -> newcomer(identifier, admission, head)
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # A person this CYFR holds, with the invitation they came with redeemed
  # first. An invitation that can no longer be used grants nothing: the
  # door decides, and a person it refuses is told the invitation failed.
  defp admitted(user, {:invitation, hash}) do
    case Sanctum.Invitations.redeem_for(hash, user.id) do
      {:ok, _redeemed} ->
        admitted(user, nil)

      {:error, :invitation_invalid} ->
        case admitted(user, nil) do
          {:ok, user} -> {:ok, user}
          {:error, {:door, _reason}} -> {:error, :invitation_invalid}
          {:error, reason} -> {:error, reason}
        end

      {:error, {:door, _reason} = refused} ->
        {:error, refused}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp admitted(%{status: "active"} = user, _admission) do
    with {:ok, :allowed} <- Sanctum.Door.sign_in(user), do: unlocked(user.id)
  end

  defp admitted(_user, _admission), do: {:error, :not_standing}

  # A new person: admitted under the request's admission, or as the door
  # admits their identifier. One another answer made meanwhile is the
  # person this answer signs in.
  defp newcomer(identifier, admission, head) do
    account = %{
      identifier: identifier,
      directory_url: head.directory_url,
      head_hash: head.head_hash
    }

    case Sanctum.Newcomer.admit(admission || :open, account) do
      {:ok, %{person: user}} ->
        {:ok, user}

      {:error, :conflict} ->
        case Users.get_by_identifier(identifier) do
          {:ok, user} -> admitted(user, nil)
          {:error, _unread} -> {:error, :unavailable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Invitations by identifier activate and fills are asked for without
  # refusing the sign-in: a pending invitation activates on the next one,
  # and a fill's failure lands on its athanor's row.
  defp unlocked(user_id) do
    case Sanctum.SharedThreads.activate_invited(%{id: user_id}) do
      {:ok, _n} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Sanctum.SignIn] an invitation's activation failed for #{user_id}: " <>
            Prima.LoggerContext.shape(reason)
        )
    end

    :ok = Sanctum.Provisioning.after_sign_in(user_id)

    case Users.get(user_id) do
      {:ok, user} -> {:ok, user}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The session, bound to the key that signed and the head it was verified
  # under: a head that moved since is refused by the fence.
  defp session(user, key, head) do
    ctx =
      Context.build(
        user_id: user.id,
        email: user[:email],
        provider: proof(key),
        athanor_id: nil,
        permissions: Context.person_permissions()
      )

    with {:ok, ctx} <-
           Sanctum.Tenancy.resolve_status(%{ctx | namespace: user[:namespace]}, force: true),
         {:ok, session} <- Sanctum.Session.create(ctx, kid: key.kid, head: head.head_hash) do
      {:ok, session.token}
    else
      {:error, reason} when reason in [:stale_head, :unavailable, :not_owner] ->
        {:error, if(reason == :not_owner, do: :unavailable, else: reason)}

      {:error, reason} ->
        Logger.warning(
          "[Sanctum.SignIn] #{user.id} was admitted and no session minted: " <>
            Prima.LoggerContext.shape(reason)
        )

        {:error, :unavailable}
    end
  end

  # ---- registry answers --------------------------------------------------------

  @doc """
  Record the registry's answer to the caller's handle claim
  (`%{"handle" => slug, "identifier" => identifier}`), only while the
  caller stands: their standing is read again first
  (`Sanctum.Caller.revalidate_session/1`), so a session, key or device
  revoked while the registry answered records nothing; the answer must
  name the identifier the caller signed the claim under
  (`:malformed_answer` otherwise: it answered for someone else); then the
  slug is recorded (`record_namespace/2`). Answers the context as it was
  read again, for the writes that follow under it. A store that cannot
  answer, or a remote person whose identity could not be confirmed fresh,
  is `:unavailable` or `:identity_stale` and the session stands; any
  other standing refusal is `:unauthenticated`.
  """
  @spec record_claim(Context.t(), map()) ::
          {:ok, Context.t()}
          | {:error,
             :unauthenticated
             | :unavailable
             | :identity_stale
             | :malformed_answer
             | :not_found
             | :invalid_slug
             | :namespace_owned_by_another_identity
             | term()}
  def record_claim(%Context{user_id: user_id} = ctx, %{
        "handle" => slug,
        "identifier" => identifier
      })
      when is_binary(user_id) and is_binary(slug) and is_binary(identifier) do
    case Sanctum.Caller.revalidate_session(ctx) do
      {:ok, fresh} ->
        with :ok <- claimed_by(user_id, identifier),
             {:ok, _user} <- record_namespace(user_id, slug),
             do: {:ok, fresh}

      {:error, reason} when reason in [:unavailable, :identity_stale] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :unauthenticated}
    end
  end

  def record_claim(%Context{}, _answer), do: {:error, :malformed_answer}

  # The answer names the identifier the person's own identity row holds.
  defp claimed_by(user_id, identifier) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, %{identifier: ^identifier}} -> :ok
      {:ok, _another} -> {:error, :malformed_answer}
      {:error, :not_found} -> {:error, :malformed_answer}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  @doc """
  Record the person's cyfr.run namespace, as a registry answer names it:
  the durable copy on `users.namespace` that every request reads. Their own athanor was minted at admission; this
  only reruns the provisioning hook so a namespace-holding person's groups
  retry. Refuses a slug another identity on this server already holds; a
  row that already carries a *different* slug keeps it (logged — the
  registry, not this server, would have to say which is right).
  """
  @spec record_namespace(String.t(), String.t()) ::
          {:ok, Sanctum.Tenancy.Users.user()}
          | {:error, :not_found | :invalid_slug | :namespace_owned_by_another_identity | term()}
  def record_namespace(user_id, slug) when is_binary(user_id) and is_binary(slug) do
    with :ok <- personal_slug(slug),
         {:ok, user} <- Users.get(user_id) do
      cond do
        user.namespace == slug ->
          {:ok, user}

        is_binary(user.namespace) ->
          # The namespace is meant to be the same person everywhere. When the
          # registry names another one, this server keeps what it recorded —
          # its athanor slug, its paths and its push attribution are all built
          # on it — and says so loudly enough to be noticed, because the
          # divergence is permanent until someone reconciles it at cyfr.run.
          Logger.warning(
            "[Sanctum.SignIn] cyfr.run names #{user_id} #{inspect(slug)} but this server " <>
              "recorded #{inspect(user.namespace)} — keeping the recorded one; reconcile at " <>
              "cyfr.run if the registry is right"
          )

          :telemetry.execute(
            [:cyfr, :sanctum, :identity, :namespace_divergence],
            %{count: 1},
            %{user_id: user_id, recorded: user.namespace, registry: slug}
          )

          {:ok, user}

        true ->
          case Users.get_by_namespace(slug) do
            {:ok, %{id: other}} when other != user_id ->
              {:error, :namespace_owned_by_another_identity}

            {:error, :database_error} = err ->
              err

            _ ->
              with {:ok, user} <- Users.set_namespace(user, slug) do
                # The athanor exists since admission; the hook retries any
                # provisioning that failed. It never undoes the identity.
                _ = Sanctum.Provisioning.after_sign_in(user_id)
                Users.get(user_id) |> or_user(user)
              end
          end
      end
    end
  end

  # The row as reread after a write, or the row the write returned when
  # the reread fails.
  defp or_user({:ok, user}, _fallback), do: {:ok, user}
  defp or_user(_, fallback), do: {:ok, fallback}

  defp personal_slug(slug) do
    if Prima.ComponentRef.valid_personal_slug?(slug), do: :ok, else: {:error, :invalid_slug}
  end
end
