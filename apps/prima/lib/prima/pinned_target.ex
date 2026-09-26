# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.PinnedTarget do
  @moduledoc """
  The address CYFR validated for one outbound request of a guest, as
  `c:Prima.HostAPI.egress_pin/3` answers it, and the request that asks
  for it. The engine resolves no name itself: it asks CYFR, under the
  calling attempt's authority, for the address a URL may be reached at,
  and connects to exactly that address (`Prima.Network.pin/3`).

  ## The request

  `egress_pin`'s `args` are `url`, `purpose` and, for a redirect only,
  `from` (`request_args/3`, `read_request/1`):

    * `url` — an `http` or `https` URL with a host (`Prima.Network.parse_url/1`);
    * `purpose` — `fetch` for a request answered whole, `stream` for one
      whose answer is streamed, `redirect` for the next hop of a redirect;
    * `from` — the `id` of the pin the redirecting answer came from, and
      only for a `redirect`.

  ## The answer

  A pin (`t:t/0`, `to_wire/1`, `read/1`) is exactly these members:

    * `id` — CYFR's name for this pin, 1 to 128 characters of unpadded
      base64url text, which a redirect's `from` names;
    * `ip` — the validated address, as text an IP literal parses from
      (`:inet.parse_strict_address/1`);
    * `family` — `4` or `6`, the family of `ip`;
    * `scheme` and `port` — the URL's own scheme and port (the scheme's
      default when the URL names none), 1 to 65535;
    * `host` — the URL's host, kept for SNI, the certificate and the Host
      header: a hostname, or an IPv6 literal in brackets;
    * `expires_at` — Unix milliseconds after which the engine pins again
      rather than reuse the address.

  ## Refusals

  A pin CYFR does not grant is answered as a `Prima.WorkerWire` error
  named by `refusals/0`: `denied` (the attempt's policy refuses the
  address), `metadata` (a metadata address, refused before any policy),
  `resolution` (the name resolves to no address), `redirect_credentials`
  (a redirect hop that would carry the request's credentials to another
  origin than the pin it came from) and `malformed` (the args do not
  read).
  """

  @enforce_keys [:id, :ip, :family, :scheme, :port, :host, :expires_at]
  defstruct @enforce_keys

  @typedoc "Why the next request is made: whole, streamed, or a redirect's next hop."
  @type purpose :: :fetch | :stream | :redirect

  @typedoc "A pin `egress_pin` refuses, as its error answer names it."
  @type refusal :: :denied | :metadata | :resolution | :redirect_credentials | :malformed

  @typedoc "An `egress_pin` request's args, read."
  @type request :: %{url: String.t(), purpose: purpose(), from: String.t() | nil}

  @type t :: %__MODULE__{
          id: String.t(),
          ip: String.t(),
          family: 4 | 6,
          scheme: String.t(),
          port: 1..65_535,
          host: String.t(),
          expires_at: non_neg_integer()
        }

  @purposes [:fetch, :stream, :redirect]
  @refusals [:denied, :metadata, :resolution, :redirect_credentials, :malformed]
  @members ~w(id ip family scheme port host expires_at)

  @id ~r/\A[A-Za-z0-9_-]{1,128}\z/
  @label "[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?"
  @hostname Regex.compile!("\\A(?=.{1,253}\\z)#{@label}(?:\\.#{@label})*\\.?\\z")
  # 2^53 − 1: the largest integer every JSON reader holds exactly.
  @max_integer 9_007_199_254_740_991

  @doc "The purposes a pin is asked for."
  @spec purposes() :: [purpose()]
  def purposes, do: @purposes

  @doc "The refusals an `egress_pin` answer names."
  @spec refusals() :: [refusal()]
  def refusals, do: @refusals

  @doc "Whether `id` is a pin id: 1 to 128 characters of unpadded base64url text."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id), do: Regex.match?(@id, id)
  def valid_id?(_id), do: false

  @doc """
  The args of an `egress_pin` request for `url` with `purpose`, naming the
  pin `from` for a redirect and for nothing else, or `:error` for a
  request `read_request/1` would refuse.
  """
  @spec request_args(String.t(), purpose(), String.t() | nil) ::
          {:ok, %{String.t() => String.t()}} | :error
  def request_args(url, purpose, from \\ nil) do
    args = %{"url" => url, "purpose" => to_string(purpose)}
    args = if from == nil, do: args, else: Map.put(args, "from", from)

    case read_request(args) do
      {:ok, _request} -> {:ok, args}
      {:error, :malformed} -> :error
    end
  end

  @doc """
  The request an `egress_pin` call's `args` spell: exactly `url` and
  `purpose`, and `from` for a `redirect`, each as the module doc says.
  Anything else is `{:error, :malformed}`.
  """
  @spec read_request(term()) :: {:ok, request()} | {:error, :malformed}
  def read_request(%{"url" => url, "purpose" => purpose} = args)
      when is_binary(url) and is_binary(purpose) and not is_struct(args) do
    with {:ok, purpose} <- read_purpose(purpose),
         {:ok, from} <- read_from(purpose, args),
         {:ok, _uri} <- Prima.Network.parse_url(url) do
      {:ok, %{url: url, purpose: purpose, from: from}}
    else
      _ -> {:error, :malformed}
    end
  end

  def read_request(_args), do: {:error, :malformed}

  defp read_purpose(purpose) do
    case Enum.find(@purposes, &(Atom.to_string(&1) == purpose)) do
      nil -> :error
      purpose -> {:ok, purpose}
    end
  end

  defp read_from(:redirect, %{"from" => from} = args) when map_size(args) == 3,
    do: if(valid_id?(from), do: {:ok, from}, else: :error)

  defp read_from(purpose, args) when purpose != :redirect and map_size(args) == 2,
    do: {:ok, nil}

  defp read_from(_purpose, _args), do: :error

  @doc """
  Whether `pin` is a `t:t/0` whose every field is as the module doc says:
  an id, an IP literal that parses and a family that matches it, an
  `http` or `https` scheme, a port of 1 to 65535, a hostname or bracketed
  IPv6 literal, and an expiry of 0 to 2^53 − 1.
  """
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = pin) do
    valid_id?(pin.id) and family_of(pin.ip) == {:ok, pin.family} and
      pin.scheme in ["http", "https"] and is_integer(pin.port) and pin.port in 1..65_535 and
      valid_host?(pin.host) and is_integer(pin.expires_at) and
      pin.expires_at in 0..@max_integer
  end

  def valid?(_pin), do: false

  @doc """
  `pin` as its JSON answer spells it, which `read/1` reads back; raises
  `ArgumentError` for a pin `valid?/1` refuses, since it is the caller's
  own.
  """
  @spec to_wire(t()) :: %{String.t() => term()}
  def to_wire(pin) do
    unless valid?(pin),
      do: raise(ArgumentError, "not a pinned target: #{Prima.LoggerContext.shape(pin)}")

    Map.new(@members, &{&1, Map.fetch!(pin, String.to_existing_atom(&1))})
  end

  @doc """
  The pin a JSON answer spells, as `to_wire/1` writes it, or `:error`: a
  member missing or extra, or a value `valid?/1` refuses.
  """
  @spec read(term()) :: {:ok, t()} | :error
  def read(%{} = wire) when not is_struct(wire) do
    if Enum.sort(Map.keys(wire)) == Enum.sort(@members) do
      pin = struct!(__MODULE__, Enum.map(@members, &{String.to_existing_atom(&1), wire[&1]}))
      if valid?(pin), do: {:ok, pin}, else: :error
    else
      :error
    end
  end

  def read(_wire), do: :error

  @doc "The address `pin` names, as `Prima.Network.pin/3` takes it."
  @spec address(t()) :: :inet.ip_address()
  def address(%__MODULE__{ip: ip}) do
    {:ok, address} = :inet.parse_strict_address(String.to_charlist(ip))
    address
  end

  @doc "Whether `pin` may no longer be used at `now` (Unix ms): past its `expires_at`."
  @spec expired?(t(), integer()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}, now) when is_integer(now),
    do: now > expires_at

  defp family_of(ip) when is_binary(ip) do
    case :inet.parse_strict_address(String.to_charlist(ip)) do
      {:ok, {_, _, _, _}} -> {:ok, 4}
      {:ok, {_, _, _, _, _, _, _, _}} -> {:ok, 6}
      {:error, _} -> :error
    end
  end

  defp family_of(_ip), do: :error

  defp valid_host?("[" <> rest) when byte_size(rest) > 1 do
    case :binary.split(rest, "]") do
      [literal, ""] -> match?({:ok, _}, :inet.parse_ipv6strict_address(to_charlist(literal)))
      _ -> false
    end
  end

  defp valid_host?(host) when is_binary(host), do: Regex.match?(@hostname, host)
  defp valid_host?(_host), do: false
end
