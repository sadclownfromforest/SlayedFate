defmodule MiniPbx.Cdr do
  @moduledoc """
  Call detail records: one per call, written when the call ends. Newest first in memory (last 5000),
  appended as JSON lines to `DATA_DIR/cdr.jsonl`.

  Fields: id, start, answer, end (UTC ISO-8601), caller, caller_name, callee (dialed), target (extension that
  was finally rung), disposition (ANSWERED | NO ANSWER | BUSY | FAILED), duration, billsec (seconds),
  route (rewrites/forwards applied), reason, src (caller IP).
  """
  use GenServer

  alias MiniPbx.{Config, Events}

  @max 5000
  @fields ~w(start answer end caller caller_name callee target disposition duration billsec route reason src id)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def add(rec), do: GenServer.call(__MODULE__, {:add, rec})
  def clear, do: GenServer.call(__MODULE__, :clear)
  def all, do: GenServer.call(__MODULE__, :all)

  @doc "Newest first. Options: `:limit` (default 500), `:q` (substring of caller/callee/target/disposition/reason)."
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)
    q = opts |> Keyword.get(:q, "") |> String.downcase()

    all()
    |> Enum.filter(fn r -> q == "" or matches?(r, q) end)
    |> Enum.take(limit)
  end

  defp matches?(r, q) do
    Enum.any?(~w(caller callee target disposition reason caller_name), fn k ->
      r |> Map.get(k, "") |> to_string() |> String.downcase() |> String.contains?(q)
    end)
  end

  @doc "All records as CSV (oldest first). Cells that could be read as spreadsheet formulas are neutralised."
  def csv do
    rows = all() |> Enum.reverse() |> Enum.map(fn r -> Enum.map(@fields, &cell(Map.get(r, &1))) end)
    ([@fields] ++ rows) |> Enum.map_join("\r\n", fn row -> Enum.join(row, ",") end) |> Kernel.<>("\r\n")
  end

  defp cell(nil), do: ""

  defp cell(v) do
    s = to_string(v)
    s = if String.starts_with?(s, ["=", "+", "-", "@", "\t", "\r"]), do: "'" <> s, else: s

    if String.contains?(s, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(s, "\"", "\"\"") <> "\"",
      else: s
  end

  @impl true
  def init(_) do
    {:ok, load()}
  end

  @impl true
  def handle_call({:add, rec}, _f, list) do
    append(rec)
    Events.broadcast(%{type: "dirty", what: "cdr"})
    {:reply, :ok, Enum.take([rec | list], @max)}
  end

  def handle_call(:clear, _f, _list) do
    File.write(file(), "")
    Events.broadcast(%{type: "dirty", what: "cdr"})
    {:reply, :ok, []}
  end

  def handle_call(:all, _f, list), do: {:reply, list, list}

  defp file, do: Path.join(Config.data_dir(), "cdr.jsonl")

  defp append(rec) do
    File.mkdir_p(Config.data_dir())
    File.write(file(), JSON.encode!(rec) <> "\n", [:append])
  end

  defp load do
    case File.read(file()) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case JSON.decode(line) do
            {:ok, %{} = r} -> [r]
            _ -> []
          end
        end)
        |> Enum.reverse()
        |> Enum.take(@max)

      _ ->
        []
    end
  end
end
