defmodule Ashiato.Ocr.Socket do
  @moduledoc """
  Unix-socket client for the resident `ashiato-ocr` service.

  `packet: 4` is the whole framing protocol: the 4-byte big-endian length
  prefix is handled by the socket, so nothing here frames by hand or reads a
  stream. This call sits on the ingest pipeline, so every failure — absent
  socket, closed connection, corrupt reply — comes back as an `{:error, term}`
  tuple instead of a raise that would take the caller's supervision tree down.
  """

  @behaviour Ashiato.Ocr

  # A CPU-only PP-OCR pass takes seconds; the bound exists so a dead service
  # cannot hang the caller forever, not to cap legitimate work.
  @default_timeout 60_000

  @doc "Runs OCR for one image locator against the configured socket."
  @spec recognise(Ashiato.Ocr.locator()) ::
          {:ok, [Ashiato.Ocr.line()]} | {:error, term()}
  def recognise({kind, value}) when kind in [:path, :url] and is_binary(value) do
    case socket_path() do
      nil ->
        {:error, :socket_path_missing}

      path ->
        case :gen_tcp.connect({:local, path}, 0, [:binary, packet: 4, active: false]) do
          {:ok, sock} -> round_trip(sock, kind, value)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp round_trip(sock, kind, value) do
    try do
      with :ok <- send_request(sock, kind, value),
           {:ok, body} <- :gen_tcp.recv(sock, 0, timeout()) do
        decode(body)
      end
    after
      :gen_tcp.close(sock)
    end
  end

  defp send_request(sock, kind, value) do
    payload = Jason.encode!(%{"op" => "ocr", Atom.to_string(kind) => value})
    :gen_tcp.send(sock, payload)
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"lines" => lines}} when is_list(lines) -> validate_lines(lines)
      {:ok, _} -> {:error, :invalid_response}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  # A corrupt block must never reach the caller: OCR output feeds the ledger,
  # so a silently passed-on bad box would poison geometry downstream.
  defp validate_lines(lines) do
    result =
      Enum.reduce_while(Enum.with_index(lines), {:ok, []}, fn
        {block, index}, {:ok, acc} ->
          case validate_block(block) do
            {:ok, line} -> {:cont, {:ok, [line | acc]}}
            {:error, _} -> {:halt, {:error, {:invalid_line, index, block}}}
          end
      end)

    case result do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_block(%{"bbox" => bbox, "text" => text, "score" => score} = block)
       when is_binary(text) and is_number(score) do
    if bbox_ok?(bbox) and score >= 0 and score <= 1 do
      {:ok, %{bbox: bbox, text: text, score: score}}
    else
      {:error, block}
    end
  end

  defp validate_block(block), do: {:error, block}

  defp bbox_ok?([x1, y1, x2, y2])
       when is_integer(x1) and is_integer(y1) and is_integer(x2) and is_integer(y2) do
    Enum.all?([x1, y1, x2, y2], &(&1 in 0..1000))
  end

  defp bbox_ok?(_), do: false

  defp socket_path do
    Application.get_env(:ashiato, Ashiato.Ocr, [])[:socket_path] ||
      System.get_env("ASHIATO_OCR_SOCKET")
  end

  defp timeout do
    Application.get_env(:ashiato, Ashiato.Ocr, [])[:timeout] || @default_timeout
  end
end
