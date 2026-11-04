defmodule MiniPbx.Store do
  @moduledoc """
  Extensions, routes and settings, kept in memory and saved as JSON in `DATA_DIR/pbx.json` (mode 600).
  Passwords are never stored: only HA1 = MD5(number:realm:password), which is all digest auth needs.
  """
  use GenServer
  require Logger

  alias MiniPbx.{Config, Digest, Events}

  @defaults %{
    "realm" => "minipbx",
    "ring_timeout" => 30,
    "auth_calls" => true,
    "public_host" => ""
  }
  @max_items 500
  @num_re ~r/^[0-9A-Za-z]{1,16}$/
  @fwd_kinds ["always", "busy", "noanswer", "unreachable"]

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  ## Reads

  def extensions, do: GenServer.call(__MODULE__, :extensions)
  def extension(number), do: GenServer.call(__MODULE__, {:extension, number})
  def routes, do: GenServer.call(__MODULE__, :routes)
  def settings, do: GenServer.call(__MODULE__, :settings)

  @doc "Extension as shown in the UI: no HA1, plus `has_password`."
  def public(ext), do: ext |> Map.delete("ha1") |> Map.put("has_password", ext["ha1"] not in [nil, ""])

  ## Writes (all return :ok | {:ok, value} | {:error, message})

  def save_extension(params), do: GenServer.call(__MODULE__, {:save_extension, params})
  def delete_extension(number), do: GenServer.call(__MODULE__, {:delete_extension, number})
  def save_route(params), do: GenServer.call(__MODULE__, {:save_route, params})
  def delete_route(id), do: GenServer.call(__MODULE__, {:delete_route, id})
  def move_route(id, dir), do: GenServer.call(__MODULE__, {:move_route, id, dir})
  def save_settings(params), do: GenServer.call(__MODULE__, {:save_settings, params})

  ## Server

  @impl true
  def init(_) do
    {:ok, load()}
  end

  @impl true
  def handle_call(:extensions, _f, st), do: {:reply, st.extensions |> Map.values() |> Enum.sort_by(& &1["number"]), st}
  def handle_call({:extension, n}, _f, st), do: {:reply, Map.get(st.extensions, n), st}
  def handle_call(:routes, _f, st), do: {:reply, st.routes, st}
  def handle_call(:settings, _f, st), do: {:reply, st.settings, st}

  def handle_call({:save_extension, p}, _f, st) do
    with {:ok, number} <- number(p["number"], "Number"),
         {:ok, fwds} <- forwards(p),
         {:ok, ha1} <- password(p["password"], number, Map.get(st.extensions, number), st.settings["realm"]),
         :ok <- limit(map_size(st.extensions), Map.has_key?(st.extensions, number)) do
      ext =
        Map.merge(fwds, %{
          "number" => number,
          "name" => clean_text(p["name"], 40),
          "ha1" => ha1
        })

      commit(st, %{st | extensions: Map.put(st.extensions, number, ext)}, {:ok, public(ext)}, "config")
    else
      {:error, _} = e -> {:reply, e, st}
    end
  end

  def handle_call({:delete_extension, n}, _f, st) do
    if Map.has_key?(st.extensions, n) do
      commit(st, %{st | extensions: Map.delete(st.extensions, n)}, :ok, "config")
    else
      {:reply, {:error, "No such extension"}, st}
    end
  end

  def handle_call({:save_route, p}, _f, st) do
    pattern = clean_text(p["pattern"], 40)
    target = clean_text(p["target"], 40)

    cond do
      not Regex.match?(~r/^_?[0-9A-Za-z*#.]+$/, pattern) ->
        {:reply, {:error, "Pattern: digits/letters, X Z N and a final dot, e.g. 100 or _1XX."}, st}

      not Regex.match?(~r/^[0-9A-Za-z*#]+$|^[0-9A-Za-z*#]*\$\{EXTEN\}[0-9A-Za-z*#]*$/, target) ->
        {:reply, {:error, "Target: a number (it may contain ${EXTEN})."}, st}

      true ->
        id = if is_binary(p["id"]) and p["id"] != "", do: p["id"], else: new_id()
        route = %{"id" => id, "pattern" => pattern, "target" => target, "note" => clean_text(p["note"], 80), "enabled" => p["enabled"] != false}

        cond do
          Enum.any?(st.routes, &(&1["id"] == id)) ->
            routes = Enum.map(st.routes, fn r -> if r["id"] == id, do: route, else: r end)
            commit(st, %{st | routes: routes}, {:ok, route}, "config")

          length(st.routes) >= @max_items ->
            {:reply, {:error, "Too many routes"}, st}

          true ->
            commit(st, %{st | routes: st.routes ++ [route]}, {:ok, route}, "config")
        end
    end
  end

  def handle_call({:delete_route, id}, _f, st) do
    commit(st, %{st | routes: Enum.reject(st.routes, &(&1["id"] == id))}, :ok, "config")
  end

  def handle_call({:move_route, id, dir}, _f, st) do
    idx = Enum.find_index(st.routes, &(&1["id"] == id))
    to = if dir == "up", do: (idx || 0) - 1, else: (idx || 0) + 1

    if idx == nil or to < 0 or to >= length(st.routes) do
      {:reply, :ok, st}
    else
      {item, rest} = List.pop_at(st.routes, idx)
      commit(st, %{st | routes: List.insert_at(rest, to, item)}, :ok, "config")
    end
  end

  def handle_call({:save_settings, p}, _f, st) do
    old = st.settings
    realm = clean_text(p["realm"] || old["realm"], 40)
    ring = to_int(p["ring_timeout"], old["ring_timeout"])
    host = clean_text(p["public_host"] || "", 100)

    cond do
      realm == "" or String.contains?(realm, "\"") ->
        {:reply, {:error, "Realm must not be empty or contain quotes."}, st}

      realm != old["realm"] and map_size(st.extensions) > 0 ->
        {:reply, {:error, "The realm is part of every stored password hash. Delete the extensions first, or keep the realm."}, st}

      ring < 5 or ring > 300 ->
        {:reply, {:error, "Ring timeout must be 5-300 seconds."}, st}

      not Regex.match?(~r/^[0-9A-Za-z.\-:]*$/, host) ->
        {:reply, {:error, "Public host: an IP address or host name."}, st}

      true ->
        s = %{"realm" => realm, "ring_timeout" => ring, "auth_calls" => p["auth_calls"] != false, "public_host" => host}
        commit(st, %{st | settings: s}, {:ok, s}, "config")
    end
  end

  ## Validation helpers

  defp number(n, label) when is_binary(n) do
    n = String.trim(n)
    if Regex.match?(@num_re, n), do: {:ok, n}, else: {:error, "#{label}: 1-16 letters or digits."}
  end

  defp number(_, label), do: {:error, "#{label}: 1-16 letters or digits."}

  defp forwards(p) do
    Enum.reduce_while(@fwd_kinds, {:ok, %{}}, fn kind, {:ok, acc} ->
      key = "forward_" <> kind
      v = (p[key] || "") |> to_string() |> String.trim()

      cond do
        v == "" -> {:cont, {:ok, Map.put(acc, key, "")}}
        Regex.match?(@num_re, v) -> {:cont, {:ok, Map.put(acc, key, v)}}
        true -> {:halt, {:error, "Forward (#{kind}): 1-16 letters or digits, or empty."}}
      end
    end)
  end

  defp password(pw, number, existing, realm) do
    pw = if is_binary(pw), do: pw, else: ""

    cond do
      pw == "" and existing != nil -> {:ok, existing["ha1"]}
      pw == "" -> {:error, "A password is required for a new extension."}
      String.length(pw) < 4 -> {:error, "Password: at least 4 characters."}
      String.length(pw) > 100 -> {:error, "Password is too long."}
      true -> {:ok, Digest.ha1(number, realm, pw)}
    end
  end

  defp limit(count, exists?), do: if(exists? or count < @max_items, do: :ok, else: {:error, "Too many extensions"})

  defp clean_text(v, max) when is_binary(v) do
    v |> String.replace(~r/[\x00-\x1f\x7f"<>]/u, "") |> String.trim() |> String.slice(0, max)
  end

  defp clean_text(_, _), do: ""

  defp to_int(v, _) when is_integer(v), do: v

  defp to_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp to_int(_, default), do: default

  defp new_id, do: Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

  ## Persistence

  defp commit(old, new, reply, what) do
    case save(new) do
      :ok ->
        Events.broadcast(%{type: "dirty", what: what})
        if what == "config", do: Events.broadcast(%{type: "dirty", what: "regs"})
        {:reply, reply, new}

      {:error, reason} ->
        Logger.error("cannot save #{file()}: #{inspect(reason)}")
        {:reply, {:error, "Could not save the data file (#{inspect(reason)})"}, old}
    end
  end

  defp file, do: Path.join(Config.data_dir(), "pbx.json")

  defp save(st) do
    data = JSON.encode!(%{"extensions" => Map.values(st.extensions), "routes" => st.routes, "settings" => st.settings})
    tmp = file() <> ".tmp"

    with :ok <- File.mkdir_p(Config.data_dir()),
         :ok <- File.write(tmp, data),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, file()) do
      :ok
    end
  end

  defp load do
    base = %{extensions: %{}, routes: [], settings: @defaults}

    with {:ok, text} <- File.read(file()),
         {:ok, %{} = data} <- JSON.decode(text) do
      exts =
        for %{"number" => n} = e <- List.wrap(data["extensions"]), into: %{} do
          {n, Map.merge(%{"name" => "", "ha1" => "", "forward_always" => "", "forward_busy" => "", "forward_noanswer" => "", "forward_unreachable" => ""}, e)}
        end

      %{
        extensions: exts,
        routes: Enum.filter(List.wrap(data["routes"]), &is_map/1),
        settings: Map.merge(@defaults, if(is_map(data["settings"]), do: data["settings"], else: %{}))
      }
    else
      _ -> base
    end
  end
end
