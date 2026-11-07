defmodule Ashiato.Ocr.Socket do
  @moduledoc """
  Unix-socket client for the resident `ashiato-ocr` service.

  Despite the `:gen_tcp` name, `{:local, path}` opens an `AF_UNIX` socket: no IP
  address or port is involved. `packet: 4` is the whole framing protocol: the
  4-byte big-endian length prefix is handled by the socket, so nothing here
  frames by hand or reads a stream. Every failure — absent socket, closed
  connection, corrupt reply — comes back as an `{:error, term}` tuple instead
  of a raise.
  """

  @behaviour Ashiato.Ocr

  # Bound connect, recv, and send so a dead service cannot block the caller.
  @default_timeout 60_000

  # Cap the buffered frame, because a corrupt length prefix would otherwise let
  # the socket collect gigabytes before any timeout fires.
  @max_reply_bytes 4_000_000

  @doc "Runs OCR for one image locator against the configured socket."
  @spec recognise(Ashiato.Ocr.locator()) ::
          {:ok, [Ashiato.Ocr.line()]} | {:error, term()}
  def recognise({kind, value}) when kind in [:path, :url] and is_binary(value) do
    case socket_path() do
      nil ->
        {:error, :socket_path_missing}

      path ->
        # :gen_tcp.connect/3 defaults to an infinite timeout; the bound covers
        # connect, recv, and send.
        opts = [
          :binary,
          packet: 4,
          active: false,
          packet_size: @max_reply_bytes,
          send_timeout: timeout(),
          send_timeout_close: true
        ]

        case :gen_tcp.connect({:local, path}, 0, opts, timeout()) do
          {:ok, sock} -> round_trip(sock, kind, value)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec recognise(term()) :: {:error, :invalid_locator}
  def recognise(_locator), do: {:error, :invalid_locator}

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
    # encode/1, not encode!/1: an invalid UTF-8 locator returns an error instead of raising.
    with {:ok, payload} <- Jason.encode(%{"op" => "ocr", Atom.to_string(kind) => value}) do
      :gen_tcp.send(sock, payload)
    else
      {:error, _} -> {:error, :encode_failed}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"lines" => lines}} when is_list(lines) -> validate_lines(lines)
      {:ok, _} -> {:error, :invalid_response}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  # Return the index of the first malformed block instead of passing it on.
  defp validate_lines(lines) do
    result =
      Enum.reduce_while(Enum.with_index(lines), {:ok, []}, fn
        {block, index}, {:ok, acc} ->
          case validate_block(block) do
            {:ok, line} -> {:cont, {:ok, [line | acc]}}
            {:error, _} -> {:halt, {:error, {:invalid_line, index}}}
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
      # JSON `1` decodes as an integer; multiply so every score is a float.
      {:ok, %{bbox: bbox, text: text, score: score * 1.0}}
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
