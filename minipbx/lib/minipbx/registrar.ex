defmodule MiniPbx.Registrar do
  @moduledoc """
  RFC 3261 section 10 registrar with digest authentication. One binding per extension (the latest wins).
  Bindings live in ETS and expire; they are not persisted (phones re-register after a restart).
  """
  use GenServer

  alias MiniPbx.{Auth, Events, Message, Store, Transport}

  @table :minipbx_regs
  @min_expires 60
  @max_expires 3600
  @default_expires 3600

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, 5_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, st) do
    now = now()
    dead = for {number, b} <- :ets.tab2list(@table), b.expires_at < now, do: number
    Enum.each(dead, &:ets.delete(@table, &1))
    if dead != [], do: Events.broadcast(%{type: "dirty", what: "regs"})
    Process.send_after(self(), :sweep, 5_000)
    {:noreply, st}
  end

  def handle_info(_, st), do: {:noreply, st}

  defp now, do: System.system_time(:second)

  ## Lookups

  @doc "Current binding of `number` or nil: %{dest: {ip, port}, contact: uri, ua, expires_at, since}."
  def lookup(number) do
    case :ets.lookup(@table, number) do
      [{_, b}] -> if b.expires_at >= now(), do: b, else: nil
      [] -> nil
    end
  end

  def all do
    t = now()

    for {number, b} <- :ets.tab2list(@table), b.expires_at >= t do
      {ip, port} = b.dest

      %{
        "number" => number,
        "ip" => ip |> :inet.ntoa() |> to_string(),
        "port" => port,
        "contact" => b.contact,
        "ua" => b.ua,
        "expires_in" => b.expires_at - t,
        "since" => DateTime.from_unix!(b.since) |> DateTime.to_iso8601()
      }
    end
    |> Enum.sort_by(& &1["number"])
  end

  def remove(number) do
    :ets.delete(@table, number)
    Events.broadcast(%{type: "dirty", what: "regs"})
    :ok
  end

  @doc """
  Where to send requests for a contact: the Contact port when it is on the address the request came
  from (a phone listening on its own port), otherwise the source address (NAT, host names).
  """
  def dest_for(contact, {sip, _sport} = src) do
    with %{host: h, port: p} <- Message.parse_uri(contact),
         {:ok, ^sip} <- :inet.parse_ipv4_address(String.to_charlist(h)) do
      {sip, p || 5060}
    else
      _ -> src
    end
  end

  ## REGISTER

  def handle(req, {ip, _} = src) do
    to = Message.parse_uri(Message.addr_uri(Message.header(req, "to")))
    number = to && to.user
    ext = number && Store.extension(number)

    case Auth.check(req, "authorization", ext, ip) do
      :forbidden ->
        Transport.reply(req, src, 403, "Forbidden", to_tag: tag())

      {:challenge, stale} ->
        Transport.reply(req, src, 401, "Unauthorized", to_tag: tag(), headers: [Auth.challenge_header(:www, stale)])

      :ok ->
        bind(req, src, number)
    end
  end

  defp bind(req, src, number) do
    contacts = req |> Message.headers("contact") |> Enum.flat_map(&Message.split_commas/1)
    header_expires = to_int(Message.header(req, "expires"))

    case contacts do
      [] ->
        ok(req, src, number, nil)

      ["*"] ->
        if header_expires == 0 do
          :ets.delete(@table, number)
          Events.broadcast(%{type: "dirty", what: "regs"})
          ok(req, src, number, nil)
        else
          Transport.reply(req, src, 400, "Bad Request", to_tag: tag())
        end

      [first | _] ->
        uri = Message.addr_uri(first)
        expires = to_int(Message.param(first, "expires")) || header_expires || @default_expires

        cond do
          Message.parse_uri(uri) == nil ->
            Transport.reply(req, src, 400, "Bad Request", to_tag: tag())

          expires == 0 ->
            :ets.delete(@table, number)
            Events.broadcast(%{type: "dirty", what: "regs"})
            ok(req, src, number, nil)

          true ->
            expires = expires |> max(@min_expires) |> min(@max_expires)
            old = lookup(number)
            dest = dest_for(uri, src)

            binding = %{
              dest: dest,
              contact: uri,
              ua: req |> Message.header("user-agent") |> to_string() |> String.slice(0, 80),
              expires_at: now() + expires,
              since: if(old && old.dest == dest, do: old.since, else: now())
            }

            :ets.insert(@table, {number, binding})
            if old == nil or old.dest != dest, do: Events.broadcast(%{type: "dirty", what: "regs"})
            ok(req, src, number, {first, expires})
        end
    end
  end

  defp ok(req, src, number, bound) do
    contact =
      case bound do
        {first, expires} ->
          [{"contact", Regex.replace(~r/;\s*expires=\d+/i, first, "") <> ";expires=#{expires}"}]

        nil ->
          case lookup(number) do
            nil -> []
            b -> [{"contact", "<#{b.contact}>;expires=#{max(b.expires_at - now(), 0)}"}]
          end
      end

    Transport.reply(req, src, 200, "OK", to_tag: tag(), headers: contact ++ [{"date", http_date()}])
  end

  defp http_date do
    Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")
  end

  defp to_int(nil), do: nil

  defp to_int(s) do
    case Integer.parse(to_string(s)) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp tag, do: Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
end
