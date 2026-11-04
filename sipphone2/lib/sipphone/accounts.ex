defmodule SipPhone.Accounts do
  @moduledoc "Account configuration store: validation, persistence and process management."
  use GenServer
  require Logger

  alias SipPhone.{Account, Events}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def views, do: GenServer.call(__MODULE__, :views, 20_000)
  def calls, do: GenServer.call(__MODULE__, :calls, 20_000)
  def save(params), do: GenServer.call(__MODULE__, {:save, params}, 20_000)
  def delete(id), do: GenServer.call(__MODULE__, {:delete, id}, 20_000)

  ## ------------------------------------------------------------------

  @impl true
  def init(_) do
    configs = load()
    Enum.each(configs, &start_account/1)
    {:ok, %{configs: configs}}
  end

  @impl true
  def handle_call(:views, _from, st), do: {:reply, build_views(st.configs), st}

  def handle_call(:calls, _from, st) do
    calls =
      Enum.flat_map(st.configs, fn cfg ->
        case Account.snapshot(cfg.id) do
          %{calls: c} -> c
          _ -> []
        end
      end)

    {:reply, calls, st}
  end

  def handle_call({:save, params}, _from, st) when is_map(params) do
    existing =
      if is_binary(params["id"]),
        do: Enum.find(st.configs, fn c -> c.id == params["id"] end),
        else: nil

    others = Enum.reject(st.configs, fn c -> existing != nil and c.id == existing.id end)

    case normalize(params, existing, others) do
      {:ok, cfg} ->
        stop_account(cfg.id)

        configs =
          if existing,
            do: Enum.map(st.configs, fn c -> if c.id == cfg.id, do: cfg, else: c end),
            else: st.configs ++ [cfg]

        persist(configs)
        start_account(cfg)
        Events.broadcast(%{type: "accounts", accounts: build_views(configs)})
        {:reply, {:ok, cfg.id}, %{st | configs: configs}}

      {:error, msg} ->
        {:reply, {:error, msg}, st}
    end
  end

  def handle_call({:save, _}, _from, st), do: {:reply, {:error, "Invalid request"}, st}

  def handle_call({:delete, id}, _from, st) do
    stop_account(id)
    configs = Enum.reject(st.configs, fn c -> c.id == id end)
    persist(configs)
    Events.broadcast(%{type: "accounts", accounts: build_views(configs)})
    {:reply, :ok, %{st | configs: configs}}
  end

  ## ------------------------------------------------------------------
  ## Processes

  defp start_account(cfg) do
    case DynamicSupervisor.start_child(SipPhone.AccountSup, {Account, cfg}) do
      {:ok, _} -> :ok
      other -> Logger.error("cannot start account #{cfg.id}: #{inspect(other)}")
    end
  end

  defp stop_account(id) do
    case Registry.lookup(SipPhone.AccountReg, id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(SipPhone.AccountSup, pid)
      _ -> :ok
    end
  end

  defp build_views(configs) do
    Enum.map(configs, fn cfg ->
      base = cfg |> Map.delete(:password) |> Map.put(:has_password, cfg.password != "")

      case Account.snapshot(cfg.id) do
        %{status: s, status_text: t} -> Map.merge(base, %{status: s, status_text: t})
        _ -> Map.merge(base, %{status: "stopped", status_text: "Not running"})
      end
    end)
  end

  ## ------------------------------------------------------------------
  ## Validation

  defp normalize(p, existing, others) do
    get = fn key, default ->
      case Map.get(p, Atom.to_string(key)) do
        v when is_binary(v) -> String.trim(v)
        v when is_integer(v) -> Integer.to_string(v)
        _ -> if existing, do: to_string(Map.get(existing, key, default)), else: default
      end
    end

    bool = fn key, default ->
      case Map.get(p, Atom.to_string(key)) do
        v when is_boolean(v) -> v
        _ -> if existing, do: Map.get(existing, key, default), else: default
      end
    end

    username = get.(:username, "") |> String.replace(~r/[\s<>";@,\\\/?]/, "")
    name = get.(:name, "") |> clean_text()
    host_re = ~r/[^A-Za-z0-9.\-:\[\]_]/

    registrar =
      get.(:registrar, "") |> String.replace(~r/^sips?:/i, "") |> String.replace(host_re, "")

    used = Enum.map(others, fn c -> c.local_port end)

    port =
      case Integer.parse(get.(:local_port, "")) do
        {n, ""} when n >= 1 and n <= 65535 -> n
        _ -> if existing, do: existing.local_port, else: next_port(used)
      end

    expires =
      case Integer.parse(get.(:expires, "300")) do
        {n, _} when n > 0 -> n |> max(30) |> min(86_400)
        _ -> 300
      end

    password =
      case p["password"] do
        v when is_binary(v) and v != "" -> v
        _ -> (existing && existing.password) || ""
      end

    codec = if get.(:prefer_codec, "pcmu") == "pcma", do: "pcma", else: "pcmu"

    cfg = %{
      id: (existing && existing.id) || valid_id(p["id"]) || new_id(),
      name: if(name == "", do: username, else: name),
      display_name: get.(:display_name, "") |> clean_text(),
      username: username,
      auth_user: get.(:auth_user, "") |> String.replace(~r/[\s<>";,\\]/, ""),
      password: password,
      domain: get.(:domain, "") |> String.replace(host_re, ""),
      registrar: registrar,
      outbound_proxy:
        get.(:outbound_proxy, "") |> String.replace(~r/^sips?:/i, "") |> String.replace(host_re, ""),
      local_port: port,
      advertised_host: get.(:advertised_host, "") |> String.replace(host_re, ""),
      expires: expires,
      auto_answer: bool.(:auto_answer, false),
      prefer_codec: codec,
      register: bool.(:register, true)
    }

    cond do
      username == "" -> {:error, "Username is required"}
      port in used -> {:error, "SIP port #{port} is already used by another account"}
      true -> {:ok, cfg}
    end
  end

  defp clean_text(s), do: String.replace(s, ~r/["<>\r\n\\]/, "")

  defp valid_id(id) when is_binary(id), do: if(Regex.match?(~r/^[a-z0-9]{4,20}$/, id), do: id, else: nil)
  defp valid_id(_), do: nil

  defp new_id, do: "a" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

  defp next_port(used) do
    Enum.find(5070..5999, fn p -> p not in used end) || 6000
  end

  ## ------------------------------------------------------------------
  ## Persistence

  defp path, do: Path.join(SipPhone.Config.data_dir(), "accounts.json")

  defp load do
    with {:ok, bin} <- File.read(path()),
         {:ok, list} when is_list(list) <- JSON.decode(bin) do
      Enum.reduce(list, [], fn p, acc ->
        case is_map(p) && normalize(p, nil, acc) do
          {:ok, cfg} -> acc ++ [cfg]
          _ -> acc
        end
      end)
    else
      _ -> []
    end
  end

  defp persist(configs) do
    dir = SipPhone.Config.data_dir()

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path(), JSON.encode!(configs)) do
      File.chmod(path(), 0o600)
      :ok
    else
      err -> Logger.warning("could not save accounts to #{dir}: #{inspect(err)}")
    end
  end
end
