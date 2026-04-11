defmodule Arca.Sqlite.Schema do
  @moduledoc """
  Parse manifest schema declarations, validate data rows, and validate query SQL.

  Component manifests can declare tables and named queries in a `schema` block.
  Query SQL is validated at publish/registration time using a tokenized
  single-statement subset check — no external SQL parser needed.
  """

  @type_map %{
    "TEXT" => :text,
    "INTEGER" => :integer,
    "REAL" => :real,
    "BLOB" => :blob
  }

  @sqlite_type_names %{text: "TEXT", integer: "INTEGER", real: "REAL", blob: "BLOB"}

  @denied_keywords ~w(
    ATTACH DETACH PRAGMA INSERT UPDATE DELETE DROP CREATE ALTER
    LOAD_EXTENSION SAVEPOINT RELEASE REINDEX VACUUM ANALYZE
  )

  # Safe SQL identifier: letters, digits, underscores only. Max 64 chars.
  @identifier_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]{0,63}$/

  @doc """
  Validate that a string is a safe SQL identifier (table or column name).

  Allows `[a-zA-Z_][a-zA-Z0-9_]{0,63}` only — no special chars, no quotes,
  no whitespace. This prevents SQL injection when identifiers must be
  interpolated (SQLite PRAGMA, ALTER TABLE, etc. don't accept parameters).
  """
  @spec validate_identifier(String.t()) :: :ok | {:error, String.t()}
  def validate_identifier(name) when is_binary(name) do
    if Regex.match?(@identifier_pattern, name) do
      :ok
    else
      {:error, "invalid identifier '#{String.slice(name, 0, 40)}': must match [a-zA-Z_][a-zA-Z0-9_]{0,63}"}
    end
  end

  def validate_identifier(_), do: {:error, "identifier must be a string"}

  @doc """
  Quote an identifier for use in SQL. Always double-quotes for safety.
  Caller MUST validate with `validate_identifier/1` first.
  """
  @spec quote_identifier(String.t()) :: String.t()
  def quote_identifier(name), do: ~s("#{name}")

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Extract and validate schema.tables and schema.queries from a manifest map.
  """
  @spec parse_manifest_schema(map()) ::
          {:ok, %{tables: map(), queries: map()}} | {:error, String.t()}
  def parse_manifest_schema(manifest) when is_map(manifest) do
    schema = manifest["schema"] || %{}
    raw_tables = schema["tables"] || %{}
    raw_queries = schema["queries"] || %{}

    with {:ok, tables} <- parse_tables(raw_tables),
         {:ok, queries} <- parse_queries(raw_queries, tables) do
      {:ok, %{tables: tables, queries: queries}}
    end
  end

  def parse_manifest_schema(_), do: {:error, "manifest must be a map"}

  @doc """
  Validate and coerce a row against a table schema.
  """
  @spec validate_row(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def validate_row(table_schema, row) when is_map(table_schema) and is_map(row) do
    columns = table_schema.columns
    column_map = Map.new(columns, fn col -> {col.name, col} end)
    pk_set = MapSet.new(table_schema.primary_key)

    with :ok <- check_unknown_columns(row, column_map),
         :ok <- check_not_null(row, columns, pk_set),
         {:ok, coerced} <- coerce_row(row, column_map) do
      {:ok, coerced}
    end
  end

  @doc """
  Generate CREATE TABLE IF NOT EXISTS DDL from a table schema.
  """
  @spec generate_ddl(String.t(), map()) :: String.t()
  def generate_ddl(table_name, table_schema) do
    col_defs =
      Enum.map(table_schema.columns, fn col ->
        type_str = Map.fetch!(@sqlite_type_names, col.type)
        pk_set = MapSet.new(table_schema.primary_key)

        not_null =
          if col.not_null or MapSet.member?(pk_set, col.name), do: " NOT NULL", else: ""

        "#{quote_identifier(col.name)} #{type_str}#{not_null}"
      end)

    pk_clause =
      case table_schema.primary_key do
        [] -> []
        keys -> ["PRIMARY KEY (#{Enum.map_join(keys, ", ", &quote_identifier/1)})"]
      end

    all_parts = col_defs ++ pk_clause
    "CREATE TABLE IF NOT EXISTS #{quote_identifier(table_name)} (#{Enum.join(all_parts, ", ")})"
  end

  @doc """
  Convert named params to ordered positional params for binding.
  Returns {positional_sql, [bound_values]}.
  """
  @spec prepare_query(map(), map()) ::
          {:ok, String.t(), [term()]} | {:error, String.t()}
  def prepare_query(query_def, params) when is_map(query_def) and is_map(params) do
    param_defs = query_def.params
    param_order = query_def.param_order

    with {:ok, resolved} <- resolve_params(param_order, param_defs, params) do
      {:ok, query_def.positional_sql, resolved}
    end
  end

  @doc """
  Validate query SQL for safety. Returns validated/transformed query info.
  """
  @spec validate_query_sql(String.t()) ::
          {:ok, %{positional_sql: String.t(), param_order: [String.t()]}}
          | {:error, String.t()}
  def validate_query_sql(sql) when is_binary(sql) do
    with {:ok, cleaned} <- strip_comments(sql),
         :ok <- reject_non_ascii_outside_quotes(cleaned),
         {:ok, tokens} <- tokenize(cleaned),
         :ok <- check_single_statement(tokens),
         :ok <- check_first_keyword(tokens),
         :ok <- check_no_recursive_cte(tokens),
         :ok <- check_denylist(tokens) do
      {positional_sql, param_order} = extract_params(cleaned)
      {:ok, %{positional_sql: positional_sql, param_order: param_order}}
    end
  end

  def validate_query_sql(_), do: {:error, "SQL must be a string"}

  # ---------------------------------------------------------------------------
  # Manifest Parsing — Tables
  # ---------------------------------------------------------------------------

  defp parse_tables(raw) when is_map(raw) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {name, def_map}, {:ok, acc} ->
      case parse_table(name, def_map) do
        {:ok, table} -> {:cont, {:ok, Map.put(acc, name, table)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_tables(_), do: {:error, "schema.tables must be a map"}

  defp parse_table(name, def_map) when is_binary(name) and is_map(def_map) do
    raw_cols = def_map["columns"] || []
    raw_pk = def_map["primary_key"] || []

    with :ok <- validate_identifier(name),
         {:ok, columns} <- parse_columns(raw_cols),
         :ok <- validate_primary_key(raw_pk, columns) do
      {:ok, %{columns: columns, primary_key: raw_pk}}
    end
  end

  defp parse_table(name, _), do: {:error, "invalid table definition for '#{name}'"}

  defp parse_columns(raw_cols) when is_list(raw_cols) do
    Enum.reduce_while(raw_cols, {:ok, []}, fn col, {:ok, acc} ->
      case parse_column(col) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_columns(_), do: {:error, "columns must be a list"}

  defp parse_column(%{"name" => name, "type" => type_str} = col)
       when is_binary(name) and is_binary(type_str) do
    with :ok <- validate_identifier(name) do
      case Map.get(@type_map, String.upcase(type_str)) do
        nil ->
          {:error,
           "unknown column type '#{type_str}' for '#{name}'. Must be: TEXT, INTEGER, REAL, BLOB"}

        type ->
          {:ok,
           %{
             name: name,
             type: type,
             not_null: col["not_null"] == true
           }}
      end
    end
  end

  defp parse_column(_), do: {:error, "each column must have 'name' (string) and 'type' (string)"}

  defp validate_primary_key(pk, columns) when is_list(pk) do
    col_names = MapSet.new(columns, & &1.name)

    case Enum.find(pk, fn k -> not MapSet.member?(col_names, k) end) do
      nil -> :ok
      missing -> {:error, "primary key column '#{missing}' not found in columns"}
    end
  end

  defp validate_primary_key(_, _), do: {:error, "primary_key must be a list of column names"}

  # ---------------------------------------------------------------------------
  # Manifest Parsing — Queries
  # ---------------------------------------------------------------------------

  defp parse_queries(raw, tables) when is_map(raw) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {name, def_map}, {:ok, acc} ->
      case parse_query(name, def_map, tables) do
        {:ok, query} -> {:cont, {:ok, Map.put(acc, name, query)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_queries(_, _), do: {:error, "schema.queries must be a map"}

  defp parse_query(name, %{"sql" => sql} = def_map, _tables) when is_binary(sql) do
    raw_params = def_map["params"] || %{}
    cache_ttl = def_map["cache_ttl"]

    with {:ok, validated} <- validate_query_sql(sql),
         {:ok, params} <- parse_query_params(raw_params) do
      # Verify declared params match SQL params
      sql_params = MapSet.new(validated.param_order)
      declared_params = MapSet.new(Map.keys(params))

      undeclared = MapSet.difference(sql_params, declared_params)

      if MapSet.size(undeclared) > 0 do
        {:error,
         "query '#{name}': SQL references undeclared params: #{Enum.join(undeclared, ", ")}"}
      else
        {:ok,
         %{
           sql: sql,
           positional_sql: validated.positional_sql,
           param_order: validated.param_order,
           params: params,
           cache_ttl: cache_ttl
         }}
      end
    end
  end

  defp parse_query(name, _, _), do: {:error, "query '#{name}' must have a 'sql' string"}

  defp parse_query_params(raw) when is_map(raw) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {name, def_map}, {:ok, acc} ->
      case parse_param_def(name, def_map) do
        {:ok, param} -> {:cont, {:ok, Map.put(acc, name, param)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_query_params(_), do: {:error, "query params must be a map"}

  defp parse_param_def(name, %{"type" => type_str} = def_map) when is_binary(type_str) do
    type =
      case String.downcase(type_str) do
        "text" -> :text
        "integer" -> :integer
        "real" -> :real
        _ -> nil
      end

    if type do
      {:ok,
       %{
         type: type,
         required: def_map["required"] != false,
         default: def_map["default"]
       }}
    else
      {:error, "unknown param type '#{type_str}' for '#{name}'. Must be: text, integer, real"}
    end
  end

  defp parse_param_def(name, _),
    do: {:error, "param '#{name}' must have a 'type' field (text, integer, real)"}

  # ---------------------------------------------------------------------------
  # Row Validation
  # ---------------------------------------------------------------------------

  defp check_unknown_columns(row, column_map) do
    case Enum.find(Map.keys(row), fn k -> not Map.has_key?(column_map, k) end) do
      nil -> :ok
      unknown -> {:error, "unknown column '#{unknown}'"}
    end
  end

  defp check_not_null(row, columns, pk_set) do
    missing =
      Enum.find(columns, fn col ->
        required = col.not_null or MapSet.member?(pk_set, col.name)
        required and (not Map.has_key?(row, col.name) or is_nil(row[col.name]))
      end)

    case missing do
      nil -> :ok
      col -> {:error, "column '#{col.name}' cannot be null"}
    end
  end

  defp coerce_row(row, column_map) do
    Enum.reduce_while(row, {:ok, %{}}, fn {key, val}, {:ok, acc} ->
      col = Map.fetch!(column_map, key)

      case coerce_value(val, col.type) do
        {:ok, coerced} -> {:cont, {:ok, Map.put(acc, key, coerced)}}
        {:error, reason} -> {:halt, {:error, "column '#{key}': #{reason}"}}
      end
    end)
  end

  defp coerce_value(nil, _type), do: {:ok, nil}
  defp coerce_value(v, :text) when is_binary(v), do: {:ok, v}
  defp coerce_value(v, :text), do: {:ok, to_string(v)}
  defp coerce_value(v, :integer) when is_integer(v), do: {:ok, v}

  defp coerce_value(v, :integer) when is_binary(v) do
    case Integer.parse(v) do
      {i, ""} -> {:ok, i}
      _ -> {:error, "cannot coerce '#{v}' to INTEGER"}
    end
  end

  defp coerce_value(v, :real) when is_float(v), do: {:ok, v}
  defp coerce_value(v, :real) when is_integer(v), do: {:ok, v * 1.0}

  defp coerce_value(v, :real) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> {:ok, f}
      _ -> {:error, "cannot coerce '#{v}' to REAL"}
    end
  end

  defp coerce_value(v, :blob) when is_binary(v) do
    case Base.decode64(v) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "BLOB value must be valid base64"}
    end
  end

  defp coerce_value(_, type), do: {:error, "cannot coerce value to #{type}"}

  # ---------------------------------------------------------------------------
  # Query Param Resolution
  # ---------------------------------------------------------------------------

  defp resolve_params(param_order, param_defs, supplied) do
    Enum.reduce_while(param_order, {:ok, []}, fn name, {:ok, acc} ->
      pdef = Map.get(param_defs, name)

      val =
        case Map.get(supplied, name) do
          nil -> pdef && pdef.default
          v -> v
        end

      cond do
        is_nil(pdef) ->
          # Param in SQL but not in declared params — use raw value
          {:cont, {:ok, acc ++ [Map.get(supplied, name)]}}

        pdef.required and is_nil(val) ->
          {:halt, {:error, "required param '#{name}' is missing"}}

        is_nil(val) ->
          {:cont, {:ok, acc ++ [nil]}}

        true ->
          case coerce_param(val, pdef.type) do
            {:ok, coerced} -> {:cont, {:ok, acc ++ [coerced]}}
            {:error, reason} -> {:halt, {:error, "param '#{name}': #{reason}"}}
          end
      end
    end)
  end

  defp coerce_param(v, :text) when is_binary(v), do: {:ok, v}
  defp coerce_param(v, :text), do: {:ok, to_string(v)}
  defp coerce_param(v, :integer) when is_integer(v), do: {:ok, v}

  defp coerce_param(v, :integer) when is_binary(v) do
    case Integer.parse(v) do
      {i, ""} -> {:ok, i}
      _ -> {:error, "cannot coerce '#{v}' to integer"}
    end
  end

  defp coerce_param(v, :real) when is_float(v), do: {:ok, v}
  defp coerce_param(v, :real) when is_integer(v), do: {:ok, v * 1.0}

  defp coerce_param(v, :real) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> {:ok, f}
      _ -> {:error, "cannot coerce '#{v}' to real"}
    end
  end

  # ---------------------------------------------------------------------------
  # SQL Tokenizer & Validator
  # ---------------------------------------------------------------------------

  # Step 0: Strip SQL comments (block /* */ and line --)
  # Must happen BEFORE tokenization to prevent comment-hidden keywords.
  defp strip_comments(sql) do
    case do_strip_comments(sql, :normal, []) do
      {:ok, cleaned} -> {:ok, IO.iodata_to_binary(cleaned)}
      {:error, _} = err -> err
    end
  end

  defp do_strip_comments(<<>>, :normal, acc), do: {:ok, Enum.reverse(acc)}
  defp do_strip_comments(<<>>, :line_comment, acc), do: {:ok, Enum.reverse(acc)}
  defp do_strip_comments(<<>>, :block_comment, _acc), do: {:error, "unclosed block comment"}

  defp do_strip_comments(<<>>, {:quoted, _q}, _acc),
    do: {:error, "unclosed string literal"}

  # Enter line comment
  defp do_strip_comments(<<"--", rest::binary>>, :normal, acc),
    do: do_strip_comments(rest, :line_comment, [" " | acc])

  # Enter block comment
  defp do_strip_comments(<<"/*", rest::binary>>, :normal, acc),
    do: do_strip_comments(rest, :block_comment, [" " | acc])

  # Exit line comment
  defp do_strip_comments(<<"\n", rest::binary>>, :line_comment, acc),
    do: do_strip_comments(rest, :normal, ["\n" | acc])

  defp do_strip_comments(<<_c, rest::binary>>, :line_comment, acc),
    do: do_strip_comments(rest, :line_comment, acc)

  # Exit block comment
  defp do_strip_comments(<<"*/", rest::binary>>, :block_comment, acc),
    do: do_strip_comments(rest, :normal, acc)

  defp do_strip_comments(<<_c, rest::binary>>, :block_comment, acc),
    do: do_strip_comments(rest, :block_comment, acc)

  # Quoted strings — enter
  defp do_strip_comments(<<q, rest::binary>>, :normal, acc) when q in [?', ?", ?`],
    do: do_strip_comments(rest, {:quoted, q}, [<<q>> | acc])

  # Quoted strings — escaped quote (doubled)
  defp do_strip_comments(<<q, q, rest::binary>>, {:quoted, q}, acc),
    do: do_strip_comments(rest, {:quoted, q}, [<<q, q>> | acc])

  # Quoted strings — exit
  defp do_strip_comments(<<q, rest::binary>>, {:quoted, q}, acc),
    do: do_strip_comments(rest, :normal, [<<q>> | acc])

  # Quoted strings — pass through
  defp do_strip_comments(<<c, rest::binary>>, {:quoted, q}, acc),
    do: do_strip_comments(rest, {:quoted, q}, [<<c>> | acc])

  # Normal chars
  defp do_strip_comments(<<c, rest::binary>>, :normal, acc),
    do: do_strip_comments(rest, :normal, [<<c>> | acc])

  # Step 0b: Reject non-ASCII characters outside quoted strings
  defp reject_non_ascii_outside_quotes(sql) do
    do_reject_non_ascii(sql, :normal)
  end

  defp do_reject_non_ascii(<<>>, _state), do: :ok

  # Enter quoted string
  defp do_reject_non_ascii(<<q, rest::binary>>, :normal) when q in [?', ?", ?`],
    do: do_reject_non_ascii(rest, {:quoted, q})

  # Bracket-quoted identifiers
  defp do_reject_non_ascii(<<?[, rest::binary>>, :normal),
    do: do_reject_non_ascii(rest, :bracket)

  defp do_reject_non_ascii(<<?], rest::binary>>, :bracket),
    do: do_reject_non_ascii(rest, :normal)

  defp do_reject_non_ascii(<<_c, rest::binary>>, :bracket),
    do: do_reject_non_ascii(rest, :bracket)

  # Hex string X'...'
  defp do_reject_non_ascii(<<x, ?', rest::binary>>, :normal) when x in [?X, ?x],
    do: do_reject_non_ascii(rest, {:quoted, ?'})

  # Exit quoted string (escaped double)
  defp do_reject_non_ascii(<<q, q, rest::binary>>, {:quoted, q}),
    do: do_reject_non_ascii(rest, {:quoted, q})

  defp do_reject_non_ascii(<<q, rest::binary>>, {:quoted, q}),
    do: do_reject_non_ascii(rest, :normal)

  # Inside quotes — allow anything
  defp do_reject_non_ascii(<<_c, rest::binary>>, {:quoted, _q} = state),
    do: do_reject_non_ascii(rest, state)

  # Outside quotes — reject non-ASCII
  defp do_reject_non_ascii(<<c::utf8, _rest::binary>>, :normal) when c > 127,
    do: {:error, "non-ASCII character (U+#{Integer.to_string(c, 16)}) outside string literal"}

  defp do_reject_non_ascii(<<_c, rest::binary>>, :normal),
    do: do_reject_non_ascii(rest, :normal)

  # Step 1: Tokenize SQL into keyword/identifier tokens
  # We only need word-boundary tokens for validation, not full AST.
  defp tokenize(sql) do
    {:ok, do_tokenize(sql, :normal, [], [])}
  end

  defp do_tokenize(<<>>, :normal, current, tokens),
    do: Enum.reverse(flush_token(current, tokens))

  defp do_tokenize(<<>>, {:quoted, _q}, current, tokens),
    do: Enum.reverse(flush_token(current, tokens))

  # Enter quoted string — flush current token, skip contents
  defp do_tokenize(<<q, rest::binary>>, :normal, current, tokens) when q in [?', ?", ?`] do
    tokens = flush_token(current, tokens)
    skip_quoted(rest, q, tokens)
  end

  # Bracket-quoted identifier
  defp do_tokenize(<<?[, rest::binary>>, :normal, current, tokens) do
    tokens = flush_token(current, tokens)
    skip_bracket(rest, tokens)
  end

  # Hex string X'...'
  defp do_tokenize(<<x, ?', rest::binary>>, :normal, current, tokens) when x in [?X, ?x] do
    tokens = flush_token(current, tokens)
    skip_quoted(rest, ?', tokens)
  end

  # Semicolons — emit as special token
  defp do_tokenize(<<?;, rest::binary>>, :normal, current, tokens) do
    tokens = flush_token(current, tokens)
    do_tokenize(rest, :normal, [], [{:semicolon} | tokens])
  end

  # Whitespace — token boundary
  defp do_tokenize(<<c, rest::binary>>, :normal, current, tokens) when c in [?\s, ?\t, ?\n, ?\r] do
    tokens = flush_token(current, tokens)
    do_tokenize(rest, :normal, [], tokens)
  end

  # Punctuation (not : which is param prefix) — token boundary
  defp do_tokenize(<<c, rest::binary>>, :normal, current, tokens)
       when c in [?(, ?), ?,, ?., ?=, ?<, ?>, ?!, ?+, ?-, ?*, ?/, ?%, ?|, ?&, ?~, ?^] do
    tokens = flush_token(current, tokens)
    do_tokenize(rest, :normal, [], [{:punct, <<c>>} | tokens])
  end

  # Named param :name — accumulate with colon
  defp do_tokenize(<<?:, rest::binary>>, :normal, [], tokens) do
    do_tokenize(rest, :normal, [?:], tokens)
  end

  # Normal character — accumulate
  defp do_tokenize(<<c, rest::binary>>, :normal, current, tokens) do
    do_tokenize(rest, :normal, [c | current], tokens)
  end

  # Multi-byte UTF-8 — skip (already validated by non-ASCII check)
  defp do_tokenize(<<_c::utf8, rest::binary>>, :normal, current, tokens) do
    do_tokenize(rest, :normal, current, tokens)
  end

  defp skip_quoted(<<q, q, rest::binary>>, q, tokens),
    do: skip_quoted(rest, q, tokens)

  defp skip_quoted(<<q, rest::binary>>, q, tokens),
    do: do_tokenize(rest, :normal, [], [{:string} | tokens])

  defp skip_quoted(<<_c, rest::binary>>, q, tokens),
    do: skip_quoted(rest, q, tokens)

  defp skip_quoted(<<>>, _q, tokens),
    do: Enum.reverse(tokens)

  defp skip_bracket(<<?], rest::binary>>, tokens),
    do: do_tokenize(rest, :normal, [], [{:identifier} | tokens])

  defp skip_bracket(<<_c, rest::binary>>, tokens),
    do: skip_bracket(rest, tokens)

  defp skip_bracket(<<>>, tokens),
    do: Enum.reverse(tokens)

  defp flush_token([], tokens), do: tokens

  defp flush_token(chars, tokens) do
    word = chars |> Enum.reverse() |> IO.iodata_to_binary()

    cond do
      String.starts_with?(word, ":") ->
        [{:param, String.trim_leading(word, ":")} | tokens]

      true ->
        [{:word, word} | tokens]
    end
  end

  # Step 2: Check single statement (no ; outside strings)
  defp check_single_statement(tokens) do
    case Enum.count(tokens, fn t -> t == {:semicolon} end) do
      0 -> :ok
      1 -> if List.last(tokens) == {:semicolon}, do: :ok, else: {:error, "multi-statement SQL: semicolons must only appear at the end"}
      _ -> {:error, "multi-statement SQL is not allowed"}
    end
  end

  # Step 3: First keyword must be SELECT or WITH
  defp check_first_keyword(tokens) do
    first_word =
      Enum.find(tokens, fn
        {:word, _} -> true
        _ -> false
      end)

    case first_word do
      {:word, w} ->
        upper = String.upcase(w)

        if upper in ["SELECT", "WITH"] do
          :ok
        else
          {:error,
           "query must start with SELECT or WITH, got '#{w}'"}
        end

      nil ->
        {:error, "empty query"}
    end
  end

  # Step 4: Reject WITH RECURSIVE
  defp check_no_recursive_cte(tokens) do
    words =
      tokens
      |> Enum.filter(fn
        {:word, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:word, w} -> String.upcase(w) end)

    case words do
      ["WITH", "RECURSIVE" | _] -> {:error, "WITH RECURSIVE is not allowed"}
      _ -> :ok
    end
  end

  # Step 5: Denylist scan — reject if any keyword token matches
  defp check_denylist(tokens) do
    found =
      Enum.find(tokens, fn
        {:word, w} -> String.upcase(w) in @denied_keywords
        _ -> false
      end)

    case found do
      {:word, w} -> {:error, "forbidden keyword '#{String.upcase(w)}' in query SQL"}
      nil -> :ok
    end
  end

  # Extract named params from the original SQL and replace with ?
  defp extract_params(sql) do
    # Track params seen to maintain ordering for first occurrence
    {result_sql, params} = do_extract_params(sql, :normal, [], [])
    positional = IO.iodata_to_binary(result_sql)
    # Unique order of first appearance
    unique_order = params |> Enum.reverse() |> Enum.uniq()
    {positional, unique_order}
  end

  defp do_extract_params(<<>>, _state, sql_acc, params), do: {Enum.reverse(sql_acc), params}

  # Enter quoted string
  defp do_extract_params(<<q, rest::binary>>, :normal, sql_acc, params)
       when q in [?', ?", ?`],
       do: do_extract_params(rest, {:quoted, q}, [<<q>> | sql_acc], params)

  # Exit quoted (escaped double)
  defp do_extract_params(<<q, q, rest::binary>>, {:quoted, q}, sql_acc, params),
    do: do_extract_params(rest, {:quoted, q}, [<<q, q>> | sql_acc], params)

  # Exit quoted
  defp do_extract_params(<<q, rest::binary>>, {:quoted, q}, sql_acc, params),
    do: do_extract_params(rest, :normal, [<<q>> | sql_acc], params)

  # Inside quotes — pass through
  defp do_extract_params(<<c, rest::binary>>, {:quoted, _} = state, sql_acc, params),
    do: do_extract_params(rest, state, [<<c>> | sql_acc], params)

  # Named param :name
  defp do_extract_params(<<?:, rest::binary>>, :normal, sql_acc, params) do
    {name, remaining} = read_param_name(rest, [])

    if name == "" do
      do_extract_params(rest, :normal, [":" | sql_acc], params)
    else
      do_extract_params(remaining, :normal, ["?" | sql_acc], [name | params])
    end
  end

  # Normal character
  defp do_extract_params(<<c, rest::binary>>, :normal, sql_acc, params),
    do: do_extract_params(rest, :normal, [<<c>> | sql_acc], params)

  defp read_param_name(<<c, rest::binary>>, acc)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) or c == ?_ do
    read_param_name(rest, [<<c>> | acc])
  end

  defp read_param_name(rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
end
