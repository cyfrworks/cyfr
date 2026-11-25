# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.PackArchive do
  @moduledoc """
  The archive a pack is brought in by, and the one Download hands out
  (`Compendium.Packs`): a `.zip` or a `.tar.gz`.

  `read/1` takes the archive's bytes and answers its regular files, each
  with its path and whether its executable bit is set. It bounds the
  archive's input and its expansion as it reads, so a small archive that
  inflates without end is refused before it is held: at most
  `max_input/0` bytes in, `max_expanded/0` bytes of content out, and
  `max_entries/0` entries. It takes regular files and directories alone:
  a link of any kind, a device, a path that climbs out (`..`) or starts at
  the root, a duplicate destination and a file where a directory is (or
  the other way about) each refuse the whole archive, saying which. The
  pack's own bounds and its path grammar are the pack's (`Compendium.Packs`).

  `tar_gz_stream/1` writes files as one `.tar.gz`, made as it is read, and
  `tar/1` the same entries as one plain tar, the same bytes for the same
  files: every time stamp, owner and group zero, a mode of `0644`, or
  `0755` for an executable file.
  """

  import Bitwise

  @max_input 64 * 1024 * 1024
  @max_expanded 128 * 1024 * 1024
  @max_entries 16_384

  @typedoc "A regular file of an archive: its path, joined by `/`, its bytes, and its executable bit."
  @type entry :: %{path: String.t(), bytes: binary(), executable: boolean()}

  @doc "The most bytes an archive may hold."
  @spec max_input() :: pos_integer()
  def max_input, do: @max_input

  @doc "The most bytes of content an archive may expand to."
  @spec max_expanded() :: pos_integer()
  def max_expanded, do: @max_expanded

  @doc "The most entries, files and directories, an archive may hold."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc """
  An archive's regular files, in the order the archive holds them, or the
  refusal `{:error, {:invalid_argument, sentence}}` naming why.
  """
  @spec read(binary()) :: {:ok, [entry()]} | {:error, {:invalid_argument, String.t()}}
  def read(bytes) when is_binary(bytes) and byte_size(bytes) > @max_input,
    do: refuse("The archive is larger than #{@max_input} bytes")

  def read(<<0x1F, 0x8B, _::binary>> = bytes) do
    with {:ok, tar} <- gunzip(bytes), do: read_tar(tar)
  end

  def read(<<"PK", 3, 4, _::binary>> = bytes), do: read_zip(bytes)
  def read(<<"PK", 5, 6, _::binary>> = bytes), do: read_zip(bytes)

  def read(bytes) when is_binary(bytes),
    do: refuse("That is not a .zip or a .tar.gz archive")

  # ---------------------------------------------------------------------------
  # gzip, bounded as it inflates
  # ---------------------------------------------------------------------------

  # The tar's bound is its content's with room for each entry's header and
  # padding, so no legal archive is refused for its framing.
  @tar_bound @max_expanded + @max_entries * 1_024 + 1_024

  defp gunzip(bytes) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      inflate(z, :zlib.safeInflate(z, bytes), [], 0)
    rescue
      ErlangError -> refuse("The archive's compressed data is damaged")
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, {state, out}, acc, size) do
    size = size + IO.iodata_length(out)

    cond do
      size > @tar_bound ->
        refuse("The archive expands past #{@max_expanded} bytes")

      state == :finished ->
        {:ok, IO.iodata_to_binary(Enum.reverse([out | acc]))}

      true ->
        inflate(z, :zlib.safeInflate(z, []), [out | acc], size)
    end
  end

  # ---------------------------------------------------------------------------
  # tar
  # ---------------------------------------------------------------------------

  defp read_tar(tar), do: tar_entries(tar, %{}, nil, new_seen())

  defp tar_entries(<<header::binary-size(512), rest::binary>>, pax, long, seen) do
    if header == <<0::size(4096)>> do
      finish(seen)
    else
      with {:ok, h} <- tar_header(header),
           {:ok, data, rest} <- tar_data(rest, h.size) do
        tar_entry(h, data, rest, pax, long, seen)
      end
    end
  end

  defp tar_entries(<<>>, _pax, _long, seen), do: finish(seen)
  defp tar_entries(_short, _pax, _long, _seen), do: refuse("The archive ends inside an entry")

  defp tar_entry(%{type: ?x}, data, rest, _pax, long, seen),
    do: tar_entries(rest, pax_records(data), long, seen)

  defp tar_entry(%{type: ?g}, _data, rest, pax, long, seen),
    do: tar_entries(rest, pax, long, seen)

  defp tar_entry(%{type: ?L}, data, rest, pax, _long, seen),
    do: tar_entries(rest, pax, trim_nul(data), seen)

  defp tar_entry(%{type: type} = h, data, rest, pax, long, seen) do
    name = Map.get(pax, "path") || long || h.name

    with {:ok, seen} <- entry(seen, name, kind(type), data, (h.mode &&& 0o111) != 0),
         do: tar_entries(rest, %{}, nil, seen)
  end

  defp kind(type) when type in [?0, 0, ?7], do: :file
  defp kind(?5), do: :dir
  defp kind(type) when type in [?1, ?2], do: :link
  defp kind(_other), do: :other

  defp tar_header(
         <<name::binary-size(100), mode::binary-size(8), _uid::binary-size(8),
           _gid::binary-size(8), size::binary-size(12), _mtime::binary-size(12),
           _sum::binary-size(8), type, _link::binary-size(100), magic::binary-size(6),
           _version::binary-size(2), _uname::binary-size(32), _gname::binary-size(32),
           _major::binary-size(8), _minor::binary-size(8), prefix::binary-size(155),
           _pad::binary-size(12)>>
       ) do
    with {:ok, size} <- octal(size),
         {:ok, mode} <- octal(mode) do
      name = trim_nul(name)
      prefix = if String.starts_with?(magic, "ustar"), do: trim_nul(prefix), else: ""

      {:ok,
       %{
         name: if(prefix == "", do: name, else: prefix <> "/" <> name),
         mode: mode,
         size: size,
         type: type
       }}
    end
  end

  defp tar_data(rest, size) do
    pad = div(size + 511, 512) * 512 - size

    case rest do
      <<data::binary-size(^size), _pad::binary-size(^pad), rest::binary>> ->
        {:ok, data, rest}

      _short ->
        refuse("The archive ends inside an entry")
    end
  end

  # A numeric field: octal digits, or base-256 when its first bit is set.
  defp octal(<<1::1, _::7, _::binary>> = field) do
    bits = bit_size(field) - 1
    <<_::1, value::size(^bits)>> = field
    {:ok, value}
  end

  defp octal(field) do
    case field |> trim_nul() |> String.trim() do
      "" ->
        {:ok, 0}

      digits ->
        case Integer.parse(digits, 8) do
          {value, ""} -> {:ok, value}
          _other -> refuse("The archive has an entry this reader cannot read")
        end
    end
  end

  defp pax_records(data), do: pax_records(data, %{})

  defp pax_records(<<>>, acc), do: acc

  defp pax_records(data, acc) do
    with [len, _] <- String.split(data, " ", parts: 2),
         {n, ""} <- Integer.parse(len),
         <<record::binary-size(^n), rest::binary>> <- data,
         [_len, kv] <- String.split(record, " ", parts: 2),
         [key, value] <- String.split(String.trim_trailing(kv, "\n"), "=", parts: 2) do
      pax_records(rest, Map.put(acc, key, value))
    else
      _malformed -> acc
    end
  end

  defp trim_nul(bytes), do: bytes |> :binary.split(<<0>>) |> hd()

  # ---------------------------------------------------------------------------
  # zip
  # ---------------------------------------------------------------------------

  defp read_zip(bytes) do
    with {:ok, offset, count} <- end_of_directory(bytes),
         {:ok, headers} <- central(bytes, offset, count, []) do
      Enum.reduce_while(headers, {:ok, new_seen()}, fn h, {:ok, seen} ->
        with :ok <- allowed(seen, h),
             {:ok, data} <- zip_data(bytes, h),
             {:ok, seen} <- entry(seen, h.name, h.kind, data, h.executable) do
          {:cont, {:ok, seen}}
        else
          {:error, _} = refused -> {:halt, refused}
        end
      end)
      |> case do
        {:ok, seen} -> finish(seen)
        refused -> refused
      end
    end
  end

  defp end_of_directory(bytes) do
    tail = min(byte_size(bytes), 65_557)
    window = binary_part(bytes, byte_size(bytes) - tail, tail)

    case :binary.matches(window, <<"PK", 5, 6>>) do
      [] ->
        refuse("The .zip archive has no directory of its files")

      matches ->
        {at, _} = List.last(matches)

        case binary_part(window, at, tail - at) do
          <<"PK", 5, 6, _disk::16, _cd_disk::16, _here::little-16, count::little-16,
            _size::little-32, offset::little-32, _rest::binary>> ->
            if count == 0xFFFF or offset == 0xFFFFFFFF,
              do: refuse("The .zip archive is past its bound"),
              else: {:ok, offset, count}

          _short ->
            refuse("The .zip archive's directory is damaged")
        end
    end
  end

  defp central(_bytes, _offset, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp central(_bytes, _offset, _count, acc) when length(acc) >= @max_entries,
    do: refuse("The archive holds more than #{@max_entries} entries")

  defp central(bytes, offset, count, acc) do
    case bytes do
      <<_::binary-size(^offset), "PK", 1, 2, made::little-16, _need::little-16, flags::little-16,
        method::little-16, _time::little-16, _date::little-16, crc::little-32, csize::little-32,
        usize::little-32, nlen::little-16, elen::little-16, clen::little-16, _disk::little-16,
        _iattr::little-16, eattr::little-32, local::little-32, name::binary-size(nlen),
        _::binary>> ->
        mode = if made >>> 8 == 3, do: eattr >>> 16, else: 0
        dir? = String.ends_with?(name, "/")

        kind =
          cond do
            (mode &&& 0o170000) == 0o120000 -> :link
            dir? or (mode &&& 0o170000) == 0o040000 -> :dir
            (mode &&& 0o170000) in [0, 0o100000] -> :file
            true -> :other
          end

        h = %{
          name: name,
          kind: kind,
          flags: flags,
          method: method,
          crc: crc,
          csize: csize,
          usize: usize,
          local: local,
          executable: (mode &&& 0o111) != 0
        }

        central(bytes, offset + 46 + nlen + elen + clen, count - 1, [h | acc])

      _damaged ->
        refuse("The .zip archive's directory is damaged")
    end
  end

  # What a file says it expands to is held to what is left before a byte
  # of it is inflated: the archive's allowance after the files already
  # read, and a file's own (`Arca.Files.max_write/0`). The inflation is
  # then bounded by that same declared size (`raw_inflate/6`), so a file
  # that lies about its size is refused as it grows past it.
  defp allowed(_seen, %{kind: kind}) when kind != :file, do: :ok

  defp allowed(%{bytes: bytes}, %{usize: usize, name: name}) do
    cond do
      usize > Arca.Files.max_write() ->
        refuse(
          "The archive's file #{inspect(name)} is past a file's #{Arca.Files.max_write()} bytes"
        )

      bytes + usize > @max_expanded ->
        refuse("The archive expands past #{@max_expanded} bytes")

      true ->
        :ok
    end
  end

  defp zip_data(_bytes, %{kind: kind}) when kind != :file, do: {:ok, ""}

  defp zip_data(_bytes, %{flags: flags}) when (flags &&& 1) == 1,
    do: refuse("The archive holds an encrypted file")

  defp zip_data(_bytes, %{usize: usize}) when usize > @max_expanded,
    do: refuse("The archive expands past #{@max_expanded} bytes")

  defp zip_data(bytes, %{local: local} = h) do
    with {:ok, start} <- local_start(bytes, local),
         true <- start + h.csize <= byte_size(bytes),
         {:ok, data} <- unzip(binary_part(bytes, start, h.csize), h) do
      if byte_size(data) == h.usize and :erlang.crc32(data) == h.crc,
        do: {:ok, data},
        else: refuse("The archive's file #{inspect(h.name)} is damaged")
    else
      {:error, _} = refused -> refused
      _short -> refuse("The archive's file #{inspect(h.name)} is damaged")
    end
  end

  # Where a file's bytes begin: past its local header, whose name and extra
  # field may differ in length from the central directory's.
  defp local_start(bytes, local) do
    case bytes do
      <<_::binary-size(^local), "PK", 3, 4, _::binary-size(22), nlen::little-16, elen::little-16,
        _::binary>> ->
        {:ok, local + 30 + nlen + elen}

      _short ->
        :short
    end
  end

  defp unzip(data, %{method: 0}), do: {:ok, data}

  defp unzip(data, %{method: 8, usize: usize, name: name}) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      raw_inflate(z, :zlib.safeInflate(z, data), [], 0, usize, name)
    rescue
      ErlangError -> refuse("The archive's file #{inspect(name)} is damaged")
    after
      :zlib.close(z)
    end
  end

  defp unzip(_data, %{name: name}),
    do:
      refuse("The archive's file #{inspect(name)} is compressed in a way this reader cannot read")

  # A file never inflates past what its directory declares.
  defp raw_inflate(z, {state, out}, acc, size, usize, name) do
    size = size + IO.iodata_length(out)

    cond do
      size > usize -> refuse("The archive's file #{inspect(name)} is damaged")
      state == :finished -> {:ok, IO.iodata_to_binary(Enum.reverse([out | acc]))}
      true -> raw_inflate(z, :zlib.safeInflate(z, []), [out | acc], size, usize, name)
    end
  end

  # ---------------------------------------------------------------------------
  # One rule for every entry, whichever format held it
  # ---------------------------------------------------------------------------

  defp new_seen, do: %{kinds: %{}, files: [], count: 0, bytes: 0}

  defp entry(_seen, name, :link, _data, _x),
    do: refuse("The archive holds a link (#{inspect(name)}): a pack holds no link of any kind")

  defp entry(_seen, name, :other, _data, _x),
    do: refuse("The archive holds #{inspect(name)}, which is neither a file nor a folder")

  defp entry(seen, name, kind, data, executable) do
    with {:ok, segments} <- segments(name),
         :ok <- counted(seen, data) do
      seen = %{seen | count: seen.count + 1, bytes: seen.bytes + byte_size(data)}
      place(seen, segments, kind, data, executable)
    end
  end

  defp counted(%{count: count}, _data) when count >= @max_entries,
    do: refuse("The archive holds more than #{@max_entries} entries")

  defp counted(%{bytes: bytes}, data) when bytes + byte_size(data) > @max_expanded,
    do: refuse("The archive expands past #{@max_expanded} bytes")

  defp counted(_seen, _data), do: :ok

  # The archive's own path spelled as segments: `./` and a trailing `/`
  # are framing; an absolute path, a `..`, a backslash or a NUL refuses.
  defp segments(name) do
    parts = name |> String.split("/") |> Enum.reject(&(&1 in ["", "."]))

    cond do
      String.starts_with?(name, "/") or String.contains?(name, ["\\", <<0>>]) ->
        refuse("The archive holds #{inspect(name)}, a path outside the archive")

      ".." in parts ->
        refuse("The archive holds #{inspect(name)}, a path that climbs out with '..'")

      parts == [] ->
        {:ok, []}

      true ->
        {:ok, parts}
    end
  end

  defp place(seen, [], :dir, _data, _x), do: {:ok, seen}
  defp place(_seen, [], :file, _data, _x), do: refuse("The archive holds a file with no name")

  defp place(seen, segments, kind, data, executable) do
    path = Enum.join(segments, "/")

    with :ok <- ancestors_are_folders(seen, segments) do
      case {Map.get(seen.kinds, path), kind} do
        {nil, :file} ->
          {:ok,
           %{
             seen
             | kinds: folders(seen.kinds, segments) |> Map.put(path, :file),
               files: [%{path: path, bytes: data, executable: executable} | seen.files]
           }}

        {nil, :dir} ->
          {:ok, %{seen | kinds: folders(seen.kinds, segments) |> Map.put(path, :dir)}}

        {:dir, :dir} ->
          {:ok, seen}

        {:file, :file} ->
          refuse("The archive holds #{inspect(path)} twice")

        _file_and_folder ->
          refuse("The archive holds #{inspect(path)} as both a file and a folder")
      end
    end
  end

  defp ancestors_are_folders(seen, segments) do
    segments
    |> Enum.drop(-1)
    |> Enum.scan(&(&2 <> "/" <> &1))
    |> Enum.find(&(Map.get(seen.kinds, &1) == :file))
    |> case do
      nil -> :ok
      file -> refuse("The archive holds #{inspect(file)} as both a file and a folder")
    end
  end

  defp folders(kinds, segments) do
    segments
    |> Enum.drop(-1)
    |> Enum.scan(&(&2 <> "/" <> &1))
    |> Enum.reduce(kinds, &Map.put_new(&2, &1, :dir))
  end

  defp finish(seen), do: {:ok, Enum.reverse(seen.files)}

  defp refuse(sentence), do: {:error, {:invalid_argument, sentence}}

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  # A tar ends with two zero blocks.
  @tar_end <<0::size(8192)>>

  @doc """
  The files as one `.tar.gz`, in the order given, each `{path, bytes,
  executable?}`, produced as it is read: a lazy stream of gzip chunks,
  one file's tar entry compressed at a time, so the archive is never held
  whole. A path too long for a ustar header carries a PAX one.
  """
  @spec tar_gz_stream([{String.t(), binary(), boolean()}]) :: Enumerable.t()
  def tar_gz_stream(files) when is_list(files) do
    Stream.resource(
      fn ->
        z = :zlib.open()
        # 31: deflate with a gzip header and trailer.
        :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)
        {z, files}
      end,
      fn
        {z, [file | rest]} ->
          {[IO.iodata_to_binary(:zlib.deflate(z, tar_file(file)))], {z, rest}}

        {z, []} ->
          {[IO.iodata_to_binary(:zlib.deflate(z, @tar_end, :finish))], {z, :done}}

        {z, :done} ->
          {:halt, {z, :done}}
      end,
      fn {z, _left} -> :zlib.close(z) end
    )
  end

  @doc "The same archive as `tar_gz_stream/1`, held whole."
  @spec tar_gz([{String.t(), binary(), boolean()}]) :: binary()
  def tar_gz(files) when is_list(files), do: files |> tar_gz_stream() |> Enum.join()

  @doc "The tar `tar_gz_stream/1` compresses, uncompressed and held whole."
  @spec tar([{String.t(), binary(), boolean()}]) :: binary()
  def tar(files) when is_list(files),
    do: IO.iodata_to_binary([Enum.map(files, &tar_file/1), @tar_end])

  defp tar_file({path, bytes, executable}) do
    mode = if executable, do: 0o755, else: 0o644

    case ustar_name(path) do
      {:ok, prefix, name} ->
        [header(name, prefix, mode, byte_size(bytes), ?0), padded(bytes)]

      :too_long ->
        record = pax_record("path", path)

        [
          header("PaxHeader", "", 0o644, byte_size(record), ?x),
          padded(record),
          header(String.slice(Path.basename(path), 0, 100), "", mode, byte_size(bytes), ?0),
          padded(bytes)
        ]
    end
  end

  defp ustar_name(path) when byte_size(path) <= 100, do: {:ok, "", path}

  defp ustar_name(path) do
    parts = String.split(path, "/")

    Enum.find_value(1..(length(parts) - 1)//1, :too_long, fn n ->
      {head, tail} = Enum.split(parts, n)
      prefix = Enum.join(head, "/")
      name = Enum.join(tail, "/")
      if byte_size(prefix) <= 155 and byte_size(name) <= 100, do: {:ok, prefix, name}
    end)
  end

  defp pax_record(key, value) do
    body = " #{key}=#{value}\n"
    len = byte_size(body)
    digits = len |> Integer.to_string() |> byte_size()
    total = len + digits
    total = if byte_size(Integer.to_string(total)) > digits, do: total + 1, else: total
    "#{total}#{body}"
  end

  defp header(name, prefix, mode, size, type) do
    fields = [
      field(name, 100),
      octal_field(mode, 8),
      octal_field(0, 8),
      octal_field(0, 8),
      octal_field(size, 12),
      octal_field(0, 12),
      "        ",
      <<type>>,
      field("", 100),
      "ustar\0",
      "00",
      field("", 32),
      field("", 32),
      octal_field(0, 8),
      octal_field(0, 8),
      field(prefix, 155),
      field("", 12)
    ]

    block = IO.iodata_to_binary(fields)
    sum = for <<byte <- block>>, reduce: 0, do: (acc -> acc + byte)
    checksum = String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> <<0, ?\s>>
    <<before::binary-size(148), _::binary-size(8), after_sum::binary>> = block
    before <> checksum <> after_sum
  end

  defp field(value, width), do: value <> :binary.copy(<<0>>, width - byte_size(value))

  defp octal_field(value, width),
    do: String.pad_leading(Integer.to_string(value, 8), width - 1, "0") <> <<0>>

  defp padded(bytes) do
    pad = rem(512 - rem(byte_size(bytes), 512), 512)
    [bytes, :binary.copy(<<0>>, pad)]
  end
end
