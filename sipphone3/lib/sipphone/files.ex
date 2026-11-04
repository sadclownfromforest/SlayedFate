defmodule SipPhone.Files do
  @moduledoc """
  Read-only access to the project's own source files for the web UI.

  Safety model (defence in depth):
    * allowlist: only a few project folders and root files, only text extensions;
    * denylist: anything whose path looks private (env files, keys, saved accounts,
      data dir, .git, build output, local settings, names with secret/password/token...);
    * symlinks are never followed or listed;
    * the content is scanned for private-key blocks;
    * `read/1` only serves paths that appear in `list/0` - no path is ever joined
      from user input, so traversal such as `../` cannot match anything.
  """

  @roots ["lib", "priv", "test", ".claude/skills"]
  @root_files ["mix.exs", "Makefile", "Dockerfile", "README.md", "CLAUDE.md"]
  @exts [".ex", ".exs", ".js", ".css", ".html", ".svg", ".md"]
  @max_size 262_144

  @deny_path ~r/(^|\/)(\.env[^\/]*|\.git|\.ssh|_build|deps|data|node_modules|settings\.local[^\/]*|accounts\.json|id_(rsa|dsa|ecdsa|ed25519)[^\/]*)(\/|$)/i
  @deny_name ~r/(secret|password|passwd|credential|private|token|apikey|api_key|\.pem$|\.key$|\.p12$|\.pfx$|\.crt$)/i
  @private_block ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/

  def root, do: System.get_env("SIPPHONE_SRC") || File.cwd!()

  @doc "Sorted list of %{path, size} for every file that may be shown."
  def list do
    root = root()

    candidates =
      Enum.flat_map(@roots, &walk(root, &1)) ++
        Enum.filter(@root_files, &regular?(Path.join(root, &1)))

    candidates
    |> Enum.filter(&allowed?(root, &1))
    |> Enum.sort()
    |> Enum.map(fn rel ->
      {:ok, %File.Stat{size: size}} = File.lstat(Path.join(root, rel))
      %{path: rel, size: size}
    end)
  end

  @doc "Content of a listed file, or {:error, reason}."
  def read(path) when is_binary(path) do
    if Enum.any?(list(), &(&1.path == path)) do
      case File.read(Path.join(root(), path)) do
        {:ok, content} -> {:ok, content}
        _ -> {:error, "File not available"}
      end
    else
      {:error, "File not available"}
    end
  end

  def read(_), do: {:error, "File not available"}

  ## ------------------------------------------------------------------

  defp walk(root, rel) do
    abs = Path.join(root, rel)

    case File.lstat(abs) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(abs) do
          {:ok, names} -> Enum.flat_map(names, &walk(root, rel <> "/" <> &1))
          _ -> []
        end

      {:ok, %File.Stat{type: :regular}} ->
        [rel]

      # symlinks, sockets, devices: ignored
      _ ->
        []
    end
  end

  defp regular?(abs), do: match?({:ok, %File.Stat{type: :regular}}, File.lstat(abs))

  defp allowed?(root, rel) do
    name = Path.basename(rel)

    not Regex.match?(@deny_path, rel) and
      not Regex.match?(@deny_name, name) and
      (Path.extname(name) in @exts or name in ["Makefile", "Dockerfile"]) and
      safe_content?(Path.join(root, rel))
  end

  defp safe_content?(abs) do
    with {:ok, %File.Stat{size: size, type: :regular}} <- File.lstat(abs),
         true <- size <= @max_size,
         {:ok, content} <- File.read(abs) do
      String.valid?(content) and not String.contains?(content, <<0>>) and
        not Regex.match?(@private_block, content)
    else
      _ -> false
    end
  end
end
