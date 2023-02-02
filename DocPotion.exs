defmodule DocPotion do
    def _read({directory, layouts}) do
        Enum.map(layouts, fn filename -> {filename, File.read!("#{directory}/#{filename}")} end)
    end

    def _alchemy({filename, layout}) do
        pattern = ~r/{([A-Za-z\.]+)}/ # The regex pattern to alchemize
        {String.replace(filename, ".layout", ""), Regex.replace(pattern, layout, fn _, partial -> File.read!("docs/partials/#{partial}") end)}
    end

    def _write({docname, content}) do
        watermark = "\n\n<!-- This file was generated by DocPotion -->\n"
        File.write!("#{docname}", "#{content}#{watermark}")
    end

    @doc """
    - Reads .layout(.md) files from directory (_read)
    - Replaces regex pattern with corresponding partials (_alchemy)
    - Writes full documents to the root directory (_write)

    Returns `{:ok, doc_count}` for success or raises runtime error upon failure

    ## Examples

        iex> DocPotion.build
        {:ok, doc_count}
 
    """
    def build() do
        directory = "docs/layouts" # The directory to read layouts from
        filenames = File.ls!(directory)
        layouts = {directory, filenames}

        result = _read(layouts)
        |> Enum.map(fn layouts -> _alchemy(layouts) end)
        |> Enum.each(fn docs -> _write(docs) end)

        {result, length(filenames)}
    end

    def success(count), do: IO.puts("Successfully built #{count} document file#{if count > 1 do "s" end}!")
    def error(e), do: raise "Error running #{__MODULE__}:\n#{e}!"
end

case DocPotion.build do
    {:ok, doc_count} -> DocPotion.success(doc_count)
    e -> DocPotion.error(e)
end
