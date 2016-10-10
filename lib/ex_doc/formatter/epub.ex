defmodule ExDoc.Formatter.EPUB do
  @moduledoc """
  Provide EPUB documentation
  """

  alias ExDoc.Formatter.HTML
  alias ExDoc.Formatter.EPUB.Templates

  @doc """
  Generate EPUB documentation for the given modules
  """
  @spec run(list, ExDoc.Config.t) :: String.t
  def run(module_nodes, config) when is_map(config) do
    output = Path.expand(config.output)
    File.rm_rf!(output)
    File.mkdir_p!("#{output}/OEBPS")

    assets() |> HTML.assets_path("epub") |> HTML.generate_assets(output)

    all = HTML.Autolink.all(module_nodes, ".xhtml", config.deps)
    modules = HTML.filter_list(:modules, all)
    exceptions = HTML.filter_list(:exceptions, all)
    protocols = HTML.filter_list(:protocols, all)

    config =
      if config.logo do
        HTML.process_logo_metadata(config, "#{config.output}/OEBPS/assets")
      else
        config
      end

    generate_mimetype(output)
    generate_extras(output, config, module_nodes)

    uuid = "urn:uuid:#{uuid4()}"
    datetime = format_datetime()
    nodes = modules ++ exceptions ++ protocols

    generate_content(output, config, nodes, uuid, datetime)
    generate_toc(output, config, nodes, uuid)
    generate_nav(output, config, nodes)
    generate_title(output, config)
    generate_list(output, config, modules)
    generate_list(output, config, exceptions)
    generate_list(output, config, protocols)

    {:ok, epub_file} = generate_epub(output, config)
    delete_extras(output)

    epub_file
  end

  defp generate_mimetype(output) do
    content = "application/epub+zip"
    File.write("#{output}/mimetype", content)
  end

  defp generate_extras(output, config, module_nodes) do
    config.extras
    |> Enum.map(&Task.async(fn ->
         create_extra_files(&1, output, config, module_nodes)
       end))
    |> Enum.map(&Task.await(&1, :infinity))
  end

  defp create_extra_files(input, output, config, module_nodes) do
    if HTML.valid_extension_name?(input) do
      content =
        input
        |> File.read!()
        |> HTML.Autolink.project_doc(module_nodes, nil, ".xhtml")

      html_content = ExDoc.Markdown.to_html(content, file: input, line: 1)

      file_name =
        input
        |> Path.basename(".md")
        |> String.upcase()

      config = Map.put(config, :title, file_name)
      extra_html = Templates.extra_template(config, html_content)

      File.write!("#{output}/OEBPS/#{file_name}.xhtml", extra_html)
    else
      raise ArgumentError, "file format not recognized, allowed format is: .md"
    end
  end

  defp generate_content(output, config, nodes, uuid, datetime) do
    content = Templates.content_template(config, nodes, uuid, datetime)
    File.write("#{output}/OEBPS/content.opf", content)
  end

  defp generate_toc(output, config, nodes, uuid) do
    content = Templates.toc_template(config, nodes, uuid)
    File.write("#{output}/OEBPS/toc.ncx", content)
  end

  defp generate_nav(output, config, nodes) do
    content = Templates.nav_template(config, nodes)
    File.write("#{output}/OEBPS/nav.xhtml", content)
  end

  defp generate_title(output, config) do
    content = Templates.title_template(config)
    File.write("#{output}/OEBPS/title.xhtml", content)
  end

  defp generate_list(output, config, nodes) do
    nodes
    |> Enum.map(&Task.async(fn ->
         generate_module_page(output, config, &1)
       end))
    |> Enum.map(&Task.await(&1, :infinity))
  end

  defp generate_epub(output, config) do
    output = Path.expand(output)
    target_path =
      String.to_char_list("#{output}/#{config.project}-v#{config.version}.epub")

    :zip.create(target_path,
                files_to_add(output),
                compress: ['.css', '.xhtml', '.html', '.ncx',
                           '.opf', '.jpg', '.png', '.xml'])
  end

  defp delete_extras(output) do
    for target <- ["META-INF", "mimetype", "OEBPS"] do
      File.rm_rf! "#{output}/#{target}"
    end
    :ok
  end

  ## Helpers
  defp assets do
   [{"dist/*.{css,js}", "OEBPS/dist" },
    {"assets/*.xml", "META-INF" },
    {"assets/mimetype", "." }]
  end

  defp files_to_add(path) do
    meta = Path.wildcard(Path.join(path, "META-INF/*"))
    oebps = Path.wildcard(Path.join(path, "OEBPS/**/*"))

    Enum.reduce meta ++ oebps ++ [Path.join(path, "mimetype")], [], fn(f, acc) ->
      case File.read(f) do
        {:ok, bin} ->
          [{String.to_char_list(f), bin}|acc]
        {:error, _} ->
          acc
      end
    end
  end

  # Helper to format Erlang datetime tuple
  defp format_datetime do
    {{year, month, day}, {hour, min, sec}} = :calendar.universal_time()
    list = [year, month, day, hour, min, sec]
    "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ"
    |> :io_lib.format(list)
    |> IO.iodata_to_binary()
  end

  defp generate_module_page(output, config, node) do
    content = Templates.module_page(config, node)
    File.write("#{output}/OEBPS/#{node.id}.xhtml", content)
  end

  # Helper to generate an UUID v4. This version uses pseudo-random bytes generated by
  # the `crypto` module.
  defp uuid4 do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    bin = <<u0::48, 4::4, u1::12, 2::2, u2::62>>
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = bin

    Enum.map_join([<<u0::32>>, <<u1::16>>, <<u2::16>>, <<u3::16>>, <<u4::48>>], <<45>>,
                  &(Base.encode16(&1, case: :lower)))
  end
end