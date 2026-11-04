defmodule MiniPbx.Dialplan do
  @moduledoc """
  Pure number rewriting. A route maps a dialed number (exact or pattern) to another number.

  Pattern characters (Asterisk style, an optional leading `_` is ignored): `X` = 0-9, `Z` = 1-9, `N` = 2-9,
  a final `.` = one or more of any character, anything else matches itself.
  The target may contain `${EXTEN}` = the dialed number. The first enabled matching route wins; the
  result is rewritten again until no route matches (up to #{8} hops), so chains work and loops are detected.
  """

  @max_hops 8

  def max_hops, do: @max_hops

  @doc "Does `number` match `pattern`?"
  def matches?("_" <> pattern, number), do: matches?(pattern, number)
  def matches?(pattern, number) when is_binary(pattern) and is_binary(number) and pattern != "" do
    do_match(String.to_charlist(pattern), String.to_charlist(number))
  end

  def matches?(_, _), do: false

  defp do_match([], []), do: true
  defp do_match([?.], [_ | _]), do: true
  defp do_match([p | pr], [c | cr]), do: char_ok?(p, c) and do_match(pr, cr)
  defp do_match(_, _), do: false

  defp char_ok?(?X, c), do: c in ?0..?9
  defp char_ok?(?Z, c), do: c in ?1..?9
  defp char_ok?(?N, c), do: c in ?2..?9
  defp char_ok?(p, c), do: p == c

  @doc """
  Apply `routes` (list of string-keyed maps with "pattern", "target", optional "enabled") to `number`.
  Returns `{:ok, number, trail}` or `{:error, :loop, trail}`; `trail` is the list of numbers produced by routes.
  """
  def resolve(number, routes), do: walk(number, routes, [], 0)

  defp walk(number, _routes, trail, hops) when hops >= @max_hops,
    do: {:error, :loop, Enum.reverse([number | trail])}

  defp walk(number, routes, trail, hops) do
    case Enum.find(routes, fn r -> Map.get(r, "enabled", true) != false and matches?(r["pattern"], number) end) do
      nil ->
        {:ok, number, Enum.reverse(trail)}

      r ->
        target = String.replace(r["target"] || "", "${EXTEN}", number)

        if target == number or target == "",
          do: {:ok, number, Enum.reverse(trail)},
          else: walk(target, routes, [target | trail], hops + 1)
    end
  end
end
