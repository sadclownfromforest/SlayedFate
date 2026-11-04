defmodule MiniPbx.Auth do
  @moduledoc """
  Digest challenge/response for REGISTER and INVITE, with server-made nonces and a per-IP
  brute-force limit (10 failures / 60 s -> blocked for 5 minutes).
  """
  use GenServer

  alias MiniPbx.{Digest, Message, Store}

  @nonces :minipbx_nonces
  @fails :minipbx_fails
  @nonce_ttl 300_000
  @max_fails 10
  @window 60_000
  @block 300_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@nonces, [:named_table, :public, :set])
    :ets.new(@fails, [:named_table, :public, :set])
    Process.send_after(self(), :sweep, 30_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, st) do
    now = now()
    :ets.select_delete(@nonces, [{{:_, :"$1"}, [{:<, :"$1", now - @nonce_ttl}], [true]}])
    :ets.select_delete(@fails, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, 30_000)
    {:noreply, st}
  end

  def handle_info(_, st), do: {:noreply, st}

  defp now, do: System.monotonic_time(:millisecond)

  def new_nonce do
    n = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    :ets.insert(@nonces, {n, now()})
    n
  end

  @doc ":ok | :stale | :unknown"
  def nonce_state(nonce) do
    case :ets.lookup(@nonces, nonce) do
      [{_, t}] -> if now() - t <= @nonce_ttl, do: :ok, else: :stale
      [] -> :unknown
    end
  end

  def blocked?(ip) do
    case :ets.lookup(@fails, ip) do
      [{_, n, until}] -> n >= @max_fails and until > now()
      [] -> false
    end
  end

  def record_failure(ip) do
    t = now()

    case :ets.lookup(@fails, ip) do
      [{_, n, until}] when until > t ->
        new_until = if n + 1 >= @max_fails, do: t + @block, else: until
        :ets.insert(@fails, {ip, n + 1, new_until})

      _ ->
        :ets.insert(@fails, {ip, 1, t + @window})
    end

    :ok
  end

  def clear_failures(ip), do: :ets.delete(@fails, ip)

  @doc """
  Check the credentials in header `hdr_name` ("authorization" or "proxy-authorization") of `req`
  against extension `ext` (a Store extension map or nil). Returns
  `:ok | {:challenge, stale?} | :forbidden`. An unknown extension never gets `:ok` and gets the same
  answers as a known one (no user enumeration).
  """
  def check(req, hdr_name, ext, ip) do
    cond do
      blocked?(ip) ->
        :forbidden

      true ->
        case Message.header(req, hdr_name) do
          nil -> {:challenge, false}
          value -> verify(req, value, ext, ip)
        end
    end
  end

  defp verify(req, value, ext, ip) do
    params = Digest.parse_challenge(value)

    cond do
      params == nil ->
        record_failure(ip)
        {:challenge, false}

      true ->
        case nonce_state(Map.get(params, "nonce", "")) do
          :ok ->
            if ext != nil and Map.get(params, "username") == ext["number"] and
                 Digest.verify(params, req.method, ext["ha1"]) do
              clear_failures(ip)
              :ok
            else
              record_failure(ip)
              {:challenge, false}
            end

          :stale ->
            {:challenge, true}

          :unknown ->
            record_failure(ip)
            {:challenge, false}
        end
    end
  end

  @doc "Header tuple for a 401 (register) or 407 (invite) response."
  def challenge_header(kind, stale) do
    value = Digest.challenge(Store.settings()["realm"], new_nonce(), stale)
    name = if kind == :proxy, do: "proxy-authenticate", else: "www-authenticate"
    {name, value}
  end
end
