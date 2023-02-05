defmodule DocPotion do
    def _loadlayouts({read_dir, layouts}) do
        Enum.map(layouts, fn filename -> {filename, File.read!("#{read_dir}/#{filename}")} end)
    end

    def _loadpartials(doc_count, read_dir \\ "docs/partials") do
        File.ls!(read_dir)
        |> Map.new(fn partial -> {partial, DocPotion._unfurl(read_dir, doc_count, partial)} end)
    end

    def _unfurl(read_dir, doc_count, partial) do
        [_, extension] = String.split(partial, ".")
        path = "#{read_dir}/#{partial}"
        if extension == "eex" do
            require EEx
            eex = EEx.compile_file(path)
            {result, _bindings} = Code.eval_quoted(eex, count: doc_count)
            result
        else
            DocPotion._replace(File.read!(path), fn _, filename -> DocPotion._unfurl(read_dir, doc_count, filename) end)
        end
    end

    def _replace(content, callback) do
        pattern = ~r/{(.+)}/
        Regex.replace(pattern, content, callback)
    end

    def _alchemy({filename, layout}, partials) do
        {String.replace(filename, ".layout", ""), DocPotion._replace(layout, fn _, filename -> Map.get(partials, filename) end)}
    end

    def _write({filename, content}, write_dir \\ "./") do
        watermark = "\n\n<!-- This file was generated by DocPotion -->\n"
        File.write!("#{write_dir}#{filename}", "#{content}#{watermark}")
    end

    @doc """
    - Reads (and _unfurl)s partial files from directory (_loadpartials)
    - Reads .layout(.md) files from directory (_loadlayouts)
    - Replaces regex pattern with corresponding partials (_alchemy)
    - Writes full documents to the root directory (_write)

    Returns `{:ok, doc_count}` for success or raises runtime error upon failure

    ## Examples

        iex> DocPotion.build
        {:ok, doc_count}
 
    """
    def build(read_dir \\ "docs/layouts") do
        filenames = File.ls!(read_dir)
        doc_count = length(filenames)
        partials = DocPotion._loadpartials(doc_count)

        result = _loadlayouts({read_dir, filenames})
        |> Enum.map(fn layout -> _alchemy(layout, partials) end)
        |> Enum.each(fn docs -> _write(docs) end)

        {result, doc_count}
    end

    def success(count), do: IO.puts("Successfully built #{count} document file#{if count > 1 do "s" end}!")
    def error(e), do: raise "Error running #{__MODULE__}:\n#{e}!"
end

case DocPotion.build do
    {:ok, doc_count} -> DocPotion.success(doc_count)
    e -> DocPotion.error(e)
end
