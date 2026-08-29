defmodule DocPotion do
@readme """
  DocPotion — tiny markdown preprocessor for alchemizing repo documentation

  ## Pipeline
    1. `load_partials/2` — reads every file in the partials dir, resolving
       nested `{partial}` tokens recursively. `.eex` partials are rendered
       with EEx first (bound with `count: doc_count`).
    2. `load_layouts/1`  — reads every `*.layout.md` file from the layouts dir.
    3. `brew/2`          — substitutes `{partial}` tokens in each layout.
    4. `write_all/2`     — writes the finished documents to the write dir.

  Run directly:

      elixir DocPotion.exs
      elixir DocPotion.exs --docs     # print this module doc and exit

  Configure via `.docpotion.exs` in the working directory — a plain
  Elixir file that evaluates to a map, e.g.:

      %{layouts_dir: "docs/layouts", partials_dir: "docs/partials", write_dir: "build/"}

  Returns `{:ok, doc_count}` on success. Failures no longer crash with a
  raw stacktrace — they're caught and reported as `{:error, reason}`.
  """
  @moduledoc @readme

  @config_file ".docpotion.exs"
  @default_config %{
    layouts_dir: "docs/layouts",
    partials_dir: "docs/partials",
    write_dir: "./"
  }

  # Non-greedy + no nested braces, so "{a}{b}" resolves as two tokens
  # instead of one (the old `~r/{(.+)}/` was greedy and line-wide).
  @token ~r/\{([^{}]+)\}/

  ## --- Public API ---------------------------------------------------------

  @doc """
  Builds every layout into a finished document.
  Returns `{:ok, doc_count}` or `{:error, reason}`.
  """
  def build do
    config = load_config()

    with {:ok, filenames} <- safe_ls(config.layouts_dir),
         doc_count = length(filenames),
         {:ok, partials} <- load_partials(config.partials_dir, doc_count),
         {:ok, layouts} <- load_layouts(config.layouts_dir, filenames),
         documents = Enum.map(layouts, &brew(&1, partials)),
         :ok <- write_all(documents, config.write_dir) do
      {:ok, doc_count}
    end
  end

  ## --- Config ---------------------------------------------------------------

  defp load_config do
    if File.regular?(@config_file) do
      try do
        case Code.eval_file(@config_file) do
          {%{} = user_config, _bindings} -> Map.merge(@default_config, user_config)
          _ -> @default_config
        end
      rescue
        _ -> @default_config
      end
    else
      @default_config
    end
  end

  ## --- Loading --------------------------------------------------------------

  defp load_layouts(read_dir, filenames) do
    result =
      Enum.reduce_while(filenames, {:ok, []}, fn filename, {:ok, acc} ->
        case safe_read("#{read_dir}/#{filename}") do
          {:ok, content} -> {:cont, {:ok, [{filename, content} | acc]}}
          {:error, reason} -> {:halt, {:error, {filename, reason}}}
        end
      end)

    case result do
      {:ok, layouts} -> {:ok, Enum.reverse(layouts)}
      error -> error
    end
  end

  defp load_partials(read_dir, doc_count) do
    case safe_ls(read_dir) do
      {:ok, filenames} ->
        result =
          Enum.reduce_while(filenames, {:ok, %{}}, fn filename, {:ok, acc} ->
            case unfurl(read_dir, filename, doc_count) do
              {:ok, content} -> {:cont, {:ok, Map.put(acc, filename, content)}}
              {:error, reason} -> {:halt, {:error, {filename, reason}}}
            end
          end)

        result

      error ->
        error
    end
  end

  # Recursively resolves a partial, rendering .eex partials through EEx
  # first, then replacing any {partial} tokens found inside the result.
  defp unfurl(read_dir, filename, doc_count) do
    path = "#{read_dir}/#{filename}"
    extension = filename |> String.split(".") |> List.last()

    with {:ok, raw} <- render(path, extension, doc_count) do
      replace_tokens(raw, fn nested_name ->
        case unfurl(read_dir, nested_name, doc_count) do
          {:ok, content} -> {:ok, content}
          error -> error
        end
      end)
    end
  end

  defp render(path, "eex", doc_count) do
    try do
      eex = EEx.compile_file(path)
      {result, _bindings} = Code.eval_quoted(eex, count: doc_count)
      {:ok, result}
    rescue
      e -> {:error, "failed to render EEx partial #{path}: #{Exception.message(e)}"}
    end
  end

  defp render(path, _extension, _doc_count), do: safe_read(path)

  ## --- Substitution -----------------------------------------------------

  # Like Regex.replace/3, but short-circuits and bubbles up the first
  # {:error, reason} a callback returns instead of silently inlining it.
  defp replace_tokens(content, resolve) do
    tokens = Regex.scan(@token, content, capture: :all_but_first) |> List.flatten() |> Enum.uniq()

    Enum.reduce_while(tokens, {:ok, content}, fn token, {:ok, acc} ->
      case resolve.(token) do
        {:ok, replacement} ->
          {:cont, {:ok, String.replace(acc, "{#{token}}", replacement)}}

        {:error, _} = error ->
          {:halt, error}

        nil ->
          {:halt, {:error, "no partial found for {#{token}}"}}
      end
    end)
  end

  defp brew({filename, layout}, partials) do
    output_name = String.replace(filename, ".layout", "")

    case replace_tokens(layout, fn name -> Map.fetch(partials, name) end) do
      {:ok, content} -> {:ok, {output_name, content}}
      error -> error
    end
  end

  ## --- Writing ------------------------------------------------------------

  defp write_all(documents, write_dir) do
    Enum.reduce_while(documents, :ok, fn
      {:ok, {filename, content}}, :ok ->
        watermark = "\n\n<!-- This file was generated by DocPotion -->\n"

        case safe_write("#{write_dir}#{filename}", "#{content}#{watermark}") do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      {:error, _} = error, :ok ->
        {:halt, error}
    end)
  end

  ## --- Safe file IO (no more bare File.*! crashes) -------------------------

  defp safe_ls(dir) do
    case File.ls(dir) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, "could not read directory #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp safe_read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "could not read file #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp safe_write(path, content) do
    with :ok <- ensure_dir(path),
         :ok <- File.write(path, content) do
      :ok
    else
      {:error, reason} -> {:error, "could not write file #{path}: #{:file.format_error(reason)}"}
    end
  end

  # Creates the write dir on demand (e.g. `build/`) instead of failing
  # when the user points write_dir at a folder that doesn't exist yet.
  defp ensure_dir(path) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  ## --- CLI output -----------------------------------------------------------

  def success(count),
    do: IO.puts("Successfully built #{count} document file#{if count != 1, do: "s"}!")

  def error!(reason), do: IO.puts(:stderr, "DocPotion failed: #{inspect(reason)}")

  def print_docs, do: IO.puts(@readme)
end

case System.argv() do
  ["--docs"] ->
    DocPotion.print_docs()

  _ ->
    case DocPotion.build() do
      {:ok, doc_count} -> DocPotion.success(doc_count)
      {:error, reason} -> DocPotion.error!(reason)
    end
end
