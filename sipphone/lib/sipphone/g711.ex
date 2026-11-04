defmodule SipPhone.G711 do
  @moduledoc "G.711 PCMU (mu-law, PT 0) and PCMA (A-law, PT 8) codecs for 16-bit LE PCM."
  import Bitwise

  @bias 0x84
  @clip 32635
  @seg_end [0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF]

  def encode(0, pcm), do: for(<<s::signed-little-16 <- pcm>>, into: <<>>, do: <<lin_to_ulaw(s)>>)
  def encode(8, pcm), do: for(<<s::signed-little-16 <- pcm>>, into: <<>>, do: <<lin_to_alaw(s)>>)

  def decode(0, data) do
    for <<b <- data>>, into: <<>>, do: <<ulaw_to_lin(b)::signed-little-16>>
  end

  def decode(8, data) do
    for <<b <- data>>, into: <<>>, do: <<alaw_to_lin(b)::signed-little-16>>
  end

  def lin_to_ulaw(sample) do
    {sign, s} = if sample < 0, do: {0x80, -sample}, else: {0, sample}
    s = min(s, @clip) + @bias
    exp = msb(s >>> 7)
    mant = (s >>> (exp + 3)) &&& 0x0F
    bnot(sign ||| (exp <<< 4) ||| mant) &&& 0xFF
  end

  def ulaw_to_lin(u) do
    u = bnot(u) &&& 0xFF
    t = (((u &&& 0x0F) <<< 3) + @bias) <<< ((u &&& 0x70) >>> 4)
    if (u &&& 0x80) != 0, do: @bias - t, else: t - @bias
  end

  def lin_to_alaw(sample) do
    pcm = sample >>> 3
    {mask, pcm} = if pcm >= 0, do: {0xD5, pcm}, else: {0x55, -pcm - 1}
    seg = Enum.find_index(@seg_end, fn e -> pcm <= e end) || 8

    if seg >= 8 do
      bxor(0x7F, mask)
    else
      aval = seg <<< 4

      aval =
        if seg < 2,
          do: aval ||| ((pcm >>> 1) &&& 0x0F),
          else: aval ||| ((pcm >>> seg) &&& 0x0F)

      bxor(aval, mask)
    end
  end

  def alaw_to_lin(a) do
    a = bxor(a, 0x55)
    t = (a &&& 0x0F) <<< 4
    seg = (a &&& 0x70) >>> 4

    t =
      case seg do
        0 -> t + 8
        1 -> t + 0x108
        _ -> (t + 0x108) <<< (seg - 1)
      end

    if (a &&& 0x80) != 0, do: t, else: -t
  end

  defp msb(v) when v > 1, do: 1 + msb(v >>> 1)
  defp msb(_), do: 0
end
